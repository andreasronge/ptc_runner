# REPL-Style Multi-Turn Agent Loop

Status: implementation-ready for milestone one; large/high-risk change with
semantic review gates. Milestone two remains separately unapproved.

## Objective

Restore the useful multi-turn semantics of the former `SubAgent` loop inside a
single bounded `PtcRunner.Kernel.run/2`:

1. The model submits one PTC-Lisp program per turn.
2. An ordinary successful result is an intermediate observation and advances
   the agent to another model turn.
3. Successful `def` and `defn` bindings are committed transactionally and are
   available to every later turn in the same Kernel run.
4. `(return value)` is the only successful terminal signal.
5. `(fail value)` is the explicit terminal failure signal.
6. Failed evaluations preserve all previously committed definitions.

Deliver this first as a minimal memory-continuation milestone. Exact `*1`,
`*2`, and `*3` parity is a separate second milestone because persistent
definitions already work in RunState, while history introduces another native
retention contract and changes RunState/ReplSession APIs.

The implementation must retain the Kernel's workflow/mission authority split,
single-owner accounting, hard ceilings, and provider-valid assistant/tool
message history.

## Non-goals

- Conversation state across separate calls to `Kernel.run/2`.
- Durable sessions, checkpoints, or recovery after a BEAM restart.
- User or human approval pauses.
- Asynchronous suspension/resumption.
- Multi-model routing.
- Compatibility shims for the removed `SubAgent` API.

Those features may later build on a separate long-lived session owner. They
must not complicate this single-run loop.

## Risk classification and authoritative boundaries

This is a large/high-risk change under
`docs/guides/large-change-guidelines.md`, even for the memory-only milestone.
It crosses the evaluator/Kernel process boundary, changes a public subordinate
outcome, retains provider-correlated transcript state, broadens retry policy,
and depends on redaction, quotas, owner state, and cleanup remaining correct.
Implementation must therefore use vertically complete slices and semantic
review checkpoints rather than landing all Kernel changes before their agent,
Viewer, test, and documentation consumers.

The authoritative representations are:

| Concept | Authoritative representation and owner | Boundary adapter / consumer |
| --- | --- | --- |
| Evaluator control | `PtcRunner.Lisp.Eval.Outcome` with context-bearing `:return`, `:fail`, and `:recur` controls | `PtcRunner.Lisp.run_native/2` converts return/fail controls to the existing `step.return` sentinels |
| Evaluation effects | `PtcRunner.Lisp.Eval.Effects` plus the shared evaluator activity atomic | `PtcRunner.Lisp.Result` exposes bounded chronological ledgers; Kernel does not add another effect representation |
| Mission capability accounting | `RunState` mission reservation counters | `Evaluation` compares the before/after count while its lease is held |
| Continuation memory | `RunState` native memory under one evaluation lease | `Evaluation` reserves and atomically commits or releases it |
| Subordinate public outcome | `PtcRunner.Kernel.Evaluation` map with `:continued`, `:returned`, `:failed`, or an error/limit outcome | `kernel/eval-source`, `kernel/eval`, `agent.core`, canonical evaluation status |
| Public value projection | `PtcRunner.Lisp.externalize_value/1` | Kernel workflow and terminal result boundaries; executable native values become inert labels |
| Model observation text | `agent.feedback/success` | `agent.core` places it in one correlated `role: tool` message |
| Accumulated transcript policy | `agent.core` | The host `LLMCapability` remains the independent final request-size authority |
| Canonical observability | `EventSink` and `TraceLog` bounded metadata | Exact source and transcript payloads remain private-inspection-only |

Do not change the unified evaluator outcome or capture protocols for this
feature. `:continued` is a Kernel policy classification of an ordinary
successful `step.return`, not a fourth evaluator control signal.

## Current state

The runtime already has most of the required mechanism:

- `RunState` owns committed mission evaluation memory and one transactional
  evaluation lease.
- `Evaluation` passes native memory into `Lisp.run_native/2` with
  `preserve_runtime_callables: true`, so persisted closures remain callable.
- The unified evaluator represents expected controls as context-bearing
  `Eval.Outcome` values, records audit data in one `Effects` value, and converts
  return/fail controls to the existing outer `step.return` sentinels. The
  Kernel can classify those sentinels without changing evaluator internals.
- A successful subordinate evaluation commits `step.memory`; an evaluation
  error or explicit `fail` releases the lease without committing.
- Repeated `llm-request` and `kernel-eval` calls already share one run deadline
  and aggregate quotas.
