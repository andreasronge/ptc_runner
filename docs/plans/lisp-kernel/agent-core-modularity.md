# Make the shipped agent loop understandable and adaptable

**Status:** proposed; no implementation has started. Written 2026-08-27 from
the current `origin/main`, the August CodeScene report, source-history analysis,
the component/public-export contract, and focused test runs described below.

`agent.core` should remain the safe shipped default while becoming a small
example an application author can understand and reuse. The implementation
should be changed in characterized slices, not rewritten wholesale. The chosen
shape is a functional state machine behind a thin effectful loop, plus one
explicit policy entry for application-owned prompt, feedback, and continuation
decisions. Protocol parsing, bounds, effect provenance, evaluation admission,
and authenticated failure taxonomy remain fixed.

## Why this work is needed

The [CodeScene report from August
2026](https://codescene.io/projects/83886/jobs/7332058/results?scope=month&aspect=#code-health)
scores `priv/preludes/kernel/agent.core.clj` at 3.78, down from 8.14, with
critical Bumpy Road, Deep Nested Complexity, and Code Health Degradation
findings. Its primary hotspot is `run-outcome*`: 275 logical lines, cyclomatic
complexity 40, nesting depth 13, and 12 bumpy blocks in the analyzed revision.
The file is now 779 physical lines. `transitioned-state` and
`continuation-state` take 8 and 11 arguments respectively, which is a symptom
of implicit loop state rather than an isolated problem.

This is sustained product pressure rather than one anomalous commit. From
2026-07-24 through 2026-08-26, 42 commits changed this file, adding 981 lines
and deleting 340. The loop currently owns all of these decisions in one nested
form:

- agent configuration and phase validation;
- phase-local and global turn bookkeeping;
- prompt state, transcript correlation, and request bounds;
- LLM dispatch and action normalization;
- source admission, subordinate evaluation, and result validation;
- safe retry, one-shot unsafe closing, and phase transition policy;
- subject, provider, host, quota, and turn-limit failure classification; and
- the public outcome and fail-fast entry contracts.

The existing split into `agent.prompt`, `agent.feedback`, `agent.retry`, and
`agent.native` helps at the edges, but `run-outcome*` still coordinates every
branch and carries six loop variables through repeated `recur` calls.

There is also a product mismatch. The guides correctly say applications can
replace policy without replacing Kernel enforcement, but a permanent custom
prompt cannot replace the shipped `agent.prompt` dependency of `agent.core`.
An application must currently copy or replace the complete loop, or use a
per-invocation component override whose dependency graph is fixed. The most
safety-sensitive code is therefore also the code users are pushed to fork.

## Goals

- Make the default `agent.core` entry read as a short sequence of effects and
  state-machine decisions rather than a nested catalogue of every outcome.
- Give application components a supported way to customize prompt rendering,
  correction feedback, and bounded continuation policy without copying the
  provider/evaluation loop.
- Preserve the current public outcome taxonomy, transcript correlation,
  phase semantics, effect-sensitive retry rules, hard bounds, annotations,
  and result-contract behavior unless a separately characterized bug is found.
- Keep Kernel-authenticated facts and safety decisions authoritative for every
  normally returned policy decision. A policy may choose less work, but cannot
  extend a turn/evaluation/request bound, repeat an unsafe effect, reinterpret
  provider evidence, or bypass validation through its returned value.
- Make important state transitions testable as data while retaining
  integration coverage through the compiled shipped PTC-Lisp bundle and real
  Kernel owner.
- Restore the CodeScene code health score to at least 8.0 and remove critical
  complexity findings from both the facade and the extracted state machine.

## Non-goals

- Do not generalize this into an arbitrary workflow framework.
- Do not make model-generated programs or manifest data supply executable
  callbacks. Policies are immutable functions authored by a selected workflow
  component and compiled into its bundle.
- Do not make `agent.native` protocol validation, Kernel tools, provider
  failure authentication, capability/effect provenance, or hard limits
  replaceable through the policy seam.
- Do not preserve private helper names or implementation structure. This is a
  0.x library and the refactor should delete superseded code.
- Do not add implementation-mirroring unit tests for the current nested
  helpers. Characterize observable behavior first; add direct tests only for
  the extracted reducer's decision contract and invariants.
- Do not add a compatibility shim for old copied versions of `agent.core`.

## Existing safety net and its limits

The current suite is much stronger than line coverage would suggest:

- `mix test test/ptc_runner/kernel/agent_library_test.exs --max-failures 1`
  passed 109 tests on 2026-08-27.
- The focused contention, capability-facade, and named-mission files passed 27
  tests with 2 prerequisite-gated exclusions.
- These tests compile the shipped PTC-Lisp components, execute the real Kernel
  with deterministic scripted LLM callbacks, and assert results, correlated
  requests, usage, events, cleanup, failure provenance, phase transitions,
  unsafe closing, and result-contract correction.

That is the correct refactor safety net. BEAM coverage cannot answer how much
of a `.clj` prelude ran, and the project's coverage threshold is currently
zero, so a percentage would give false confidence. The evidence supports a
staged refactor, not a single large rewrite.

Before moving behavior, add table-driven integration characterization for the
remaining high-risk boundaries:

1. A protocol error, retryable evaluation error, terminal-source rejection,
   and unsafe failure on the last turn of a non-final phase. Assert whether the
   loop transitions, closes, or terminates; also assert phase index, phase turn,
   global agent turn, next mission, and transcript order.
2. Every admitted provider/protocol/whole-request timeout reason and its kebab
   and underscore spellings. Assert the returned `run-outcome` envelope,
   resolved model alias, retryability, and fail-fast projection. Replace the
   currently duplicated lists in `ProviderError`, `SafeMetadata`, and
   `agent.core` with one host-owned closed catalog and a generated pure PTC
   projection, and make the matrix enumerate that catalog, so a new reason
   requires a test decision. Also assert exact raw `tool/llm-request`,
   `llm/request`, inspection, and `run-outcome` error maps: catalog sharing must
   not add a field to any public or retained envelope.
3. State preservation across one correction followed by a phase transition:
   retained definitions, prompt transition event, `closing?`, narration/tool
   correlation, and turn budgets must survive together.
4. Invalid policy values must fail before any provider request or subordinate
   evaluation, without reflecting closures or caller data into diagnostics.

Place new end-to-end cases in a focused
`test/ptc_runner/kernel/agent_core_characterization_test.exs` instead of
making the already large `agent_library_test.exs` a larger mixed concern.

## Options considered

### 1. Rewrite `run-outcome*` and rely on unit tests

Rejected. The hard behavior lives at the LLM, Kernel, result-contract, phase,
and effect-provenance boundaries. Tests that reproduce the current `cond` and
`case` branches would be easier to keep green than the actual contract.

### 2. Keep one namespace and only extract private functions

Useful as a first mechanical slice, but insufficient as the destination. It
can reduce nesting and argument counts, yet it leaves a 700-line customization
target and does not solve the fixed `agent.prompt` dependency.

### 3. Split helpers across several components

Rejected as the primary decomposition. PTC-Lisp has one namespace per
component, and cross-component calls require public exports. `defn-` helpers
cannot cross that boundary, while `:discoverable` only removes an export from
the prompt inventory; it does not make it private. A file-oriented split into
configuration, transcript, provider, and phase helpers would turn incidental
implementation details into callable application API.

### 4. Functional state machine plus a thin effect shell

Chosen. One discoverable support component owns a deliberately small state
transition contract; `agent.core` performs the bounded effects it commands.
Application policy is passed as first-class functions through one explicit
public entry. This creates a real reuse seam without exporting every helper.

PTC-Lisp already supports functions as values and callbacks in collection
values; shipped `cap/fold-pages` exercises the same caller-owned callback
shape. The first implementation slice must nevertheless prove private local
callbacks passed across a component boundary, transitive tool-requirement
accounting, and bounded diagnostics before committing to the final public
contract.

## Proposed design

### Two responsibilities

`agent.core` becomes the effect shell and default facade. It owns the public
`run*` functions, calls `llm/request`, `kernel/eval-with`/the existing Kernel
helpers, result validation, authenticated diagnostic tools, and
`workflow.event/annotate`. Its loop repeatedly interprets one closed command
from the state machine and feeds the resulting event back. It must not decide
phase, retry, transcript, or outcome taxonomy inline.

A new discoverable `agent.machine` component owns immutable configuration and
loop state, closed event classification, and command selection. It performs no
LLM, Kernel evaluation, annotation, diagnostic, or capability effect. Its
public surface is intentionally limited to constructor/advance operations (the
spike should prefer two exports, and must justify any additional export). A
separate generated discoverable `agent.failure` support component projects the
host-owned LLM failure catalog as one pure classification function. It exists
only to keep the catalog authoritative without modifying public LLM envelopes
or adding a runtime effect.

Keep immutable run context separate from changing loop state:

```clojure
{:context {:cfg ...
           :phases ...
           :total-max-turns ...
           :projector-kind ...}
 :state {:phase-index 0
         :phase-turn 0
         :agent-turn 0
         :messages [...]
         :prompt-state ...
         :closing? false}}
```

This replaces positional state threaded through 8- and 11-argument helpers.
The reducer returns a closed command such as request, evaluate, validate,
continue, return, subject-failure, provider-failure, or host-failure. Each
command includes only the data the shell needs for that effect. Policy-hook
invocation is also an explicit shell command: `agent.core` invokes the callback,
validates and bounds its answer, then returns a policy-result event to the
machine. The shell retains the validated policy map; it is not machine state.
Events fed back to the machine use a closed vocabulary. Unknown commands/events
fail closed.

This distinction is necessary because a callback is ordinary trusted workflow
code, not a pure function enforced by the language. The shipped prompt renderer
already calls `kernel/mission-model-context`, and a custom callback can call any
capability its component is authorized to use. The machine guarantees only how
a callback result may influence loop control; it cannot make callback execution
effect-free. Documentation must recommend pure or read-only policy hooks and
warn that an effectful hook is responsible for its own idempotency.

The exact keywords are implementation details until the spike and
characterization suite establish them. Once shipped, the two
`agent.machine` exports are public component contracts and must be documented
in their source and the generated prelude reference.

### Explicit policy seam

Add a discoverable zero-arity `agent.core/default-policy` function and a
discoverable `agent.core/run-outcome-with-policy` entry. Existing `run-outcome`,
`run-value`, `run-result-value`, `run-phased-result-value`, and `run` delegate
through the default policy and preserve their current contracts.

The initial policy contains only hooks backed by today’s replaceable policy
components:

- initialize, render, and transition prompt state;
- render bounded feedback for a closed loop event; and
- decide whether a retryable event should continue, subject to the machine's
  hard phase/turn and safety rules.

A custom component can derive the default map and replace only selected hooks:

```clojure
(defn run [task cfg]
  (agent.core/run-outcome-with-policy
    task
    cfg
    (assoc (agent.core/default-policy)
           :render-prompt (fn [state] (my.prompt/render state))
           :feedback (fn [event] (my.feedback/render event)))))
```

Policy validation happens once, before model dispatch. Require exactly the
closed keys, required arities, and callable values; reject missing, unknown, or
non-callable entries with bounded diagnostics that identify only the key and
expected shape. PTC-Lisp currently has `fn?` but no public safe arity query for
an arbitrary private closure, so Slice 0 must expose a bounded, non-invoking
`accepts-arity?` predicate before this pre-dispatch guarantee can ship. It must
reuse the evaluator's existing `PtcRunner.Lisp.Eval.Apply.accepts_arity?/2`
oracle rather than create a second arity table. The public predicate accepts a
callable and one non-negative integer and returns only a boolean; it never
returns a descriptor or exposes closure environment, body, metadata, or
captured values. Refactor the shared oracle so opaque runtime callables fail
closed when used for policy validation instead of inheriting `pcalls`' current
optimistic admission. Do not preflight by invoking hooks. Register the new
PTC-Lisp extension in `priv/functions.exs`, document it in the language
specification, generate the function reference, and test that both the policy
validator and `pcalls` derive their answers from the same structural logic.
Do not include a generic “handle event” hook, raw effect executor, arbitrary
result projector, or access to host-private diagnostic records.

The machine owns the final decision when policy and safety disagree:

- hard turn, transcript, program, observation, and capability limits win;
- an unsafe evaluation is never repeated, regardless of policy;
- at most one existing bounded closing turn is offered;
- a normally returned policy value cannot bypass result validation or
  terminal-only source checks;
- provider/host/subject provenance and fail-fast projection remain fixed; and
- policy may decline a retry but may not manufacture additional budget.

Calling a hook can itself perform an authorized workflow effect; the above
rules constrain the loop's reaction to a normally returned value, not
arbitrary trusted code the policy author placed inside the hook. PTC-Lisp has
no recovery construct, and callback `return`/`fail` signals deliberately cross
higher-order and prelude calls. Do not pretend that `agent.core` can contain
them: document those signals as a policy-contract violation that propagates
out of the calling workflow, and test that they are never reclassified as a
successful agent outcome. This is not a new authority escape—a component that
owns the workflow entry can already return or fail directly. Adding a generic
control-signal-catching primitive would broaden the language and is outside
this refactor. Runtime errors from normally invoked hooks retain the existing
bounded evaluator diagnostics.

### Keep user-facing and support surfaces distinct

`agent.core` remains `:prompt` because its ordinary entries are useful workflow
functions. Mark the policy seam and `agent.machine` support exports
`:discoverable` at export level so they are inspectable without adding them to
the model-facing inventory. They remain callable by design; documentation must
say that visibility is not an authority boundary.

Do not split more components merely to improve file-size metrics. Extract
another public component only when it has a cohesive, reusable contract that
can be stated without mentioning `agent.core` private variables.

## Implementation slices

Each slice lands independently with green focused tests. Do not combine the
state representation, component extraction, and customization API into one
review.

### Slice 0 — characterize and prove the seam

1. Add the four integration matrices listed above, with a deterministic
   scripted LLM and the real shipped bundle/Kernel.
2. Add a small compile-and-run spike proving a local component can pass private
   closures in a policy map to a shipped dependency, that the callbacks retain
   their intended dependencies, and that tool requirements remain enforced.
3. Refactor the structural logic behind
   `PtcRunner.Lisp.Eval.Apply.accepts_arity?/2` into the single arity oracle
   used by `pcalls`, and expose the bounded non-invoking `accepts-arity?`
   predicate needed by policy validation. Cover fixed, variadic, multi-arity,
   partial/composed, public-prelude, Java, opaque runtime-callable, and malformed
   values; opaque values must fail closed for policy admission. Prove the query
   never exposes or evaluates a closure body or captured environment. Register
   it in `priv/functions.exs`, specify it in
   `docs/ptc-lisp-specification.md`, and regenerate
   `docs/function-reference.md` with `mix ptc.gen_docs`.
4. Introduce one host-owned LLM failure catalog that canonicalizes the admitted
   provider, model-alias protocol, and whole-request timeout reasons. Make
   `ProviderError` and `SafeMetadata` consume it, and have the documentation
   generator project the same catalog into a small, tracked, generated
   `agent.failure` component with one pure `classify` export. `agent.core`
   calls that function on the unchanged bounded LLM envelope and sends only
   its closed result to the machine; delete its handwritten spelling table.
   Register the generated component, dependency closure, staleness assertion,
   and semantic revision input in this slice. The classifier must not add a
   field to the raw `tool/llm-request`, `llm/request`, inspection, or
   `run-outcome` envelope, and must not add a tool call, evaluator intrinsic,
   ledger entry, capability event, event-sink failure point, or new failure
   precedence. The existing `kernel-llm-provider-failure` operation remains
   the terminal evidence-consumption boundary for fail-fast propagation.
5. Record the current CodeScene findings and focused command timings in the PR
   description; do not add a source coverage percentage.

Exit criterion: the new tests fail under deliberate mutations of phase-boundary
retry, provider classification, unsafe closing, and prompt transition, then
pass on unchanged behavior.

### Slice 1 — make state explicit inside `agent.core`

1. Replace the six loop bindings and positional transition arguments with the
   separate context/state maps.
2. Introduce closed event and decision constructors as private helpers.
3. Extract one branch at a time in this order: protocol/limit/provider actions;
   source admission; evaluation outcomes; result validation; phase transition.
4. Keep every public export, dependency, emitted annotation, diagnostic, and
   request byte-for-byte compatible where the contract requires exact text.

Exit criterion: no behavior change in the characterization and existing agent
integration suites; no function has more than five positional parameters;
`run-outcome*` is an effect sequence rather than the branch implementation.

### Slice 2 — extract `agent.machine`

1. Move the now-pure reducer and immutable state construction into one new
   shipped component with the minimum public surface proven by Slice 0.
2. Keep all actual effects in `agent.core`. Add exhaustive direct reducer tests
   for the closed event/command table and invariants, not for string formatting
   or trivial field access.
3. Add `agent.machine` to `PtcRunner.Kernel.Library`, make its dependencies on
   the already-generated `agent.failure` projection explicit, and update the
   appropriate dependency closures, manifest/library tests, generated prelude
   docs, and semantic revision inputs. Do not regenerate
   `priv/semantic_build_projection.json` on the feature branch.

Exit criterion: `agent.core` contains no phase/evaluation decision tree, and
the reducer can be tested without an LLM callback or Kernel owner.

### Slice 3 — ship the policy API

1. Build the shipped default policy from `agent.prompt`, `agent.feedback`, and
   `agent.retry` callbacks inside the zero-arity `default-policy` function;
   dependency references in top-level `def` initializers remain forbidden.
   Make all existing entries delegate through it.
2. Add strict pre-dispatch policy validation and negative tests for every
   rejected shape. Add callback tests for an authorized read, an unsafe effect,
   a raised runtime error, and escaped `return`/`fail` signals. For normally
   returning and runtime-error hooks, assert the shell invokes each hook at
   most once per command and bounds every diagnostic. For `return`/`fail`,
   assert the existing workflow-level propagation explicitly and that the
   signal is never reclassified as an agent outcome.
3. Add an integration example with a local application component that replaces
   prompt and feedback behavior while reusing the shipped loop. Prove hard
   limits, unsafe closing, result validation, and provider taxonomy are
   unchanged under the custom policy.
4. Update `docs/guides/building-agents.md`,
   `docs/guides/components-and-preludes.md`, and
   `docs/reference/component-contracts.md` with the permanent customization
   path and its trust/authority boundary. Update the exact API in
   `docs/agent-library-reference.md`, the owning PTC-Lisp docstrings, and the
   customization prose in `Mix.Tasks.Ptc.GenDocs` that currently requires a
   copied custom loop. Update generator assertions and run `mix ptc.gen_docs`;
   do not hand-edit generated references.

Exit criterion: an application can permanently customize the documented hooks
under a new component ID without copying `agent.core` or using a component
override.

### Slice 4 — simplify and measure

1. Delete superseded private helpers, branches, and documentation; add no
   compatibility layer.
2. Run CodeScene on the changed tree. If either component retains a critical
   finding, simplify the state/event contract rather than moving code between
   files to chase the score.
3. Move durable contracts into the owning component docs, maintained guides,
   and specification. Remove this plan when the final approved slice lands.

Exit criterion: CodeScene score at least 8.0 for both changed components, no
critical Bumpy Road/Deep Nested Complexity finding, and the public support
surface is no larger than the documented use case requires.

## Verification for every implementation slice

Run the narrow commands first:

```text
mix test test/ptc_runner/kernel/agent_core_characterization_test.exs
mix test test/ptc_runner/kernel/agent_library_test.exs
mix test test/ptc_runner/kernel/agent_evaluation_contention_test.exs \
  test/ptc_runner/kernel/cap_agent_main_test.exs \
  test/ptc_runner/kernel/named_missions_e2e_test.exs
```

When component sources, dependencies, or generated docs change:

```text
mix ptc.gen_docs
mix precommit
MIX_ENV=dev mix docs --warnings-as-errors
scripts/ci/core-tests.sh --schedulers 4
```

The implementation PR must also inspect `git diff --check`, generated-artifact
staleness, the compiled library closure, and the default prompt inventory. Run
the relevant deterministic tutorial manifest offline as a final smoke test.
Live model E2E is not required for a behavior-preserving state-machine slice;
run it only when a slice changes provider-facing request semantics.

## Main risks and controls

- **A reducer becomes a second opaque blob.** Keep a closed event/command table,
  one transition owner, explicit invariants, and CodeScene acceptance on both
  files. Do not recreate the old nesting behind a new filename.
- **Public support API leaks implementation.** Export only constructor/advance
  operations; keep formatting, classification, and state access private inside
  `agent.machine`. Treat `:discoverable` as presentation, not privacy.
- **Policy callbacks weaken safety.** Validate them before effects and make
  normally returned decisions advisory inside fixed bounds. Invoke them as
  explicit shell effects, document that ordinary workflow authority and
  non-local `return`/`fail` semantics still apply, and test
  effectful/error/control-signal cases. Never delegate protocol, evaluation
  admission, effect provenance, result validation, or failure authentication.
- **Closure passing obscures capability requirements.** The Slice 0 spike must
  prove compile-time dependency and attach-time authority checks. If that proof
  fails, stop and design an explicit data-only policy protocol instead of
  weakening requirement validation.
- **Callable validation accidentally executes user code, leaks closure
  internals, or drifts from `pcalls`.** Expose only the existing structural
  arity decision as a bounded boolean, share one oracle, fail closed for opaque
  policy values, and prove it does not invoke, format, or traverse captured
  state.
- **Host failure classification changes observable execution.** Attach the
  host catalog only to a generated pure component, never to the runtime result
  envelope; do not introduce a private tool or evaluator call. Characterization
  must assert identical raw/public/inspection maps, events, capability counts,
  usage, and failure precedence.
- **Mechanical refactoring changes exact transcripts.** Assert complete request
  messages and annotations at the phase/error boundaries before extraction;
  keep formatting in existing policy components until the machine is stable.
- **The test suite gives false confidence through duplicated logic.** Prefer
  real Kernel integration for public behavior and mutation checks for the new
  characterization cases. Direct reducer tests cover invariants and the closed
  table only.
