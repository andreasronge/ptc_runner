# Native Step State and Public Rendering — Plan

## Status

Part 1 implemented on 2026-07-01 except for the optional continuation wrapper
follow-up. The current implementation introduces `PtcRunner.Step.Public`,
keeps session/SubAgent loop execution native internally, renders public
`SubAgent.run/2` and `PtcRunner.Session.eval/3` results at the API edge, and
adds regression coverage for MCP session keyword validation.

The immediate keyword-persistence bug shipped with this renderer refactor.
Part 2 (below) specs the remaining structural hardening: split the native and
public step types, wrap chat continuation state in an opaque handle, funnel
finalization, and retire the remaining representation flags. Part 2 is
proposed and not started.

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

---

# Part 2 — Make the Boundary Structural

## Status

Implemented in the current Part 2 change for the native/public step split,
opaque chat continuation, and removal of `native_step` /
`native_step_result` representation flags. Remaining follow-up: finish the
single finalization funnel/render-once cleanup and document/test the
parent↔child SubAgent boundary contract.

## Problem

Part 1 centralized *how* to render, but not *whether a given value has been
rendered*. The native/public distinction is still a temporal invariant — "has
`Step.Public.render/2` been called on this value yet?" — that is not
observable from the data. The Part 1 review history is the diagnostic: every
review round found the same defect class (a native step or value crossing a
public edge unrendered) on yet another path, because no type or runtime check
distinguishes the two representations.

Before Part 2, five weaknesses remained. This change resolves items 1, 3, and
4; item 2 is reduced by the native/public type split but still needs continued
renderer/scanner discipline for any new value-carrying fields; item 5 remains
as finalization/render-once cleanup.

1. **Resolved: one struct, two meanings.** `Step.Public.from_native/2` now maps
   `%PtcRunner.Lisp.Result{}` to public `%PtcRunner.Step{}`. Native/public
   confusion is visible in pattern matches instead of being implicit temporal
   state.

2. **Field-enumeration renderer and scanner.** `%Step{}` has 24 fields;
   `Step.Public.render/2` converts 10 of them and `PublicStepAssertions`
   checks the same 10. Any future Step field that can carry a Lisp value
   must be added to both lists by hand or it leaks silently — exactly how
   `catalog_ops` was missed in Part 1 review.

3. **Resolved: representation flags moved rather than disappeared.**
   `native_step:` and `native_step_result:` are gone from ordinary flow.
   Internal callers use native entry points (`Lisp.run_native/2`,
   `Loop.run_native/2`), and public facades render at their edge. Direct
   `Lisp.run/2` remains the documented compatibility exception that keeps
   `step.memory` native continuation state.

4. **Resolved: Step still doubles as chat continuation state.**
   `SubAgent.chat/3` now returns `{:ok, result, %PtcRunner.SubAgent.Chat{}}`.
   The chat handle carries messages plus native memory, has no `Jason.Encoder`,
   and hides internals in `Inspect`.

5. **Double rendering per run.** `Loop.run_with_telemetry/2` renders the
   final step for telemetry stop metadata, then `render_loop_result/2` (or
   the `SubAgent` facade) renders it again for the caller. The deep-walk cost
   is paid twice on every run.

One boundary decision is also currently implicit rather than documented:
SubAgentTool child results are rendered publicly before entering the parent's
native runtime (`ToolNormalizer`), so keyword identity does not survive
parent↔child agent boundaries. That is probably the right contract — child
results are external data, like any tool result — but it is decided per call
site and stated nowhere.

## Goal

> A public `%Step{}` cannot exist without going through the renderer, and
> continuation state cannot be JSON-encoded without a loud failure.

Turn the Part 1 convention into structure: pattern matches and dialyzer
enforce the boundary, so review no longer has to enumerate paths.

## Non-Goals

- Do not tag every Lisp value with an envelope struct. That would make
  externalization local and total, but it touches the entire evaluator and
  adds allocation to every operation. The type split gets most of the safety
  at a fraction of the cost.
- Do not preserve the `SubAgent.chat/3` four-tuple shape. This is a 0.x
  library; prefer the clean contract (consistent with Part 1 non-goals).
- Do not change what public payloads contain — only how their construction
  is enforced.

## Solution Outline

### 2.1 Split the step type

Introduce an internal native result type and reserve `%PtcRunner.Step{}` for
the public shape:

- `%PtcRunner.Lisp.Result{}` (working name) is what `Lisp.run` internals, the
  SubAgent loop, session eval, and the upstream bridge produce and thread.
  Same field names as today's step, so internal code changes are mechanical.
- Rename `Step.Public.render/2` to `Step.Public.from_native/2` with the
  signature `Step.Native.t() -> Step.t()`. It becomes the only constructor
  of public `%Step{}` in the library.
- Public code that pattern-matches `%Step{}` can no longer accept a native
  step; passing native where public is expected is a match/dialyzer error.
- Double-rendering becomes unrepresentable: `from_native/2` does not accept
  an already-public `%Step{}`.

Naming: the public struct keeps the `Step` name because it is the documented
API type; the internal struct is then free to change shape without a public
break.

Alternative considered and rejected: a `rendered?: boolean` field on
`%Step{}`. It is invisible to dialyzer, requires guards at every consumer,
and reintroduces the flag pattern this plan removes.