- `agent.core` already preserves provider-valid assistant/tool correlation for
  correction turns.

The missing behavior is control-flow information. `Evaluation.commit_result/3`
currently maps both an ordinary successful value and `{:__ptc_return__, value}`
to `%{outcome: :returned, value: ...}`. `agent.core` therefore terminates after
every successful program.

The former `SubAgent` loop on `main` used the desired distinction:

- explicit `return` -> terminal success;
- explicit `fail` -> terminal failure;
- any other successful result -> commit memory, append history, return an
  observation to the model, and continue.

The former loop's history was not unrestricted native REPL history. It passed
each intermediate value through `ResponseHandler.truncate_for_history/2`
(approximately 1 KB by default) and retained three entries. Do not cite that
implementation as evidence for retaining three arbitrary native values.

## Required semantics

| Program outcome | Memory | Workflow-visible projection | Model loop | Terminal result |
| --- | --- | --- | --- | --- |
| Ordinary success | Commit | `:continued`, inert public value, bounded evaluator prints | Continue with one escaped observation | None |
| `(return value)` | Commit | `:returned`, inert public value | Stop | Success with `value` |
| `(fail value)` | Roll back | `:failed`, inert public failure value | Stop | Explicit failure |
| Pure parse/analyze/runtime error | Roll back | Bounded error with `capability_activity?: false` | Correct while policy and turn budget permit | None or policy failure |
| Error after capability activity | Roll back memory; external effect remains | Bounded error with `capability_activity?: true` | Do not automatically retry | Non-retryable failure |
| Timeout/heap kill | Roll back | Existing limit/error outcome; detailed ledgers may be unavailable, RunState accounting remains authoritative | Correct only when capability activity is false and policy/turn budget permits | None, limit, or non-retryable failure |
| Memory bound exceeded | Roll back | Existing memory-limit outcome | Stop | Limit failure |
| Protocol error before evaluation | Unchanged | Bounded protocol feedback | Correct while budget remains | None or turn-limit failure |

Every LLM response consumes a turn, including protocol corrections and
evaluation corrections. A final explicit `return` is allowed on the last turn;
an intermediate result on the last turn fails because there is no remaining
model turn.

Only native continuation memory may be reused. Public/externalized memory is an
observation and must never be fed back into the evaluator because doing so
would destroy keywords, closures, and runtime callable identity.

## Design

### 1. Preserve terminal signals at the evaluation boundary

Change `PtcRunner.Kernel.Evaluation` to classify `step.return` before
externalizing it:

```text
ordinary value              -> outcome: :continued
{:__ptc_return__, value}     -> outcome: :returned
{:__ptc_fail__, value}       -> outcome: :failed
evaluator failure            -> outcome: :evaluation_error (or existing limit outcome)
```

For both ordinary success and explicit return:

- commit native `step.memory` under the active lease;
- externalize only the value copied into the workflow-visible result;
- include `step.prints || []` only in the `:continued` projection, so the next
  model turn can observe intentional `println` diagnostics;
- never expose the native memory map to workflow Lisp;
- report a memory limit failure if the owner rejects the commit.

Keep explicit `fail` transactional: it releases the lease and does not commit
definitions created earlier in the failing program.

Generalize the existing capability-activity safety marker. Every evaluation
error should report a bounded boolean `capability_activity?`, derived while the
single lease is still held as the OR of:

- the mission `RunState` capability count increasing since evaluation start;
- a non-empty unified `step.tool_calls` ledger; and
- an existing `step.fail.details.capability_activity? == true` marker.

The RunState delta remains authoritative when a killed worker cannot return its
detailed ledger; the unified ledger covers expected errors after runtime tools
that do not use Dispatcher reservations. Do not read `EvalContext`, its atomic,
or process-local capture state from Kernel code. If activity is true, mark the
error non-retryable. Memory rollback cannot undo an external read or write, so
`agent.core` must not automatically execute a corrected program after activity
unless a future effect-aware policy proves that retry is safe.

Use `:continued` as the new public outcome name. It describes agent policy
without overloading `:ok`, which is already used at capability boundaries.

### 1a. Make the public value projection non-executable

Correct `PtcRunner.Lisp.externalize_value/1` before using it for continued
observations. It currently labels `RuntimeCallable` and composed callable forms
but can leave a native `{:closure, ...}` tuple unchanged. The public projection
must recursively replace every executable value with an inert deterministic
label. Reuse the inert display wrappers already owned by
`PtcRunner.Lisp.Format`, whose JSON encoders emit only their display strings:

- a `Var` remains/becomes an inert `Format.Var` rendering as `#'name`;
- a Lisp closure becomes `%Format.Fn{params: "..."}`, rendering exactly as
  `#fn[...]`, without parameter names, body, captured environment, history, or
  metadata;
- a `RuntimeCallable` keeps its existing public qualified label;
- builtin values become inert `Format.Builtin` values, while composed and plain
  BEAM callables become `%Format.Fn{params: "..."}`, rendering as `#<builtin>`
  or `#fn[...]` as appropriate; and
- lists, maps, sets, and return/fail sentinel contents are traversed
  recursively, so nesting cannot bypass the projection.

The neutral `Lisp.run/2` continuation result remains native. This correction
affects only callers that explicitly request the public projection and Kernel
boundaries that already use it, including subordinate `:continued`,
`:returned`, and `:failed` values and the workflow terminal result. Add
regressions for a direct closure, a closure nested in a collection, composed
callables, and `(return (fn [x] ...))`, including a closure whose captured
environment contains a sentinel secret. The secret and native tuple must be
absent from workflow results, tool observations, canonical events, Logger,
Telemetry, and child-result fields.

Files:

- `lib/ptc_runner/lisp.ex`
- `lib/ptc_runner/kernel/evaluation.ex`
- `test/ptc_runner/lisp_test.exs` or the narrowest existing public-projection test
- `test/ptc_runner/kernel/core_contract_test.exs`
- `test/ptc_runner/kernel/agent_library_test.exs`

### 2. Keep the first milestone limited to existing memory continuation

Do not change the RunState reservation/commit API merely to make successful
`def` and `defn` bindings persist. It already atomically reserves the current
native memory and commits `step.memory`; the generated-program evaluator already
uses `preserve_runtime_callables: true`.

The first milestone therefore must not:

- add history fields to RunState;
- reinterpret `evaluation_memory_bytes`;
- refactor ReplSession ownership;
- change `*1`, `*2`, or `*3` behavior.

This smaller design isolates the actual regression: Evaluation erases the
ordinary-success versus explicit-return distinction, and `agent.core` treats
every successful evaluation as terminal.

Files:

- no RunState or ReplSession production change expected for milestone one;
- retain focused RunState/ReplSession regression tests to prove no behavior
  drift.

### 2b. Add exact turn history only as a separately approved milestone

If exact `*1`, `*2`, and `*3` semantics are required after milestone one, first
choose and document one of these incompatible contracts:

1. **Exact ReplSession history:** retain native prior values so later programs
   see the same types and callable identities.
2. **Former SubAgent observation history:** retain a bounded/truncated
   projection. This is cheaper but can change the type/value observed through
   `*1` and is not exact REPL behavior.

Prefer exact ReplSession semantics if this milestone is approved. Do not
silently truncate a native value and still describe `*1` as the previous exact
result.

For exact history, extend the single RunState owner from just evaluation memory
to an evaluation continuation:

```text
%{
  memory: native_user_namespace,
  turn_history: [oldest, ..., newest]
}
```

Use a fixed history depth of three because the language exposes only `*1`,
`*2`, and `*3`.

Change the evaluation reservation/commit API as one atomic owner protocol:

- reservation returns the current native memory, current native history, and
  lease token together;
- execution receives both `memory:` and `turn_history:`;
- an ordinary successful result proposes new memory plus history with the
  native result appended and trimmed to three;
- an explicit return proposes committed memory without needing to advance
  history;
- failure releases the lease without changing either value;
- commit validates the complete candidate continuation before installing it.

Do not introduce a separate `RunState.history/1` read followed by an update.
That would recreate a read-modify-write race outside the owner.

Do not reinterpret `evaluation_memory_bytes`: that can reject previously valid
programs when a large value is both stored in a definition and retained in
history. Add an explicit host-owned history ceiling (for example
`evaluation_history_bytes`) and validate both the per-value candidate and the
three-value aggregate before the atomic commit. `evaluation_memory_summary/1`
or a renamed continuation summary should then report:

- definition count;
- history count;
- combined retained bytes.

Adapt `Kernel.ReplSession` only in this second milestone. Its public/session
struct may continue projecting `memory` and `history` for callers, but RunState
must be the authoritative owner while the session is live. Do not add a
separate owner read followed by an update.

Files:

- `lib/ptc_runner/kernel/run_state.ex`
- `lib/ptc_runner/kernel/evaluation.ex`
- `lib/ptc_runner/kernel/repl_session.ex`
- `lib/ptc_runner/kernel/limits.ex`
- `test/ptc_runner/kernel/core_contract_test.exs`
- `test/ptc_runner/kernel/repl_session_test.exs`
- `test/ptc_runner/kernel/owner_status_privacy_test.exs`

### 3. Continue after an ordinary successful evaluation

Add a `:continued` branch to `priv/preludes/kernel/agent.core.clj`.

That branch must:

1. Confirm that another turn remains.
2. Build a bounded success observation.
3. Append the exact public assistant tool call to `messages`.
4. Append one `role: tool` message with the same `tool_call_id`.
5. Transition prompt policy with an `:evaluation-success` event.
6. Recur with the incremented turn.

Normalize `max_turns`, `max_program_chars`, `max_observation_chars`, and
`max_transcript_chars` once in `agent.core`. Pass an `assoc` of `cfg` containing
those effective values to `agent.prompt/initial-state`, so prompt policy never
sees a different turn or observation limit from the loop. Every success,
evaluation-error, and protocol-error transition event carries the completed
zero-based `:turn` plus `:turns-remaining = max_turns - (turn + 1)`. The default
prompt state retains only those bounded policy values and renders the final-turn
warning whenever `:turns-remaining == 1`, including the initial prompt when
`max_turns == 1`. The stable warning is:

```text
FINAL TURN: the next program must call (return value) or (fail value).
```

Keep the terminal branches:

- `:returned` -> `(return (result/ok value))`;
- `:failed` -> explicit workflow failure;
- non-retryable evaluation error -> terminal workflow failure;
- retryable correction -> existing provider-valid feedback exchange.

The success observation contract is exact:

- `max_observation_chars` defaults to `2_048`; an integer from `128` through
  `16_384` overrides it, and any other value uses the default;
- `agent.feedback/success` formats the already-public `evaluation.value` with
  `pr-str`, joins `evaluation.prints` in evaluator order, and builds this body:

  ```text
  user=> <value preview>
  println:
  <joined prints, only when non-empty>
  ```

- replace every literal `</untrusted_ptc_output>` in the body with
  `</untrusted_ptc_output (escaped)>` before truncation;
- cap the complete escaped body, including labels and marker, at
  `max_observation_chars`; when truncation is required, reserve space for and
  append `\n... (observation truncated)` inside that cap; and
- wrap the body in one trusted constant preamble plus
  `<untrusted_ptc_output source="evaluation">...</untrusted_ptc_output>`, then
  append a trusted reminder that any definitions created by the correlated
  successful program remain available.

This is deliberately valid text rather than truncated JSON. The wrapper and
trusted text have fixed bounded overhead outside `max_observation_chars`.
`println` data is included only for `:continued`; terminal return/fail branches
do not construct another model observation, and milestone one does not add
captured prints to existing error feedback.

Callable results such as the value of a `defn` must already be inert before
they reach `agent.feedback` and render only through the public labels defined
in section 1a (for example `#'add-one` or `#fn[...]`). The original program
remains in the assistant tool call, so the model can see which definition it
created without receiving native memory or closure internals.

Do not require stored-symbol or memory-diff feedback in milestone one.
Evaluation does not currently expose such a projection, and the exact model
program is already retained in the correlated assistant tool call. If later
evidence shows that stored-key feedback materially improves reliability, add a
separate bounded safe projection at the Evaluation boundary; never infer it by
exposing or externalizing the complete native memory map.

Files:

- `priv/preludes/kernel/agent.core.clj`
- `priv/preludes/kernel/agent.feedback.clj`
- `priv/preludes/kernel/agent.retry.clj` only if turn-budget helpers can be
  simplified there

### 3b. Bound the complete accumulated model request

Per-observation truncation is insufficient because `messages` retains every
prior generated program and observation. Add `max_transcript_chars` to
`agent.core`; it defaults to `262_144`, accepts a positive override up to the
hard maximum `1_000_000`, and otherwise uses the default.

Before every `llm/request`, construct the complete prospective request
(`system`, `messages`, and tool schema) exactly once, encode it with
`json/generate-string`, and measure `count` on that encoded string. A non-string
encoding terminates with
`(fail (result/error :invalid-transcript :encoding-failed))`; a count over the
configured ceiling terminates with
`(fail (result/error :transcript-limit :request-too-large))`. Neither case
calls `llm/request`.

