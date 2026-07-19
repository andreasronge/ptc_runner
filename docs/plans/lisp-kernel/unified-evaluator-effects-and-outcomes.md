# Unified evaluator effects and outcomes

Status: implemented 2026-07-19. Created 2026-07-18 after the runtime-prelude
contract review found that nested higher-order and parallel failures could
cross several distinct effect-capture and error-transport paths.

This plan consolidates evaluator audit effects into one typed representation,
one process-local capture stack, and one effect-bearing outcome protocol. It is
primarily an internal simplification: PTC-Lisp values, error classifications,
retry policy, resource limits, prompt rendering, trace schemas, and capability
authority must retain their current external behavior. The intentional
observable corrections are that already-executed effects currently lost on an
expected exit become present in the existing result and trace fields, failed
parallel work receives its existing audit record, and cache writes captured
from an earlier ordinary-HOF callback become visible to later callbacks. No new
public field or error shape is introduced for those corrections.

## Why this work is needed

### Audit effects now participate in correctness

The evaluator records more than optional diagnostics:

- capability-call activity determines whether a failed model program may be
  retried without risking duplicate external effects;
- tool-call records and caches determine whether a later call is charged or
  served from an already observed result;
- prelude-call counts provide accounting and diagnostic reporting; and
- prints and parallel-call records explain the executed program in traces.

Losing an effect on an exceptional path is therefore not merely incomplete
logging. It can produce incorrect accounting or an unsafe retry decision.
Capability activity must continue to have an authoritative shared atomic signal
in addition to the detailed effect ledger, because a heap-killed worker cannot
reliably return process-local records.

### Two capture mechanisms represent the same state

Ordinary Erlang higher-order functions currently use the private
`:__ptc_hof_stack` in `PtcRunner.Lisp.Eval.Apply`. Parallel workers additionally
use `PtcRunner.Lisp.Eval.EffectCapture` and its separate
`:__ptc_parallel_effect_capture_stack__`.

Both mechanisms carry the same logical fields:

- `tool_calls`;
- `pmap_calls`;
- `prints`;
- `prelude_call_counts`; and
- `tool_cache`.

The empty value, merge direction, cache precedence, and cleanup rules are
implemented in several places. A new field or exit path must be added to every
copy. This duplication caused the runtime-contract review to require a second
fix when the newly introduced `ParallelError` crossed an outer HOF stash that
only preserved effects for `ContractError`.

### Control flow uses too many transport shapes

Evaluator work currently crosses ordinary result tuples, `ContractError`,
`ParallelError`, `ExecutionError`, `ToolError`, and thrown `return`/`fail`
signals. Some contain an `EvalContext`, some contain an effect delta, and some
require a caller to reconstruct one. Wrappers consequently contain
exception-specific rescue lists whose real purpose is to retain effects.

Exceptions are still useful as a private adapter when an Elixir callback must
abort an `Enum` operation that accepts only a value-returning function. The
problem is not the use of an exception itself; it is having several semantic
exception types with different effect-retention rules.

The current ordinary-HOF bracket also exposes a known defect that must not be
frozen as compatibility behavior. It merges its accumulated frame into
`ContractError` and `ParallelError`, but drops the frame for `ToolError` and
thrown `return`/`fail` signals. Separately, ordinary returned `{:error, reason}`
tuples contain no context, so a sequential form that fails after an earlier
effect can lose the earlier form's ledger and cache. This refactor must correct
those paths while preserving their value or failure classification.

### The evaluator is difficult to review locally

`Eval`, `Apply`, `ParallelRunner`, and `Eval.Context` collectively own parsing
results, callable adaptation, control signals, scheduling, cancellation,
effect capture, effect merging, error classification, and trace assembly. A
small semantic change can therefore require inspection across several large
modules. Consolidating effects and outcomes should happen before merely moving
code into smaller files, so extraction creates real ownership boundaries rather
than distributing the same implicit protocol.

## Goals

1. Define one canonical typed representation for all evaluator effects.
2. Define merge order, cache precedence, bounds, and context application once.
3. Use one nestable process-local capture stack wherever explicit context
   threading is impossible.
4. Make every expected evaluation exit, including `return`, `fail`, and
   `recur`, carry its effects explicitly.
5. Use at most one private abort carrier for expected exits crossing plain
   Elixir/Erlang callbacks.
6. Keep `ParallelRunner` responsible for scheduling and cancellation rather
   than contract-specific error semantics.