### 2.2 Opaque continuation handle for chat (completes Part 1 §4)

Replaced the `{:ok, result, messages, memory}` tuple of `SubAgent.chat/3`:

```elixir
{:ok, result, %PtcRunner.SubAgent.Chat{}}
```

- `%Chat{}` holds `messages` plus native continuation memory, with room for
  journal/tool_cache later without another shape change.
- No `Jason.Encoder` implementation, and a custom `Inspect` that elides
  internals — JSON-encoding continuation state fails loudly instead of
  silently stringifying keywords.
- `chat(agent, msg, chat: prior_chat)` replaces the separate `:messages` and
  `:memory` options.
- With no SubAgent/Session/MCP public Step carrying native memory, the
  `native_step` and `native_step_result` flow-control flags are deleted.
  Direct `Lisp.run/2` remains the compatibility exception: it renders return
  values publicly but keeps `step.memory` as continuation state for callers
  that feed it into a later direct Lisp eval.

Breaking change, external-only: `demo/` and `mcp_server/` have no `chat/3`
callers.

### 2.3 One finalization funnel; render once (completes Part 1 §5)

Status: partially implemented. The loop returns native and the
`native_step_result:` option is gone; the full render-once telemetry/finalizer
cleanup remains.

- Funnel the final-step assembly sites in `Loop`, `TextMode`, `JsonHandler`,
  and `PtcToolCall` (currently ~19 direct `%Step{}`/`Step.error` construction
  points) through one native-step assembler: branch code computes native
  result and control flow; the assembler builds the native step.
- Render exactly once per run at the `Runner.run/2` boundary. Pass the
  already-rendered public step into the telemetry stop metadata instead of
  rendering separately inside `run_with_telemetry/2`.
- Delete the `native_step_result:` option — the loop always returns native;
  the facade boundary always renders.

### 2.4 Single deep-walk owner; retire assembly-time externalization

Status: implemented for assembly-time externalization and the `native_step:`
flag. Continued field coverage remains part of renderer maintenance.

- Internal step assembly in `lisp.ex` always builds native. Delete
  `memory_for_step/2`, `return_for_step/3`, `catalog_ops_for_step/1`, and
  the `native_step:` flag on `EvalContext`.
- `PtcRunner.Lisp.run/2` is itself a public API and keeps its externalized
  default — implemented by rendering at its own return edge via
  `Step.Public`, not by a second assembly-time mechanism. Internal callers
  (Session, loop, upstream bridge) use the native entry point.
- Fold the two deep-walkers into one owned by `Step.Public`;
  `Lisp.externalize_value/1` remains the value-level primitive it delegates
  to. One walker means one place to handle a new native value kind.

### 2.5 Document the child-boundary contract

State explicitly (SubAgentTool moduledoc + subagent guide): child SubAgent
results are external data; keyword identity is not preserved across
parent↔child boundaries. Add a regression test asserting the contract so a
future "fix" cannot silently change it.

## Verification

- Dialyzer passes with the split types; a deliberate native-into-public
  misuse in a test fixture is rejected.
- `Jason.encode!/1` on `%Chat{}` raises (regression test), and `inspect/1`
  on `%Chat{}` does not dump native internals.
- Render-once: telemetry stop metadata and the caller result are the same
  rendered struct (assert identity, or probe the walker with a counter).
- The Part 1 invariant scanner is retained as a backstop over the same mode
  matrix and still passes.
- The original two-turn keyword reproduction passes through both `Session`
  and the new `chat/3` shape.
- Child-boundary test: a child agent returning `{:parse :jsonl}` yields
  externalized data in the parent runtime, per the documented contract.
- Repository gates: `mix format --check-formatted`, `git diff --check`,
  `mix test`, `(cd mcp_server && mix test)`, `mix precommit`.

## Acceptance Criteria

- Done: public `%Step{}` values reachable from `SubAgent.run/2`, `Session.eval/3`,
  `SubAgent.chat/3`, MCP, and trace APIs are constructible only via
  `Step.Public.from_native/2`.
- Done: no `native_step` or `native_step_result` representation flags remain in
  ordinary flow. The only remaining render option exception is direct
  `Lisp.run/2` preserving `step.memory` as continuation state for backward
  compatibility.
- Done: `SubAgent.chat/3` returns an opaque `%Chat{}` continuation handle whose
  JSON encoding fails loudly.
- Remaining: final steps are assembled by one funnel and rendered exactly once
  per run.
- Remaining: one deep-walk implementation owns native→public conversion.
- Remaining: child-boundary keyword semantics are documented and tested.

## Sequencing and Risk

1. **Done: 2.2 Chat handle** — removes the last public carrier of native
   memory and the chat render options.
2. **Remaining: 2.3 Funnel + render-once** — shrinks the number of render call sites,
   preparing the type split.
3. **Done: 2.1 Type split + most of 2.4** — native `%Step.Native{}` is internal
   state and public `%Step{}` is rendered at API boundaries.
4. **Remaining: 2.5 Contract docs/test** — document and pin child-boundary
   keyword semantics.

Main risk is churn in tests that construct `%Step{}` directly; mitigate by
keeping field names identical between the native and public structs so most
updates are alias changes. The `chat/3` shape change is the only public
break and lands in the changelog under a minor 0.x bump.