This is intentionally a deterministic encoded-character policy, not an attempt
to duplicate the host's byte/heap representation. `LLMCapability` continues to
apply its independently configured retained-size validator as the final
authority, so it may reject a request below the prelude ceiling. Tests must
cover JSON escaping and non-ASCII text so the measured contract cannot silently
drift back to raw message-character counting.

Do not add compaction in this milestone. A future compaction policy may replace
older observations, but silent dropping or truncation of assistant/tool pairs
would invalidate provider correlation and is out of scope.

### 4. Teach the model the multi-turn contract

Update the shipped prompt and native action description:

- A program without `return` or `fail` is an intermediate turn.
- Successful `def` and `defn` bindings persist into later turns.
- A failed evaluation rolls back all bindings from that turn.
- Use `(return value)` only when the task is complete.
- Use `(fail value)` only when the task cannot be completed.
- Do not repeat irreversible capability effects merely to reconstruct state.

Remove the current instruction that every successful program must end in
`return` or `fail`. Keep the requirement of exactly one `run_ptc_lisp` tool
call per model turn.

Files:

- `priv/preludes/kernel/agent.prompt.clj`
- `priv/preludes/kernel/agent.native.clj`

#### Reuse the proven prompt policy from `main`

Use the former `SubAgent` prompt cards as migration input rather than inventing
new REPL guidance from scratch. Inspect these exact sources on `main` during
implementation:

- `priv/prompts/behavior-multi-turn.md`
- `priv/prompts/behavior-return-explicit.md`
- `priv/prompts/turn-feedback-must-return.md`
- `priv/prompts/turn-feedback-retry.md`
- `priv/prompts/reference.md`
- `lib/ptc_runner/sub_agent/loop/turn_feedback.ex`

Reuse or closely adapt these proven ideas:

- "Definitions persist across turns."
- Show `def`/`defn` in one turn and symbol reuse in a later turn.
- "Use `(println ...)` to inspect, `(return answer)` when done."
- "Explore first, return last."
- Make explicit that ordinary expression results are observations, not final
  answers.
- Tell the model that output previews are bounded and that it should print only
  concise diagnostics.
- Warn before the final available turn that the next program must call
  `return` or `fail`.
- Report the intermediate result in a REPL-like `user=> ...` preview.
- Remind the model that definitions created by the correlated successful
  program remain available; do not claim to report stored names unless a later
  bounded projection is implemented.

Adapt instead of copying these parts:

- The old prompt required a fenced Clojure block. The Kernel transport requires
  exactly one native `run_ptc_lisp` tool call and no prose.
- The old prompt advertised its own data/tool inventory. Keep the Kernel's
  frozen `kernel/mission-model-context` projection as the sole API authority.
- Do not advertise `budget/remaining`, journaling, plans, discovery, Java
  interop, or other features unless they are actually present in the selected
  Kernel bundle and current language contract.
- Do not copy the blanket old rule that a program may never call a tool and
  `return` in the same turn. A self-contained Kernel program may legitimately
  call a granted mission capability, validate its result, compute the answer,
  and return atomically. Preserve the broader principle: return only when the
  program has concrete evidence and the task is complete.
- The old prompt's output truncation numbers were tied to `SubAgent` options.
  Render the actual bounded policy selected for the Kernel prelude instead of
  claiming a stale fixed size.

Keep the resulting text domain-blind. Prompt content must explain runtime
semantics and the frozen mission API only; it must not mention test fixtures,
benchmark domains, or expected answer patterns.

Add prompt tests that assert the migrated semantic clauses rather than one
large byte-for-byte snapshot. At minimum assert that the prompt says:

- definitions persist after successful turns;
- failed turns roll back;
- ordinary results continue;
- explicit `return` completes;
- explicit `fail` aborts;
- exactly one `run_ptc_lisp` action is required;
- the generated program runs only against the advertised mission API; and
- the exact final-turn warning appears on an initial one-turn run and on the
  request after a transition leaves one turn remaining.

Also add a scripted-model test whose requester refuses to produce turn two
unless the system prompt contains the persistence and explicit-return rules.
This proves that the shipped prompt, rather than fixture knowledge, teaches the
REPL behavior.

### 5. Keep limits and lifecycle run-scoped

Do not add an agent session owner. The existing Kernel run remains the complete
lifetime boundary:

- `run_duration_ms` bounds the whole agent loop;
- `workflow_timeout_ms` bounds the outer workflow evaluation;
- `evaluation_timeout_ms` bounds each generated program;
- workflow `llm-request` quotas bound model turns;
- `subordinate_evaluations` bounds generated programs;
- mission capability quotas span every turn;
- provider resources close once after the complete loop;
- the evaluation lease serializes memory transactions in milestone one and the
  complete memory/history continuation only if milestone two is approved.