7. Preserve deterministic input-order reporting for parallel work.
8. Keep the shared capability-activity signal authoritative for retry safety.
9. Reduce `Eval` and `Apply` responsibilities after behavior is characterized.

## Non-goals

- Rewriting the evaluator as a monad or converting every expression to
  continuation-passing style.
- Changing PTC-Lisp syntax, value semantics, error messages, public result
  structs, trace schemas, or Viewer behavior.
- Treating a currently missing tool, print, parallel, prelude-count, or cache
  record as compatibility behavior when the underlying effect did execute.
  Restoring those records is an explicit bug fix within the existing schemas.
- Changing capability grants, JSON Schema validation, resource limits, cache
  policy, or agent retry policy.
- Changing cache eligibility, cache-key identity, or cache-entry contents. Making
  an already captured cache write visible to a later ordinary-HOF callback is a
  consistency fix, not a new cache policy.
- Guaranteeing recovery of detailed records from a worker killed before it can
  report them. The shared atomic activity and quota counters remain the safety
  authorities for that case.
- Combining this refactor with prompt, prelude-contract, model-provider, or
  Viewer features.

## Proposed internal contracts

### One `Effects` value

Add `PtcRunner.Lisp.Eval.Effects` with a struct resembling:

```elixir
%Effects{
  tool_calls: [],
  parallel_calls: [],
  prints: [],
  prelude_call_counts: %{},
  tool_cache: %{}
}
```

The implementation may retain `pmap_calls` as the field name if changing it
would add conversion noise. There must still be exactly one canonical field
set and one constructor.

`Effects` owns:

- `empty/0`;
- recording one bounded print, tool call, parallel call, prelude call, or cache
  write;
- extracting the legacy effect-bearing fields from an `EvalContext` only while
  a temporary migration adapter is required;
- applying an effect delta to an `EvalContext`;
- computing a baseline-relative delta where a worker or callback starts from a
  cumulative context;
- merging two deltas in documented evaluator order;
- count addition and cache last-writer precedence; and
- conversion to existing public result/trace shapes at the outer boundary.

List ordering must be specified in terms of semantic execution order. Internal
prepend order may remain for efficiency, but callers must not independently
reimplement its reversal rules. Cache precedence must be deterministic and
consistent with sequential evaluation.

Prefer a struct over an untyped map so a missing field is detected during
development instead of by a later `Map.fetch!/2` path.

The final `EvalContext` representation contains one `effects: Effects.t()`
field. Its five current top-level fields are migration inputs, not a second
permanent representation, and must be removed with the temporary adapters.
All evaluator code reads or updates effects through `Effects`; direct struct
updates of `tool_calls`, `pmap_calls`, `prints`, `prelude_call_counts`, or
`tool_cache` do not remain after migration.

The ordering algebra is explicit. Effect lists are stored newest-first inside
the evaluator. `Effects.merge(newer, older)` concatenates each list as
`newer ++ older`, adds counts, and lets `newer` win cache-key conflicts. A
separate input-order helper merges indexed parallel deltas so the final public
reversal reports lower input indexes first. No caller infers merge direction
from argument names or performs an extra reversal.

### One capture stack

Replace both current effect stacks with one private capture module backed by a
single process-dictionary key. It provides two bracketed operations around a
known baseline context:

```elixir
Capture.run_outcome(baseline_context, fn -> ... end)
Capture.run_value(baseline_context, fn -> ... end)

# => {:ok, value, final_context}
# => {:error, reason, final_context}
# => {:control, :return | :fail | :recur, value, final_context}
# => {:raise, kind, reason, stacktrace, final_context}
```

`run_outcome/2` requires its callback to return the evaluator outcome protocol.
`run_value/2` treats every callback return as a plain value, even when that value
is a tuple resembling `{:ok, ...}` or `{:error, ...}`. It wraps the value before
capture interprets it. Host-callable adapters must choose one operation
explicitly; capture never guesses from tuple shape.

All exits pop their frame exactly once. The frame is a baseline-relative
`Effects` delta. When the callback returns or aborts with a context that already
contains the same effects, capture normalization **replaces** that context's
effect field with `Effects.merge(frame, baseline_context.effects)`; it never
adds the frame to the returned context. This replacement rule makes the frame
authoritative at the callback boundary and prevents double counting. If an
error has no context yet, the bracket attaches the normalized effects to the
baseline context. Nested captures merge the inner delta into the parent only
through `Effects`; the parent does not separately inspect the inner context.

