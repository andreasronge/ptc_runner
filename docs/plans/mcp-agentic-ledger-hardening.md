# MCP Agentic Ledger Hardening

**Status:** Planned · **Created:** 2026-06-09 · **Owner:** TBD  
**Related:** `docs/plans/subagent-upstream-runtime-integration.md` §7
Phase 3b decision, `docs/plans/root-upstream-runtime.md`

---

## 1. Context

The 2026-06-09 Phase 3b audit confirmed that core attempt recording should stay
deferred for now: no non-MCP consumer reads `Eval.run_subagent/3` bridge records
as an audit surface, and MCP's separate pre-dispatch ledger still owns the
current side-effect policy and wire projection.

The same audit found three MCP-ledger issues that should be handled before any
future Phase 3b migration:

1. `lisp_task` builds success `upstream_results[]` previews from raw upstream
   values, while core `lisp_eval` scrubs values before `result_overview`.
2. MCP has a second effect classifier that disagrees with
   `PtcRunner.Upstream.Effect.classify/3`.
3. The ledger wire shape carries fields with no valid current semantics
   (`turn`, `args_hash`) plus ignored completion-time `effect:` opts.

This plan intentionally splits the work into three PR-sized commits. Each PR
should include the failing test first, the minimal implementation, a Codex
review gate, and verification output before committing.

---

## 2. PR1: Success Overview Redaction

**Goal:** close the credential preview leak in `lisp_task` without changing
error handling or byte accounting.

This PR protects the diagnostic `upstream_results[]` preview surface. It does
not make the entire `lisp_task` response credential-safe: a program can still
return upstream data through `answer` / `structured_result`, and this plan
deliberately does not add an envelope-level redactor.

### Scope

Change only the `%{ok: true}` completion path in
`mcp_server/lib/ptc_runner_mcp/agentic.ex`:

- Keep `value_kind` derived from the raw `value`, matching
  `lib/ptc_runner/upstream/call_tool.ex`.
- Build `result_overview` from
  `Runtime.scrub(RootUpstreamRuntime.runtime(), value)`.
- Keep `result_bytes` from the raw `value`, matching core's raw size accounting.
- Do not change the `%{ok: false}` path. It already receives
  `Result.error(reason, scrubbed_detail)` from core, so its message is already
  scrubbed.

Suggested implementation shape:

```elixir
overview =
  RootUpstreamRuntime.runtime()
  |> Runtime.scrub(value)
  |> Result.result_overview(value_kind)
```

If the helper must be testable without a configured root runtime, fail closed
without leaking: rescue runtime lookup failures and omit `result_overview`
entirely. No preview is better than a raw preview. In normal production flow this
branch should be unreachable because the ledger wrapper only runs under a
configured root runtime. Do not add an envelope-level redactor as part of this
PR.

### Tests

Add a credentialed regression test that drives the MCP ledger wrapper directly:

- Start/configure an upstream runtime whose own `PtcRunner.Upstream.Runtime`
  credentials include `"SECRET"` in the runtime scrub set. Do not use
  `PtcRunnerMcp.Credentials.Redactor` / the MCP ETS redaction set for this test;
  PR1 must exercise `Runtime.scrub/2`.
- Wrap a stub `"call"` function with `Agentic.root_tools_with_ledger/2`.
- Have the stub return `Result.success(%{"token" => "SECRET"})`.
- Assert the ledger success entry's `result_overview["preview"]` contains
  `"[REDACTED]"` and does not contain `"SECRET"`.
- Also assert `Projection.upstream_results/1` is redacted, since that is the
  wire-facing surface.

`root_tools_with_ledger/2` is currently a test seam rather than the live
production bridge; the live path injects the wrapper through `on_upstream_call`.
The seam is still valid because both paths funnel through `call_with_ledger/3`
and `complete_ledger_attempt/3`.

This is a temporary patch over the parallel-ledger duplication. A future Phase
3b migration that re-points MCP projection onto core records should inherit
core's already-scrubbed overview and delete this duplicate path.

### Verification

Run the narrow MCP agentic tests, then `mix precommit` from the repository root.

---

## 3. PR2: Canonical Effect Classification

**Goal:** make MCP side-effect policy use the same classifier as core.

### Scope

In `mcp_server/lib/ptc_runner_mcp/agentic.ex`:

- Replace `upstream_tool_effect/2` with a call to
  `PtcRunner.Upstream.Effect.classify/3`.
- Keep `rescue _ -> :unknown` so classification remains fail-closed if the
  runtime call raises.
- Delete the now-dead MCP-local classifier functions:
  `find_tool_annotations/3`, `annotations_effect/1`, and `annotation_true?/2`.
- Add `PtcRunner.Upstream.Effect` to aliases if useful.

Expected shape:

```elixir
defp upstream_tool_effect(server, tool) do
  if RootUpstreamRuntime.configured?() do
    Effect.classify(RootUpstreamRuntime.runtime(), server, tool)
  else
    :unknown
  end
rescue
  _ -> :unknown
end
```

This preserves the pre-dispatch in-flight write block because
`ledger_attempt/2` still records the classified attempt before dispatch.

### Tests