Document that `max_turns` cannot grant authority beyond these host limits. A
configuration asking for 32 turns can still stop earlier if the host permits
only 16 LLM requests or subordinate evaluations.

No new sleeping/backoff primitive is required for this work. Provider retry
backoff can be designed separately; generated-program continuation should not
sleep inside the workflow sandbox.

### 6. Preserve observability contracts

Add `:continued` to the bounded evaluation outcome vocabulary. Canonical event
loading already accepts generic JSON-like status data, but the Viewer success
set currently recognizes `ok`, `returned`, `completed`, and `success`, not
`continued`. Update `ptc_viewer/priv/static/js/kernel-transcript.js` and its
tests/fixtures so intermediate successful evaluations render as successful.

For each intermediate turn, traces should make it possible to establish:

- one LLM request produced one correlated model action;
- one action produced one subordinate evaluation;
- the evaluation continued, returned, failed, or errored;
- memory commit occurred only on success, with history commit also reported if
  milestone two is implemented;
- capability and evaluation counts remain cumulative for the run.

Canonical events must continue to contain only bounded safe metadata. Exact
programs, observations, and model messages belong only in explicitly enabled
private inspection capture.

Files to verify or change:

- `lib/ptc_runner/kernel/event_sink.ex`
- `lib/ptc_runner/kernel/trace_log.ex`
- `ptc_viewer/priv/static/js/kernel-transcript.js`
- corresponding Kernel and Viewer tests/fixtures

## Vertically complete test-first implementation sequence

Repository policy requires a failing regression before each bug fix. Each slice
below must then carry its behavior through production code, every affected
entry/exit path, durable documentation, focused verification, and a semantic
review checkpoint. Do not begin the next slice with unresolved correctness or
confidentiality findings in the previous one.

### Slice 1: General retry safety after capability activity

1. Add a failing agent integration test where a generated program invokes a
   granted capability and then produces an ordinary type/runtime error rather
   than a prelude contract error.
2. Add the equivalent mission runtime-tool case and retain current pure-error
   retry tests.
3. Implement the section 1 activity derivation in `Evaluation`, expose the
   bounded boolean on every evaluation error, and make `agent.core` terminate
   when it is true.
4. Assert the capability executes exactly once, candidate memory rolls back,
   prior committed memory remains intact, and no second model request occurs.
5. Update the maintainer guide's current contract-only retry wording to the
   complete evaluation policy.
6. Run focused Kernel/agent tests and review the RunState-counter/unified-ledger
   authority boundary before continuing.

This slice is independently coherent and may land before multi-turn success.

### Slice 2: Non-executable public value projection

1. Add failing public-projection tests for direct and nested closures, a closure
   capturing a sentinel secret, a `Var`, `RuntimeCallable`, builtin, composed
   callable, plain BEAM callable, and return/fail sentinel contents.
2. Exercise both existing Kernel consumers: subordinate `Evaluation` results
   and the workflow terminal result projection.
3. Correct `Lisp.externalize_value/1` as specified in section 1a without
   changing native `Lisp.run/2` continuation values.
4. Assert native tuple tags, closure bodies, captured environments, the sentinel
   secret, and executable values are absent from all public results, child
   results, canonical events, Logger, and Telemetry.
5. Update `Lisp` and Kernel boundary documentation, run focused Lisp/Kernel
   tests, and adversarially review the trust boundary before continuing.

### Slice 3: Complete intermediate-success turn

This slice changes the meaning of ordinary subordinate success and must remain
vertically complete. Do not land an `Evaluation`-only commit that emits
`:continued` while the shipped agent still treats it as an error.

1. Add a focused Evaluation test proving:
   - `(def committed 1)` produces `:continued` and commits `committed`;
   - `(def returned 2) (return returned)` produces `:returned` and commits
     `returned`;
   - `(def leaked 3) (fail leaked)` produces `:failed` and does not commit
     `leaked`; and
   - later evaluations resolve `committed` and `returned`, while evaluating
     `leaked` produces an unbound-variable error.
2. Exercise equivalent ordinary/return/fail classification through both
   production workflow routes: dynamic `kernel/eval-source` and embedded
   `kernel/eval`.
3. Add observation tests for result-only, print-only/nil-result, combined
   result/prints, exact-boundary, truncated, non-ASCII, callable-label, and
   literal `</untrusted_ptc_output>` content. Assert the exact assistant/tool
   correlation and the section 3 text contract.