Effects accumulated by earlier callbacks must also be visible during later
callbacks, not merely attached to the final result. Capture therefore exposes:

```elixir
Capture.materialize_context(context)
```

Each frame stores the stable baseline effects supplied when it was opened. The
operation returns the given context with its effect field **replaced** by
`Effects.merge(Capture.current_effects(), Capture.baseline_effects())`; it never
merges into the context's current effect field. Materialization is therefore
idempotent even if the input context was previously materialized, while
preserving its non-effect fields. Every host callback invocation that can
evaluate Lisp or invoke a runtime callable obtains its context through this
operation. When opening a nested capture, its stable baseline is the
materialized parent context. This preserves live cache visibility and tool-call
reservation behavior across HOF iterations.

Process-local storage is acceptable here because Elixir `Enum` callbacks
cannot return an updated `EvalContext` without changing the host function's
contract. It remains a hidden implementation adapter, not a second source of
truth. Tests must prove that the stack is empty after success, expected abort,
throw, ordinary exception, timeout propagation, and nested capture.

All effect-producing context operations must pass through one recording seam.
No special callable, including HOF `println`, may mutate the capture map
directly. Bounded formatting happens before recording.

### One expected-outcome protocol

Introduce one internal outcome representation with these concrete cases:

```elixir
{:ok, value, EvalContext.t()}
{:error, reason, EvalContext.t()}
{:control, :return | :fail | :recur, value, EvalContext.t()}
```

At evaluator/module boundaries, expected type and evaluation errors, contract
failures, tool failures, parallel failures, and Lisp control signals use this
protocol. An outcome never carries a second effect delta: its context contains
the normalized cumulative `Effects`. The handler for `recur` deliberately
reuses only the state that current `recur` semantics retain—new argument values,
effects, and the loop counter—and does not accidentally make unrelated closure
state persistent.

Where a plain host callback cannot return an expected outcome, use one private
abort carrier containing that semantic outcome. The surrounding capture frame,
not the carrier, is the authoritative effect delta and normalizes the outcome
context by replacement as described above. Every callback adapter handles that
one carrier uniformly. `ToolError`, `ContractError`, `ParallelError`, and
`ExecutionError` no longer act as separate expected-error transports.
Unexpected VM/runtime exceptions and resource termination remain distinct and
retain their stacktraces. Capture cleanup may attach the accumulated context to
an unexpected raise envelope, but intermediate adapters re-raise it rather than
classifying it as an expected outcome.

Scope normalization remains owned by the evaluator adapter that understands the
callable. Before constructing an outcome or private carrier it must:

1. restore the caller's `user_ns`, `env`, `locals`, prelude-caller stack, and
   origin/authority state;
2. tag a returned prelude closure and perform output-contract validation where
   current semantics require it; and only then
3. hand the scope-safe context to capture, which replaces only its `effects`
   field.

Capture never selects or restores lexical, namespace, or authority state. This
ordering applies to direct and HOF `return`/`fail` paths so a generic
context-bearing control outcome cannot expose private prelude state.

This does not require exposing exceptions to PTC-Lisp or changing final error
classification. The outer evaluator still converts the internal outcome into
the current `Lisp.run/2` result.

### One parallel worker envelope

Every evaluator-owned parallel worker returns one envelope containing:

- worker index;
- success value or expected failure;
- child trace metadata; and
- the worker's `Effects`.

The runner, not the worker callback, attaches the authoritative input index.
Worker payloads do not carry a second caller-supplied index that could disagree
with the runner's scheduling state.

`ParallelRunner` schedules, monitors, cancels, drains, and returns indexed
worker envelopes. It must not recognize `ContractError` or construct
`parallel_contract_error`/`parallel_effect_error` tuples. The evaluator owns
the mapping from a worker failure to PTC-Lisp `pmap`/`pcalls` errors and agent
contract feedback.

On failure, the runner returns the failing envelope plus successful envelopes
already received before or during cancellation cleanup. Completed envelopes
are sorted by input index exactly once. The evaluator then merges their effects
using `Effects`; it does not pattern-match several historical worker tuple
arities.

An abnormal worker exit without an envelope retains the existing stable
timeout, heap, capacity, or runtime-error classification. Detailed effects from
that worker may be unavailable, but the shared capability-activity and quota
counters must already reflect any provider invocation that began.

