# Make the shipped agent loop understandable and adaptable

**Status:** core refactor proposed; no implementation has started. The
customization contract is deliberately decision-gated until the smaller shell
exists. Written 2026-08-27 from the current `origin/main`, the August CodeScene
report, source-history analysis, the component/public-export contract, and
focused test runs described below.

`agent.core` should remain the safe shipped default while becoming a small
example an application author can understand and adapt. The implementation
should be changed in characterized slices, not rewritten wholesale. The chosen
core shape is a functional state machine behind a thin effectful loop. After
that extraction, use the real shell and concrete customization examples to
choose between documenting custom shells, adding a narrow policy entry, or
shipping no new customization API yet. Protocol parsing, bounds, effect
provenance, evaluation admission, and authenticated failure taxonomy remain
fixed in the shipped default.

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
- Reduce the amount of orchestration an application must understand or copy,
  then choose the smallest supported customization contract justified by the
  extracted shell and real application examples.
- Preserve the current public outcome taxonomy, transcript correlation,
  phase semantics, effect-sensitive retry rules, hard bounds, annotations,
  and result-contract behavior unless a separately characterized bug is found.
- Keep Kernel-authenticated facts and safety decisions authoritative in the
  shipped shell and in any eventual supported customization contract.
- Make important state transitions testable as data while retaining
  integration coverage through the compiled shipped PTC-Lisp bundle and real
  Kernel owner.
- Restore the CodeScene code health score to at least 8.0 and remove critical
  complexity findings from both the facade and the extracted state machine.

## Non-goals

- Do not generalize this into an arbitrary workflow framework.
- Do not make model-generated programs or manifest data supply executable
  callbacks. If a callback seam is eventually selected, callbacks are immutable
  functions authored by a selected workflow component and compiled into its
  bundle.
- Do not make `agent.native` protocol validation, Kernel tools, provider
  failure authentication, capability/effect provenance, or hard limits
  replaceable through any eventual customization seam.
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
   resolved model alias, retryability, and fail-fast projection. Also assert
   exact raw `tool/llm-request`, `llm/request`, inspection, and `run-outcome`
   error maps so a later catalog consolidation cannot add a field to any public
   or retained envelope.
3. State preservation across one correction followed by a phase transition:
   retained definitions, prompt transition event, `closing?`, narration/tool
   correlation, and turn budgets must survive together.

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

### 4. Let applications shadow shipped policy component IDs

Rejected. Local components cannot bind the ID of a shipped component, and a
per-invocation override replaces source without changing the attested dependency
graph. Relaxing either rule would silently alter every consumer of that ID and
undermine pinned-profile auditability. An explicit call from application source
is preferable because the selected replacement is visible where it is used.

### 5. Functional state machine plus a thin effect shell

Chosen. One discoverable support component owns a deliberately small state
transition contract; `agent.core` performs the bounded effects it commands.
This removes the nested decision tree without exporting every incidental helper
and gives the post-extraction decision gate a concrete shell to evaluate.

### 6. Commit now to either custom shells or a policy map

Deferred. A custom shell over `agent.machine` is broader but makes its complete
event/command protocol an application-facing contract. A narrow policy map is
smaller but may omit the adaptations users actually need. The current file is
the wrong evidence for choosing: extract the machine first, inspect the final
shell, and exercise concrete customization examples before approving either
surface.

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
implementation should prefer two exports and must justify any additional
export.

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
command includes only the data the shell needs for that effect. Events fed back
to the machine use a closed vocabulary. Unknown commands and events fail
closed.

The exact keywords are implementation details until characterization and the
extraction establish them. Once shipped, even the minimum `agent.machine`
exports are callable public component contracts. Document their invariants in
source and the generated prelude reference, but do not advertise the complete
event/command protocol as the end-user customization API before the decision
gate evaluates that cost.

### Independent failure-catalog track

The repeated LLM failure spellings in `ProviderError`, `SafeMetadata`, and
`agent.core` should still converge on one host-owned catalog, but that cleanup
does not block state extraction. Its pure PTC projection belongs in a small,
tracked, generated discoverable `agent.failure` component so it neither adds a
runtime effect nor modifies the public LLM envelope. This work is Slice 0b and
may land before, alongside, or after Slices 1–2.

### Customization decision after extraction

Do not commit to a policy API in advance. After Slice 2, exercise these three
candidates against the actual reduced shell:

1. Document `agent.core` as the small example shell and let applications write
   a custom shell over `agent.machine`. This permits transcript and annotation
   changes, but makes the machine protocol an intentional application contract
   and leaves shell authors responsible for effect ordering, result validation,
   and authenticated failure propagation.
2. Add a narrow callback map for prompt initialization/render/transition,
   bounded feedback, and advisory continuation. This preserves the shipped
   shell but freezes hook names and shapes that may not match real demand.
3. Ship no new customization API yet. Retain component overrides and the
   smaller copied-shell path until an application demonstrates a stable seam.

The decision must compare final shell size, safety-sensitive responsibilities,
two or more real customization examples, and the public-contract cost of the
machine protocol versus narrow hooks. No candidate is the default merely
because it was sketched first.

If the callback map is selected, a plausible API is a zero-arity
`agent.core/default-policy` plus `agent.core/run-outcome-with-policy`. Validate
the closed key set and `fn?` values before model dispatch, but do not add public
arity introspection for this feature. A wrong-arity late hook may fail after one
provider request through existing bounded evaluator diagnostics; test that it
does not trigger a second request. Normally returned hook decisions remain
advisory inside fixed bounds: they cannot extend budgets, repeat an unsafe
effect, bypass validation, or reinterpret failure evidence.