4. Implement `:continued`, the `prints` projection, `agent.feedback/success`,
   the `agent.core` branch, prompt transition, final-turn warning, native action
   description, and Viewer success classification together.
5. Add the persistent `defn` journey:

   ```clojure
   ;; turn 1
   (defn add-one [x] (+ x 1))

   ;; turn 2
   (return (add-one 41))
   ```

   Assert exactly two LLM requests, correlated successful feedback, the final
   existing result envelope containing `42`, two subordinate evaluations, and
   no native callable in any public or ordinary observability plane.
6. Add a four-turn rollback journey that actually proves absence:

   ```clojure
   ;; turn 1: commits
   (def retained 42)

   ;; turn 2: candidate definition then runtime error; rolls back
   (do (def leaked 99) (+ {} 1))

   ;; turn 3: must fail as unbound if rollback worked
   (return leaked)

   ;; turn 4: prior committed state still works
   (return retained)
   ```

   Assert turn three is an unbound-variable correction rather than a returned
   value and turn four returns `42`.
7. Update the tutorial, maintainer guide, language specification, module docs,
   Viewer fixtures, and prompt semantic tests in this slice.
8. Run focused Lisp, Kernel, agent, provider-lifecycle, inspection, and Viewer
   tests, then review correlation, redaction, and public outcome parity before
   continuing.

### Slice 4: Transcript, final-turn, quota, and lifecycle limits

Add failing tests first, then implement and document these cases together:

- the encoded transcript exactly at the configured character ceiling is sent;
- one character over the ceiling fails with
  `:transcript-limit/:request-too-large` before provider dispatch;
- encoding failure produces `:invalid-transcript/:encoding-failed` without
  provider dispatch;
- JSON escapes and non-ASCII data are measured from the encoded request rather
  than raw message text;
- an intermediate result on the final allowed turn commits its memory and then
  produces the turn-limit failure because no next model turn exists;
- `subordinate_evaluations` or workflow `llm-request` quota may stop the loop
  before `max_turns`;
- an evaluation-memory rejection remains atomic;
- a timeout/heap failure never publishes candidate memory and does not retry
  after authoritative capability activity;
- provider resources and owner processes close exactly once after terminal
  success, non-retryable error, transcript rejection, quota failure, and
  timeout; and
- canonical events remain payload-free while private inspection alone may
  retain exact source, messages, and observations.

Run the focused limit/lifecycle/inspection tests and perform an adversarial
review of cleanup, accounting, and information disclosure before the final
whole-range review.

### Slice 5: Turn history (separately approved milestone two only)

Do not start this slice as part of the memory-only implementation. If separately
approved, add:

1. `40` as an ordinary result;
2. `(+ *1 1)` as the next ordinary result; and
3. `(return (+ *1 *2))`, which must return `81`.

Also prove that only three prior successful intermediate results are retained,
failed attempts do not consume a history position, the separate history ceiling
rejects an oversized candidate continuation atomically, and existing valid
memory is not charged again against a reinterpreted memory ceiling.

## Documentation changes

Update durable documentation together with the implementation:

- `docs/guides/kernel-tutorial.md`
  - describe intermediate success, committed definitions, success feedback,
    and explicit terminal return;
  - add a two-turn example.
- `docs/guides/kernel-maintainer.md`
  - in milestone one, document the evaluation outcome algebra, the existing
    atomic memory owner, the broader all-error capability-activity retry rule,
    and the non-executable public value projection;
  - in milestone two only, document the expanded continuation owner and the
    separate memory/history accounting.
- `docs/ptc-lisp-specification.md`
  - make the host contract for ordinary completion versus explicit return
    precise;
  - specify definition persistence and rollback within one Kernel run;
  - specify `*1`/`*2`/`*3` advancement and rollback only if milestone two is
    implemented.
- Module docs for `Evaluation` in milestone one. Update `RunState`, `Limits`,
  and `ReplSession` docs only for production contracts actually changed by
  milestone two.
- `PtcRunner.Lisp.externalize_value/1` documentation in milestone one must say
  that the projection is inert and cannot retain executable closure state.

Keep the `PTC_AGENT_PROMPT_V1` marker if the existing top-level prompt section
structure remains unchanged; it is the Viewer's decoding/version marker, not a
hash of instruction wording. If implementation changes that structure, bump
the marker and add the corresponding Viewer decoder and opaque-fallback tests
in the same slice.

Do not link code documentation to this private plan. Do not directly edit
generated function-reference or conformance outputs; update their generators
and run the documented generation task if the generated contract changes.