Once `ParallelRunner` has been invoked, the evaluator appends one outer
`pmap_calls` record on success or failure. A type, arity, or other preflight
failure before scheduling begins does not create a record. A failed-operation
record uses the existing shape with these semantics:

- `count` is the total number of input work items;
- `success_count` is the number of retained successful envelopes;
- `error_count` is `count - success_count`, including the failing item, timed
  out or cancelled items, and items not started because of terminal capacity
  failure;
- child trace ids and steps come from every retained successful or failing
  envelope, including the failing worker when it returned one; and
- a worker killed without an envelope contributes to `error_count` but cannot
  contribute child metadata or detailed effects.

The evaluator merges all retained worker effects first, then appends the outer
failed-operation record so nested capture and public reversal preserve the
defined ordering.

## Implementation plan

### Phase 1: Characterize stable semantics and specify effect corrections

1. Add table-driven coverage over these execution paths:
   - top-level sequential evaluation;
   - an ordinary HOF such as `map`;
   - `pmap`;
   - `pcalls`;
   - a parallel operation nested inside an ordinary HOF and vice versa;
   - `loop`/function `recur`; and
   - `doseq`, whose analyzed form uses `loop`/`recur`.
2. Cover success, type error, contract input/output error, tool error,
   `return`, `fail`, `recur`, loop-limit failure, timeout, heap termination, and
   worker-capacity failure where the path supports them.
3. For each relevant case assert tool calls, prints, parallel records, prelude
   counts, cache contents, final failure reason, and retryable classification.
4. Add explicit regression cases where one sequential form or earlier HOF
   callback records an effect and a later form or callback returns an ordinary
   error, raises `ToolError`, or signals `return`/`fail`. The expected result
   retains the already-executed effect even when current code drops it.
5. Separate assertions into:
   - stable value, error-shape, ordering, limit, and retry behavior that must
     remain unchanged; and
   - the enumerated missing-effect corrections that deliberately change ledger,
     count, print, parallel-record, or cache content.
6. Assert deterministic input ordering with workers completing out of order.
7. Assert that repeated identical runtime-callable invocations within one HOF
   continue to observe earlier cache writes, produce a cache hit, and do not
   reserve a second tool call. Add the equivalent ordinary-closure HOF
   regression with the same expected behavior; it is an intentional correction
   to the current missing live-cache overlay.
8. Characterize direct and HOF prelude `return`/`fail` scope restoration:
   caller memory survives, private `user_ns` and inner `env`/`locals` do not
   escape, origin authority is restored, and returned closures retain only the
   intended namespace tag.
9. Assert failed `pmap`/`pcalls` records use the defined success, non-success,
   cancellation, capacity, and child-metadata semantics.
10. Assert no double counting through nested captures or repeated context
    materialization.
11. Assert process-dictionary capture keys are absent after every exit class.
12. Add unit or property tests for effect merge identity, associativity under
   the documented ordering, count addition, and cache precedence.

These tests are the migration oracle. Stable-behavior assertions characterize
the current runtime; missing-effect, failed-parallel-record, and ordinary-HOF
cache-visibility regressions encode the corrected behavior before implementation
and are expected to fail until the owning phase lands. Do not rewrite either
class to mirror an intermediate implementation.

### Phase 2: Introduce `Effects` without changing transport

1. Add the struct and its canonical operations.
2. Add `effects: Effects.t()` to `EvalContext` and route construction, access,
   baseline-delta calculation, recur preservation, and public-result conversion
   through it.
3. Replace duplicated empty maps and merge helpers in `Eval`, `Apply`,
   `Eval.Context`, and `EffectCapture` with `Effects` calls.
4. Keep narrow temporary conversion functions at module boundaries while both
   old transports still exist. Mark them for deletion in this plan; new code
   must not call legacy raw-field helpers.
5. Route bounded `println`, tool ledger entries, parallel records, prelude
   counts, and cache writes through the same recording seam.
6. Remove the five raw effect fields from `EvalContext` and update its type once
   all direct field users have migrated. Do not proceed with two permanent
   representations.
7. Run focused evaluator tests and `mix precommit` before proceeding.

This phase should be reviewable as a behavior-preserving data-model change.

### Phase 3: Replace the two capture stacks with one

1. Implement `run_outcome/2` and `run_value/2` for all success, abort, throw,
   and exception paths, including the baseline-replacement rule and an explicit
   callback-result contract.