Add the load-bearing reachable safety regression at the deterministic contract
test level, not through a planner-driven `lisp_task` run:

- Follow the existing `agentic_contract_test.exs` wrapper harness.
- Configure or inject a root runtime catalog entry for the tested tool with
  annotations `%{"readOnlyHint" => true, "destructiveHint" => true}`.
- Drive the stub call through the ledger wrapper.
- Assert the recorded effect is `:unknown` / projected `"unknown"` rather than
  `"read"`.
- Assert `Ledger.side_effecting_attempted?/1` is `true` for that entry.

The guard-to-stop mechanics are already covered elsewhere; this regression
should target the classifier bug and the ledger policy consequence directly.

Also keep or add a synthetic OpenAPI POST classifier test in core
`PtcRunner.Upstream.EffectTest`. OpenAPI POST is not reachable through current
v1 config because the compiler is GET-only, so this should remain a classifier
unit test rather than an end-to-end config test.

### Verification

Run core upstream effect tests, MCP agentic contract tests, then `mix precommit`.

---

## 4. PR3: Ledger Slimming

**Goal:** remove ledger fields and arguments that have no truthful current
semantics.

### Scope

Treat this as one intentional 0.x wire change because all edits collapse the
same signature.

In `mcp_server/lib/ptc_runner_mcp/agentic/ledger.ex`:

- Change `record_attempt/6` to `record_attempt/4`:
  `(ledger, server, tool, effect)`.
- Remove the `args` and `turn` parameters.
- Remove `:args_hash` and `:turn` from the entry type and recorded entry.
- Delete `hash_args/1`.
- Keep `:effect` as the pre-dispatch classification.

In `mcp_server/lib/ptc_runner_mcp/agentic.ex`:

- Update `ledger_attempt/2` to stop passing `call_args` and literal `1`.
- Remove ignored completion options `effect: :unknown` from
  `Ledger.complete_success/3` and `Ledger.complete_error/5` calls.

In `mcp_server/lib/ptc_runner_mcp/agentic/projection.ex`:

- Remove `"turn"` and `"args_hash"` from projected `upstream_calls[]`.

In the `lisp_task` output schema:

- Remove `"turn"` and `"args_hash"` from `@upstream_calls_item_schema`.

Do not attempt to thread a real turn in this PR. The current
`on_upstream_call` wrapper shape has no turn in scope, and adding one belongs to
a future Phase 3b record surface if that trigger fires. Remove only the ledger /
`upstream_calls[]` turn field. Preserve unrelated real turn state, including:

- planner turn tracking in `mcp_server/lib/ptc_runner_mcp/agentic.ex`;
- session lifecycle / session output schema `turn` assertions;
- core SubAgent loop turn state.

### Tests

Update ledger/projection tests to assert the slim shape:

- `upstream_calls[]` contains server/tool/status/duration/effect/result_bytes/
  oversize and optional reason/error.
- It does not contain `"turn"` or `"args_hash"`.
- Completion-time `effect:` cannot appear because the option has been removed
  from call sites.

Name and update the known breaking assertions in
`mcp_server/test/ptc_runner_mcp/agentic_contract_test.exs` that currently expect
projected `"turn" => 1` in `upstream_calls[]`. No known test assertion currently
references `args_hash`, but verify that with search before editing.

Search verification:

```sh
rg -n "args_hash|\"turn\" =>|:turn|effect: :unknown" \
  mcp_server/lib/ptc_runner_mcp/agentic* mcp_server/test
```

Treat `:turn` hits as candidates requiring inspection, not automatic removals.
Planner/session/SubAgent turn fields are in scope only if they are ledger
projection artifacts; otherwise keep them.

### Verification

Run MCP agentic tests and `mix precommit`. Because this PR changes typespecs and
the `record_attempt` arity, also run `mix prepush` or at least dialyzer before
pushing.

---

## 5. Explicit Non-Goals

- Do not add core pre-dispatch attempt recording.
- Do not change `Eval.with_run_context/3` drain-on-raise behavior.
- Do not add an envelope-level redactor for `lisp_task`.
- Do not change upstream error redaction; the current error path already receives
  scrubbed details from core.
- Do not introduce compatibility shims for removed `turn` or `args_hash` fields.

The raise-through-bridge record-loss issue remains the outstanding §6 fault
test from `subagent-upstream-runtime-integration.md`. It should document current
behavior until a real Phase 3b trigger creates a consumer for bridge records on
raise.

---

## 6. Landing Workflow

Use one isolated worktree or equivalent per PR-sized commit so unrelated doc or
code edits do not leak between changes.

Land the commits sequentially. PR2 and PR3 both edit the same
`agentic.ex` ledger path, so PR3 should rebase on PR2 rather than being built in
parallel against the original file state.

For each PR:

1. Write the failing test first.
2. Implement the smallest code change that satisfies the test.
3. Run the narrow test target.
4. Run `mix precommit`.
5. Run a Codex review gate for that commit's diff and address findings before
   landing.
6. For PR3, also run `mix prepush` or dialyzer because the ledger typespecs and
   arities change.
7. Commit directly to `main` only after verification, with a concise
   Conventional Commit subject.
8. Verify the final commit with `git show --stat`.