## Semantic review checkpoints

Because this is a high-risk boundary change, stop for review after each
vertically complete slice:

1. **Retry safety:** challenge the counter/ledger authority split, killed-worker
   behavior, rollback, and absence of duplicate capability activity.
2. **Public projection:** adversarially inspect direct, nested, terminal, and
   child-result callables for native state or captured-data disclosure.
3. **Continuation turn:** review the whole slice together for outcome parity,
   provider correlation, prompt correctness, observation escaping, Viewer
   status, and documentation drift.
4. **Limits/lifecycle:** review exact-boundary accounting, terminal paths,
   resource closure, and canonical/private observability separation.
5. **Final whole range:** inspect all committed and uncommitted changes for
   obsolete paths, competing representations, stale fixtures/comments,
   accidental compatibility code, and unexplained behavior outside the stated
   contracts.

A passing focused test run does not close a checkpoint with unresolved semantic
findings. Milestone two starts a new review sequence if it is approved.

## Verification

During implementation, run the narrowest tests after each slice, for example:

```console
mix test test/ptc_runner/kernel/agent_library_test.exs
mix test test/ptc_runner/kernel/core_contract_test.exs
mix test test/ptc_runner/kernel/repl_session_test.exs
mix test test/ptc_runner/kernel/provider_lifecycle_test.exs
mix test test/ptc_runner/kernel/inspection_lab_test.exs
```

After editing shipped sources under `priv/preludes/kernel/`, recompile them and
run the nested Viewer formatter/tests when its code or fixtures change. Then
run the repository gates:

```console
mix compile
mix precommit
mix prepush
```

`mix prepush` is required before pushing, not after every local edit. Fix and
rerun the specific failing tool before repeating the broader gate.

## Acceptance criteria

- A successful `defn` in one generated-program turn is callable in every later
  turn of the same Kernel run.
- Ordinary successful evaluation continues the model loop.
- Only explicit `return` completes successfully.
- Definitions created before an explicit `return` are committed before the run
  completes.
- Explicit `fail` terminates and does not commit the failing turn.
- Evaluation errors roll back memory; external capability effects are not
  claimed to be reversible.
- An evaluation error after capability activity is not automatically retried.
- Assistant tool calls and tool observations remain provider-valid and
  correlated by call ID.
- Continued observations include the inert result plus chronological evaluator
  prints, follow the exact escaped text contract, and honor the configured
  `2_048`-default/`16_384`-maximum body ceiling.
- Native closures, callable implementations, captured environments, and
  captured secrets never cross any workflow/public or ordinary observability
  boundary, including through nesting, terminal results, or child results.
- Dynamic `kernel/eval-source` and embedded `kernel/eval` produce the same
  ordinary/return/fail classifications.
- The complete prospective model request is bounded before each provider call,
  using the exact encoded-character contract and configured
  `262_144`-default/`1_000_000`-maximum ceiling, in addition to the independent
  host request, turn, capability, memory, time, heap, result, and event limits.
- Intermediate `:continued` outcomes render as successful in Kernel traces and
  the Viewer.
- Provider resources and owner processes are cleaned up once at run end.
- Canonical events remain payload-free; exact transcript data remains private.
- Durable docs describe the implemented behavior without referring to this
  plan.
- Every semantic checkpoint is closed, and `mix precommit` plus the pre-push
  `mix prepush` gate pass.

If milestone two is separately approved, add these acceptance criteria:

- `*1`, `*2`, and `*3` reflect the three prior successful intermediate results
  under the chosen documented native or projected-history contract.
- Failed evaluations do not advance history.
- Memory and history have explicit separate ceilings and the complete
  continuation commits atomically.

## Suggested commit structure

Commits follow the vertically complete slices and include their tests and
durable documentation:

1. `fix(kernel): make evaluation retries effect-safe`
2. `fix(lisp): make public value projection non-executable`
3. `feat(agent): continue successful mission evaluations`
4. `feat(agent): bound accumulated model requests`

The third commit includes the `Evaluation`, agent, prompt, Viewer, fixture, and
documentation changes required to understand `:continued`; do not split it
into an inconsistent Kernel-only intermediate commit. The fourth may include
the remaining final-turn/quota/lifecycle changes or be divided only where every
resulting commit remains behaviorally complete.

If milestone two is separately approved, follow with its own reviewable slice
and commit such as `feat(kernel): retain bounded evaluation turn history`, with
tests and durable documentation included rather than deferred.