2. Migrate ordinary HOF adapters from `:__ptc_hof_stack`.
3. Migrate parallel workers from the current `EffectCapture` stack.
4. Add idempotent `materialize_context/1` and use it before every host callback
   that can evaluate Lisp or invoke a runtime callable. Open nested captures
   from a materialized parent baseline.
5. Wrap the top-level evaluator boundary so ordinary sequential errors that do
   not yet return a context still receive the capture frame before result
   assembly.
6. Delete direct process-dictionary access from `Apply`, `RuntimeCallable`, and
   special callables.
7. Delete the superseded stack and all duplicate merge/pop/drop helpers.
8. Prove nested HOF/parallel combinations produce the same effects exactly
   once and leave no process-local state behind.

### Phase 4: Normalize expected outcomes

1. Add the internal outcome type and the single private host-callback abort
   carrier.
2. Convert contract, tool, Lisp control, and parallel expected failures at
   their ownership boundaries. Include `recur`, while preserving its current
   state-retention semantics.
3. Convert ordinary sequential and HOF-returned errors to context-bearing
   outcomes at the nearest evaluator boundary so prior effects survive.
4. Restore caller namespace, lexical, and origin state before constructing a
   control outcome or private carrier; capture may replace only `effects`.
5. Make the private carrier contain only the outcome; capture owns and applies
   the delta by replacement exactly once.
6. Remove exception-specific effect-preservation rescue lists.
7. Delete `ToolError`, `ParallelError`, and `ContractError` after their expected
   failures use outcomes or the one private carrier.
8. Convert all current semantic `ExecutionError` uses to outcomes, including
   tool lookup/arguments/authorization/provider errors, type and arity errors,
   strict-data failures, and stable parallel timeout/heap/capacity failures.
   Delete `ExecutionError` as an expected-error transport. Unexpected host/VM
   exceptions retain their native exception classes and stacktraces instead of
   being wrapped in it.
9. Verify final public values, error tuples, messages, feedback details, and
   retryable flags remain byte-for-byte stable where they are contractual, while
   the enumerated missing-effect cases now retain their executed effects.

### Phase 5: Simplify the parallel boundary

1. Define one worker-envelope struct or tagged tuple.
2. Make `ParallelRunner` attach the authoritative input index and retain indexed
   envelopes on every evaluator-owned
   failure instead of using the optional `retain_completed_results` protocol.
3. Remove contract-specific and historical tuple-shape handling from the
   runner and evaluator collectors.
4. Centralize completed/failing-worker effect merging in one evaluator helper.
5. Append the existing `pmap_calls` record on every post-scheduling success or
   failure using the defined count and child-metadata semantics.
6. Retain the existing cancellation, monitor cleanup, global worker budget,
   deadline, and heap-limit behavior.
7. Add repeated concurrency tests or a bounded stress test for result/cancel
   message races without using `Process.sleep/1`.

### Phase 6: Extract ownership-focused modules

Only after the protocols are uniform:

1. Move pmap/pcalls evaluation and worker-result classification into
   `PtcRunner.Lisp.Eval.Parallel`.
2. Keep scheduling and process lifecycle in `Eval.ParallelRunner`.
3. Keep effect representation/capture in `Eval.Effects` and its private capture
   helper.
4. Keep host-callable adaptation in one small adapter module rather than
   spreading it across `Eval`, `Apply`, and `RuntimeCallable`.
5. Leave expression evaluation and public result assembly in `Eval`.
6. Update module documentation to state each ownership boundary and delete old
   compatibility helpers, legacy effect-field adapters, and historical outcome
   shapes rather than retaining shims.

### Phase 7: Documentation and final verification

1. Update the maintainer guide's evaluator architecture and parallel
   accounting sections, including the corrected retention of already-executed
   effects on expected exits.
2. Update the PTC-Lisp specification only if its documented evaluation semantics
   need clarification. The ledger-content correction uses existing result
   fields and is expected to require maintainer documentation and tests, not a
   new language or public-schema contract.
3. Run focused tests after every phase, then `mix precommit` and `mix prepush`.
4. Run an independent review with particular attention to effect ordering,
   cleanup after abnormal exits, cache precedence, and retry safety.
5. Keep implementation commits separated by phase so each review has one
   semantic concern.

## Acceptance criteria

1. Exactly one canonical `Effects` type owns every evaluator effect field, and
   `EvalContext` embeds that value rather than duplicating its five fields.
