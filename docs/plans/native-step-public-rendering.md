# Native Step State and Public Rendering — Plan

## Status

Implemented on 2026-07-01 except for the optional continuation wrapper
follow-up. The current implementation introduces `PtcRunner.Step.Public`,
keeps session/SubAgent loop execution native internally, renders public
`SubAgent.run/2` and `PtcRunner.Session.eval/3` results at the API edge, and
adds regression coverage for MCP session keyword validation.

The immediate keyword-persistence bug can ship with this renderer refactor. The
remaining long-term hardening is to wrap opaque chat/session continuation state
in a dedicated struct so accidental JSON encoding fails loudly.

## Problem

The session keyword bug showed the core boundary mistake:

- PTC-Lisp runtime state must preserve native values such as keywords,
  closures, sentinels, and runtime callables while a computation is still
  resumable.
- Public output must be JSON/protocol-safe and must externalize those native
  values into ordinary Elixir/JSON shapes.

The current fix establishes that invariant by convention across many
control-flow branches. Each final-step path has to remember which pieces to
externalize:

- `step.return`
- `step.fail`
- `step.memory`
- `step.turns[*].memory`
- `step.turns[*].result`
- trace previews and memory diffs
- MCP envelope fields

That is fragile. Review rounds found the same failure pattern in multiple
places: direct finals, turn results, trace previews, and combined text/JSON
finals. The pattern is diagnostic: duplicated final-step assembly lets every
new path accidentally leak native values or accidentally store externalized
values as continuation state.

The deeper design issue is that `%PtcRunner.Step{}` currently has a dual
representation:

- internal native step state, suitable for continuing evaluation;
- public rendered step state, suitable for API/MCP/trace output.

The value itself does not say which representation it is. Callers infer that
from flags such as `:externalize_memory` and `:externalize_final_memory`, which
encode the same conceptual boundary at different layers.

## Goal

Make native runtime state the only internal representation, and perform
externalization once at explicit public edges.

The desired invariant:

> Inside the library, `%Step{}` and loop/session state are native. At public
> boundaries, render a public representation exactly once.

## Non-Goals

- Do not add backward-compatibility shims for both step shapes. This is a 0.x
  library; prefer a clean internal contract.
- Do not externalize `SubAgent.chat/3` PTC-Lisp memory. That value is
  continuation state and should remain opaque to callers.
- Do not change PTC-Lisp keyword semantics or parser behavior.
- Do not change MCP envelope content except as required to preserve the public
  native-free contract.

## Solution Outline

### 1. Introduce one public rendering boundary

Add a module dedicated to converting native internal values to public payloads,
for example:

```elixir
PtcRunner.Step.Public.render(step, opts)
```

or:

```elixir
PtcRunner.PublicStep.from_internal(step, opts)
```

The renderer owns all public-shape conversion:

- `return`: `Lisp.externalize_value/1`, then public key normalization where
  appropriate.
- `fail`: externalized failure payload.
- `memory`: `Lisp.externalize_memory/1`, unless the caller explicitly requests
  native continuation memory.
- `turns`: externalized turn memory and turn result.
- nested child steps, if they are exposed publicly.

The renderer should be the only normal place that knows how to turn native Lisp
values into public values.

### 2. Make internal execution native-only

Remove the representation flags from ordinary internal flow:

- remove or sharply reduce `:externalize_memory`;
- remove or sharply reduce `:externalize_final_memory`;
- make `PtcRunner.Lisp.run/2`, `PtcRunner.Session`, and SubAgent loop state keep
  native values by default.

Step assembly should no longer decide whether a value is public. It should build
the native internal step only.

### 3. Render at true public edges

Call the public renderer only where data leaves the native execution boundary:

- `SubAgent.run/2` return values;
- `PtcRunner.Session.eval/3` return values;
- MCP session/tool envelope rendering;
- trace/event serialization.

`SubAgent.chat/3` in PTC-Lisp mode is the exception for memory: return native
continuation memory and document it as opaque. Its result/messages can still be
public rendered where appropriate.

### 4. Make opaque continuation memory explicit

Wrap chat/session continuation memory in a dedicated struct, for example:

```elixir
%PtcRunner.Continuation{memory: native_memory}
```

Benefits:

- JSON encoding fails loudly instead of silently converting continuation state.
- Pattern matching makes continuation use explicit.
- Future fields can be added without changing the public tuple shape again.

This remains a follow-up after the renderer refactor because it changes the
`SubAgent.chat/3` tuple shape and session embedding ergonomics.

### 5. Remove duplicated finalization logic

After the renderer exists, simplify duplicated final-step construction in:

- `PtcRunner.SubAgent.Loop`
- `PtcRunner.SubAgent.Loop.TextMode`
- `PtcRunner.SubAgent.Loop.JsonHandler`
- `PtcRunner.SubAgent.Loop.PtcToolCall`
- `PtcRunner.Session`
- `PtcRunnerMcp.Sessions.Session`

The target shape is:

1. branch-specific code computes native result and control flow;
2. shared step assembler builds a native step;
3. public edge calls the renderer.

## Completed Cleanup

- Removed the representation-control flags from ordinary SubAgent/session loop
  flow.
- Removed dead per-mode final memory rendering helpers.
- Kept MCP session contract validation at the public boundary by externalizing
  native return values before schema atomization/JSON encoding.

## Verification

### Invariant scanner

Add a generic test helper that walks public payloads and fails if any internal
runtime value appears.

The scanner should reject at least:

- `%PtcRunner.Lisp.Keyword{}`
- runtime callable structs/labels intended only for internal memory
- closure tuples or closure structs
- return/fail sentinels such as `{:__ptc_return__, _}` and `{:__ptc_fail__, _}`

Run the scanner over public `Step` fields:

- `return`
- `fail`
- `memory`
- `turns`
- `child_steps`
- trace/event payloads that are public API

### Mode matrix

Cover the paths that previously produced misses:

- content/text mode direct final;
- content/text mode combined final;
- content/text retry/final-after-retry;
- JSON handler final;
- tool-call direct final;
- explicit `(return ...)`;
- explicit `(fail ...)`;
- memory-limit and LLM-error final paths;
- `Session.eval/3`;
- MCP `lisp_session_eval`;
- `SubAgent.chat/3` memory threading.

For each public path:

- assert public payloads contain no native runtime values;
- assert nested keywords externalize to strings or public keyword-compatible
  values as intended;
- assert failure maps keep their public atom/string key behavior and are not
  over-normalized.

For each continuation path:

- assert nested keyword values survive across turns;
- assert `*1`, `*2`, and turn-history values preserve keyword identity while
  still internal;
- assert closures and runtime callables are retained or sanitized according to
  the internal continuation contract.

### Regression reproduction

Keep an integration test for the original bug:

```clojure
(def m {:page {:parse :jsonl}})
```

followed by a separate eval in the same session:

```clojure
(keyword? (get (get m :page) :parse))
```

Expected result: `true`.

Also assert the public MCP/Step response for the same session is externalized
and does not expose `%PtcRunner.Lisp.Keyword{}`.

### Commands

Run targeted tests first:

```sh
mix test test/ptc_runner/session_test.exs \
  test/ptc_runner/sub_agent/chat_test.exs \
  test/ptc_runner/sub_agent/run_test.exs \
  test/ptc_runner/sub_agent/loop

(cd mcp_server && mix test test/ptc_runner_mcp/sessions_lifecycle_test.exs)
```

Then run repository gates:

```sh
mix format --check-formatted
git diff --check
mix precommit
```

If `mix precommit` fails on dependency lock drift, run `mix deps.get` only after
confirming the lockfile change is expected for the current branch.

## Acceptance Criteria

- Internal session and SubAgent loop state uses native Lisp values consistently.
- Public rendering is centralized in one renderer or a small set of explicit
  edge renderers.
- Ordinary final-step branches no longer manually externalize memory/turns.
- Public `Step`, MCP, and trace payloads are free of internal Lisp runtime
  values.
- Cross-turn keyword identity is preserved for sessions and PTC-Lisp chat
  continuation memory.
- The original two-turn reproduction passes.
- The public invariant scanner covers the mode matrix and would have caught the
  direct-final, turn-result, trace-preview, and combined-final misses.