Callbacks remain ordinary trusted workflow code. They may perform authorized
effects, and PTC-Lisp `return`/`fail` signals propagate out of higher-order and
prelude calls. If hooks are selected, document those facts, recommend pure or
read-only callbacks, test effectful/error/control-signal cases, and add no
generic recovery or arity-reflection language feature.

### Keep user-facing and support surfaces distinct

`agent.core` remains `:prompt` because its ordinary entries are useful workflow
functions. Mark `agent.machine`, `agent.failure`, and any later approved policy
exports `:discoverable` so they are inspectable without entering the
model-facing inventory. They remain callable by design; documentation must say
that visibility is not an authority boundary.

Do not split more components merely to improve file-size metrics. Extract
another public component only when it has a cohesive, reusable contract that
can be stated without mentioning `agent.core` private variables.

## Implementation slices

Each core slice lands independently with green focused tests. Slice 0b is a
separate cleanup track, not a prerequisite for Slices 1–2. Slice 3 approves a
customization direction before any corresponding public API is implemented.

### Slice 0a — characterize current behavior

1. Add the three integration matrices listed above, with a deterministic
   scripted LLM and the real shipped bundle/Kernel.
2. Record the current CodeScene findings and focused command timings in the PR
   description; do not add a source coverage percentage.

Exit criterion: the new tests fail under deliberate mutations of phase-boundary
retry, provider classification, unsafe closing, and prompt transition, then
pass on unchanged behavior.

### Slice 0b — consolidate the failure catalog independently

1. Introduce one host-owned LLM failure catalog that canonicalizes the admitted
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

Exit criterion: every host and PTC consumer enumerates the same catalog, while
the Slice 0a assertions prove byte-for-byte envelopes, inspection data, events,
usage, and failure precedence remain unchanged. This slice may land before,
alongside, or after Slices 1–2.

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
   shipped component with the minimum constructor/advance surface required by
   the characterized shell.
2. Keep all actual effects in `agent.core`. Add exhaustive direct reducer tests
   for the closed event/command table and invariants, not for string formatting
   or trivial field access.
3. Add `agent.machine` to `PtcRunner.Kernel.Library` and update the appropriate
   dependency closures, manifest/library tests, generated prelude docs, and
   semantic revision inputs. If Slice 0b has landed, make its `agent.failure`
   dependency explicit; otherwise retain the characterized classifier until
   0b lands. Do not regenerate
   `priv/semantic_build_projection.json` on the feature branch.
4. Delete the superseded state-machine helpers and branches; add no
   compatibility layer. The decision gate must inspect the real reduced shell,
   not a transitional file that still contains dead orchestration.

Exit criterion: `agent.core` contains no phase/evaluation decision tree, and
the reducer can be tested without an LLM callback or Kernel owner.

### Slice 3 — provisional customization decision gate

1. Measure the extracted `agent.core`: logical and physical size, remaining
   branches, public entries, and every safety-sensitive responsibility that a
   custom shell would have to reproduce.
2. Build at least two throwaway application components against the extracted
   code: one replacing prompt/feedback behavior and one changing transcript or
   annotation behavior. Exercise the real Kernel and prove hard limits, unsafe
   closing, result validation, provider taxonomy, events, and usage.
3. Compare the three candidates above. Account explicitly for the cost of
   supporting the full `agent.machine` protocol, the expressiveness and
   permanence of narrow hooks, and the option to wait for stronger demand.
4. Record the decision in the owning component docs or an approved follow-up
   issue. Do not merge `default-policy`, `run-outcome-with-policy`, or another
   customization export merely to complete this plan.

If a callback API is selected, its follow-up implementation must prove private
closure passing, transitive tool requirements, bounded diagnostics, effectful
hooks, runtime errors, non-local `return`/`fail`, and wrong-arity failure without
a second provider call. Update `docs/guides/building-agents.md`,
`docs/guides/components-and-preludes.md`,
`docs/reference/component-contracts.md`, `docs/agent-library-reference.md`,
owning PTC-Lisp docstrings, generator prose/assertions, and generated docs only
for the contract actually approved.

Exit criterion: a reviewed decision names the smallest evidence-backed
customization contract, or explicitly chooses to ship none. Slices 0a–2 remain
valuable and complete if the decision is to wait.

### Slice 4 — simplify and measure

1. Delete any remaining superseded documentation or incidental helpers exposed
   by the customization exercises; add no compatibility layer.
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
- **The machine protocol becomes an accidental customization API.** Export only
  constructor/advance operations; keep formatting, classification, and state
  access private. Treat `:discoverable` as presentation, not privacy, and make
  Slice 3 decide explicitly whether direct application use is supported.
- **A policy API is frozen before demand is understood.** Keep Slice 3 as a
  decision gate. Compare real prompt, feedback, transcript, and annotation
  adaptations against the extracted shell before adding hooks.
- **A selected callback seam weakens safety or obscures authority.** If chosen,
  validate closed keys and `fn?` values before effects, make normal decisions
  advisory inside fixed bounds, and prove compile-time dependencies,
  attach-time authority, effectful/error/control-signal behavior, and bounded
  diagnostics. Never delegate protocol, evaluation admission, effect
  provenance, result validation, or failure authentication.
- **Wrong hook arity is discovered after a provider call.** Accept that narrow
  configuration cost instead of adding a language feature; fail through the
  existing bounded evaluator path and prove no second provider request occurs.
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