2. Exactly one process-local capture stack is used for HOF and parallel effect
   transport; `:__ptc_hof_stack` and the duplicate parallel stack are removed.
3. No evaluator module constructs an ad hoc empty effect map or reimplements
   merge ordering/cache precedence.
4. Host adapters explicitly select `run_outcome/2` or `run_value/2`; a plain
   tuple value is never inferred to be an evaluator outcome.
5. Every Lisp-evaluating host callback materializes its context from its stable
   baseline and current frame, so earlier callback cache writes and counts are
   visible during execution without double application.
6. Every expected evaluator exit carries one normalized cumulative context;
   `return`, `fail`, and `recur` use the same control-outcome protocol, and the
   private callback carrier contains no second effect delta.
7. `ToolError`, `ContractError`, `ParallelError`, and `ExecutionError` are not
   separate expected-error transports. Expected reasons use outcomes or the one
   private carrier; unexpected exceptions retain native classes and stacktraces.
8. Direct and HOF control outcomes restore caller namespace, lexical, prelude,
   and origin state before capture replaces only `effects`; private prelude
   scope cannot escape through a context-bearing outcome.
9. `ParallelRunner` contains no prelude-contract-specific classification.
10. Parallel success and retained completed-worker effects are deterministic in
    input order, independent of completion order.
11. Every post-scheduling failed `pmap`/`pcalls` appends one outer record with
    the defined success/non-success counts and all available child metadata;
    preflight failures append none.
12. Nested HOF/parallel effects are neither lost nor counted twice.
13. An effect executed before a later sequential or HOF type error, tool error,
    `return`, or `fail` remains present in the existing result ledger, count,
    print, parallel-record, and cache fields as applicable.
14. Apart from those enumerated missing-effect corrections, bounded prints,
    tool ledgers, parallel records, prelude counts, and cache writes retain
    current public behavior.
15. Capture process-dictionary state is absent after success, expected failure,
    control exit, throw, ordinary exception, timeout, and nested execution.
16. Retryability remains false whenever the authoritative complete evaluation
    recorded capability activity, including activity from a worker that later
    fails or is killed.
17. Tool-call and parallel-worker limits remain shared, atomic, and unchanged.
18. Existing PTC-Lisp result shapes, trace schemas, error classifications, and
    agent feedback remain compatible with the immediately preceding commit. The
    only observable changes are restored audit content and the explicitly
    specified ordinary-HOF cache visibility correction.
19. The evaluator's major modules have narrower documented responsibilities;
    extraction does not merely move duplicated protocols to new files.
20. `mix precommit` and `mix prepush` pass, including the characterization
    matrix and concurrency race coverage.

## Review checkpoints

To avoid another oversized review, request an independent review after each
behaviorally meaningful phase:

1. `Effects` algebra and migration adapters.
2. Single capture stack and cleanup invariants.
3. Expected-outcome/abort-carrier normalization.
4. Parallel worker envelope and cancellation behavior.
5. Final module extraction and documentation.

Do not begin the next checkpoint while the previous diff has unresolved
correctness findings. Mechanical extraction should be kept separate from
semantic changes whenever possible.

## Principal risks

- Reversing internal prepend order twice, or not at all.
- Double-recording an inner effect in both its own frame and its parent.
- Adding a captured delta to an outcome context that already contains it instead
  of replacing the context's effect field at the callback boundary.
- Implementing materialization as an incremental merge instead of replacement
  and thereby duplicating effects, or failing to materialize before a later
  callback and thereby missing a live cache entry.
- Treating a plain tuple returned by a host function as an evaluator outcome.
- Applying a cache delta with the wrong last-writer precedence.
- Leaking a capture frame after an unexpected throw or exception.
- Restoring effects before scope normalization and allowing private prelude
  namespace, lexical, or origin state to escape.
- Freezing known missing-effect behavior into characterization tests under the
  name of compatibility.
- Letting `recur` retain unrelated closure state while moving it onto the common
  control protocol.
- Masking an external cancellation while draining worker messages.
- Misstating failed parallel counts or dropping available child metadata during
  cancellation cleanup.
- Treating a missing killed-worker ledger as proof of no capability activity.
- Converting a stable resource error into a generic evaluator failure.
- Expanding scope into prompt, Viewer, or public-language work.

The characterization suite and phased review checkpoints are explicit gates
against these risks.
