# Lisp Kernel — Autonomous S21 Inner-Eval Domain Prelude Plan

**Status:** registered implementation spike for a future autonomous Codex
session on `exp/lisp-kernel`. Written 2026-07-09 after role-backed prelude
selection, D4 kernel TurnEvents, S20 SymbolInventory rendering, and host-held
multi-turn memory landed. No implementation or live comparison has run.

This is an infrastructure spike, not a domain-prelude A/B and not a claim that
domain preludes improve model performance. It creates the missing capability
channel required by such an experiment while preserving the kernel's
two-level authority boundary.

## Short Goal Prompt

```text
Run the autonomous S21 Inner-Eval Domain Prelude plan described in
docs/plans/lisp-kernel/autonomous-s21-inner-eval-domain-prelude.md.

Goal: let a role explicitly authorize a separate, frozen prelude bundle for
model-authored inner PTC-Lisp programs. Keep the trusted agent loop bundle and
the model-callable inner bundle separate. Resolve both through PreludeStore,
project only inner exports to the model, preserve runtime: nil and
discovery_exec: nil, record source-free provenance for both slots, and emit
honest runtime invocation counts for inner prelude functions.

Work risk-first and deterministic-only. Add failing boundary tests before
implementation. Do not run a live model, build calendar fixtures, finish Tier
2, or start a self-improving loop. Stop if the design requires exposing
llm-complete/eval-program/log, attaching the loop bundle to inner eval, or
granting an upstream runtime to model code.
```

## Objective

The kernel currently has two execution levels but only one prelude attachment:

1. The trusted outer loop runs `agent.core/run-mission` with the compiled
   `agent.*` bundle and private kernel tools.
2. Each untrusted model program runs through `Lisp.run_native/2` with mission
   data and mission tools, but explicitly with `prelude: nil`, `runtime: nil`,
   and `discovery_exec: nil`.

Role-backed selection can already resolve arbitrary PreludeStore components,
including a hypothetical `domain.calendar@1`, but it compiles every selected
component into the one outer loop bundle. S20 then projects prompt-visible
exports from that outer bundle even though model programs cannot call them.
Adding a domain component to the existing selection therefore changes
presentation and outer composition, not inner model capability.

S21 introduces a second, narrower attachment slot:

```text
role policy + PreludeStore
        │
        ├── loop selection  ──> loop bundle  ──> outer Lisp.run
        │                       agent.*          private kernel tools
        │
        └── inner selection ──> inner bundle ──> each Lisp.run_native
                                domain.*         mission tools only
```

The bundles are independently selected, compiled, validated, attributed, and
traced. The inner bundle is frozen once before the outer run begins and reused
across every model turn. It is never the loop bundle and never receives the
outer private capabilities.

## Current Implementation Audit

Facts verified in the source on 2026-07-09:

- `PtcRunner.Kernel.run/2` compiles one prelude, logs it, feeds it to
  `SymbolInventory`, and attaches it to the outer `Lisp.run/2`.
- `run_inner_program/5` calls `Lisp.run_native/2` with `prelude: nil`,
  `runtime: nil`, `discovery_exec: nil`, prior host-held memory, strict timeout
  and heap limits, and the caller's tool-call cap.
- `PtcRunner.PreludeRolePolicy` has one exact-ref allowlist (`preludes`) and
  one default selection (`default_preludes`). Its fingerprint schema is v1.
- `PtcRunner.PreludeRuntime.resolve/3` and
  `PreludeStore.Selection.resolve!/3` expand pinned dependency closure and
  compile exactly one frozen bundle.
- `PreludeStore.Selection` returns source-free resolved refs with dependency
  provenance; `Prelude.trace_summary/1` returns aggregate and per-component
  hashes without source or captured environments.
- `SymbolInventory.project/1` already renders only `:prompt` exports and knows
  their kind, params, doc, usage, and effect. The kernel currently supplies a
  prelude to it only for role-backed outer selections.
- Capability Prelude attachment validates `tool:<name>` requirements against
  the attached typed-tool map. With `runtime: nil`, upstream runtime existence
  checks are skipped, so S21 must explicitly reject upstream-backed inner
  exports rather than treating `runtime: nil` as sufficient validation.
- Prelude namespaces become protected namespaces when attached. This is
  desirable for `domain.*`: model code may call public exports but may not
  redefine their namespace.
- The evaluator has explicit `{:prelude_call, ref, args}` and
  `{:prelude_ref, ref}` nodes. There is no runtime prelude-call ledger today.
  Static source scanning would report references, not actual invocations.
- D4 TurnEvents currently carry one `preludes` component list and the loop
  role projection. The ephemeral eval event stream emits one run-start
  `"prelude"` event.
- Host-held memory is reattached on each inner run with
  `preserve_runtime_callables: true`; a new test must prove model definitions
  and aliases that refer to the frozen inner prelude remain usable on later
  turns.

## Design Decisions

### 1. Name the runtime boundary, not the first benchmark

Use `inner_preludes` in Elixir options and role policy. Calendar is the first
planned consumer, but the mechanism is equally applicable to graph, table,
JSON, and other safe model-callable helper libraries. `domain.*` remains the
recommended namespace convention, not a hardcoded list of benchmark domains.

Use these terms consistently:

- **loop prelude** — trusted outer policy bundle containing `agent.*`.
- **inner prelude** — curated model-callable bundle attached to model programs.
- **domain prelude** — an intended class of inner prelude, usually named
  `domain.<name>`.

Do not add ambiguous singular options such as `domain_prelude:` that accept a
raw `%Prelude{}` and bypass role/store resolution.

### 2. Inner callability is a distinct role grant

Being allowed to compose a component into the outer loop must not implicitly
authorize its exports inside model code. Extend the core role shape with a
separate exact-ref allowlist and default:

```json
{
  "default_role": "calendar_eval",
  "roles": {
    "calendar_eval": {
      "prelude_store_access": "none",
      "preludes": [
        "agent.prompt@1",
        "agent.feedback@1",
        "agent.core@1"
      ],
      "default_preludes": ["agent.core@1"],
      "inner_preludes": ["domain.calendar@1"],
      "default_inner_preludes": ["domain.calendar@1"]
    }
  }
}
```

Semantics:

- existing `preludes` / `default_preludes` continue to govern the loop bundle;
- `inner_preludes` is an exact-ref allowlist specifically for model-callable
  attachment;
- `default_inner_preludes` is checked against that allowlist;
- `Kernel.run(..., inner_preludes: refs)` overrides the inner default and is
  checked against the inner allowlist;
- omission plus an empty inner default means no inner prelude, which is the
  generic baseline and today's behavior;
- an explicit empty `inner_preludes: []` selects the no-inner-prelude baseline;
- requesting `inner_preludes` without `role_policy` fails closed. The embedded
  no-policy bootstrap remains loop-only;
- the grant fingerprint schema increments and covers both new fields.

The schema-version increment intentionally changes every role fingerprint,
including roles with empty inner grants. Update frozen fixtures and provenance
assertions in the same commit; do not preserve v1 fingerprints with a shim.

Existing role documents with neither new key parse with empty inner grants and
retain today's behavior. This is a schema default, not a compatibility shim.

### 3. Resolve two independent dependency closures

Refactor selection around an explicit surface (`:loop | :inner`) rather than
copying the role and runtime logic into kernel-private helpers. A suitable
shape is:

```elixir
PreludeRolePolicy.selected_refs(grant, opts, :loop)
PreludeRolePolicy.selected_refs(grant, opts, :inner)

PreludeRuntime.resolve(store, grant, :loop, opts)
PreludeRuntime.resolve(store, grant, :inner, opts)
```

Exact names may vary, but the invariants do not:

- the loop selection remains required in role-backed mode;
- an empty inner selection resolves successfully to `%{prelude: nil, ...}`;
- non-empty selections use `PreludeStore.Selection.resolve!/3`, including
  pinned transitive dependencies and conflict detection;
- each returned prelude carries source-free role-selection metadata with an
  explicit `surface` value;
- both bundles are resolved and frozen before the LLM callback or outer
  sandbox starts;
- no component object, callable, or private environment is shared by merging
  the two artifacts.

### 4. Validate the entire resolved inner closure fail-closed

Validation runs after dependency expansion and before any model call. Checking
only directly requested refs is insufficient because a permitted domain
component could pin a forbidden dependency.

Required checks over the resolved inner artifact and component metadata:

- reject any declared namespace equal to `agent` or prefixed by `agent.`;
- reject namespace overlap between the loop artifact and inner artifact;
- reject component-id overlap between loop and inner resolved closures;
- reject inner component ids equal to `agent` or prefixed by `agent.` as a provenance
  and configuration error, even when their source declares another namespace;
- rely on the existing compiler to reject reserved namespaces (`tool`, `data`,
  `budget`, `mcp`, `ptc.core`) and duplicate namespaces, and pin tests so S21
  does not weaken that behavior;
- reject any inner export with a non-nil `provider_ref`;
- reject any inner export requirement beginning with `upstream:`;
- reject dynamic upstream dispatch (`"call"` in transitive `tool_refs`);
- allow pure exports and typed mission-tool wrappers. Existing attach-time
  validation must prove every `tool:<name>` requirement is present in the
  actual `mission_tools` map before the model program is analyzed;
- never pass an upstream runtime to the inner run. `runtime: nil` remains
  literal and tested;
- keep `discovery_exec: nil`. Attached-prelude local discovery remains governed
  by D17; S21 must document, not overclaim, that domain source is hidden.

Return stable structured errors such as `:invalid_inner_prelude` with a bounded
reason and offending public id/namespace/ref. Do not leak source text or
captured values in an error.

### 5. Project only the callable inner artifact to the model

Change the kernel inventory path to accept both artifacts:

```elixir
render_symbol_inventory(mission, opts, inner_prelude)
```

The `prelude:` passed to `SymbolInventory.project/1` is the validated inner
artifact, never the loop artifact. This applies whether the loop uses the
embedded or role-backed path; however S21 only permits a non-nil inner artifact
under role-backed selection.

Consequences:

- `agent.core`, `agent.prompt`, and `agent.feedback` exports disappear from
  model symbol facts;
- `:prompt` inner exports render with the S20 kind/doc/usage contract;
- `:discoverable` inner exports remain callable and locally discoverable under
  existing Prelude semantics but are not injected into the prompt inventory;
- an inner export mask, if later supported, must be an authority projection
  applied before both inventory and execution. S21 must not add a
  presentation-only mask that advertises a different surface from the one the
  evaluator accepts.

No domain vocabulary is added to `agent.*` source or generic prompts. Domain
vocabulary comes only from the explicitly selected inner artifact and its own
export docs.

### 6. Attach the same frozen inner artifact on every turn

Thread `inner_prelude` through the private `eval-program` closure to
`run_inner_program`. The call remains structurally strict:

```elixir
Lisp.run_native(program,
  context: mission_context,
  tools: mission_tools,
  prelude: inner_prelude,
  runtime: nil,
  discovery_exec: nil,
  memory: prior_memory,
  preserve_runtime_callables: true,
  timeout: inner_timeout,
  max_heap: inner_max_heap,
  max_tool_calls: inner_max_tool_calls
)
```

Do not re-resolve the store per turn. Store mutation during a run must not
change the attached artifact, prompt inventory, provenance, or behavior.

Memory tests must cover more than a plain numeric `def`:

- a model-defined function that calls an inner export on the next turn;
- a value-position alias such as `(def normalize domain.calendar/normalize)`
  used on the next turn;
- a model definition and an inner prelude private helper with the same bare
  name, proving namespace isolation;
- mutation of the PreludeStore after turn one, proving the current run keeps
  the frozen vN artifact while a new run can select vN+1.

### 7. Count runtime invocations, not source mentions

Add bounded aggregate accounting to the Lisp evaluator rather than scanning
submitted program strings. Recommended shape:

```elixir
%{"domain.calendar/intersect" => 2,
  "domain.calendar/normalize" => 1}
```

Implementation direction:

- add `prelude_call_counts` to `PtcRunner.Lisp.Eval.Context`, initialized to
  `%{}`;
- increment only when a function export is actually entered at runtime;
- count both direct `{:prelude_call, ref, args}` calls and later application of
  a value-position exported closure tagged with its originating `prelude_ref`;
- do not count parsing, analysis, a constant lookup, a dead branch, or merely
  passing a ref as a value;
- preserve counts through closure execution, `recur`, return/fail throws, and
  the existing prelude effect merge paths, just as tool-call and catalog
  ledgers are preserved;
- aggregate by public ref rather than retaining an unbounded call list;
- expose the aggregate on `%Step{}` as a general Lisp execution metric, then
  project only refs belonging to the selected inner artifact into the kernel
  eval result and TurnEvent;
- call the metric `inner_prelude_call_counts`. Do not label it successful
  calls: entry followed by a failure still counts as an invocation.

If correct higher-order accounting cannot be added without destabilizing
general evaluator effect propagation, stop and land the capability channel
without claiming invocation truth. A textual reference metric may be added
only under the explicit name `inner_prelude_reference_count` and must not
satisfy S21's invocation-metric pass criterion.

### 8. Attribute loop and inner artifacts separately

Preserve existing `preludes` semantics in canonical TurnEvents for the loop
bundle and add separate bounded fields rather than changing the existing list
into an overloaded map.

Required trace/report shape:

- run-start ephemeral events carry `slot: "loop" | "inner"`; emit the loop
  event always and the inner event when non-nil;
- sanitized eval traces retain the slot plus the same bounded
  aggregate/component fields S19 already permits;
- kernel TurnEvent `data.preludes` remains loop component provenance;
- add `data.inner_preludes` for inner component provenance;
- add `data.inner_prelude_projection` for source-free selected/resolved refs;
- add `data.inner_prelude_call_counts` for the current inner eval;
- the top-level `role` and `grant_fingerprint` remain one authority identity;
- do not place raw prelude source, docs, form graphs, private envs, or raw
  selected candidate metadata in events;
- update `TurnEvent`, MemorySink/JSONL parity tests, and eval sanitizer tests in
  the same change.

The no-inner baseline must render an empty/nil inner provenance slot and empty
call counts, never copy loop provenance into it.

## Build Sequence

Work in the order below. Each phase starts with a failing focused test and ends
with the smallest relevant test command. Commit only coherent code + tests +
docs batches; do not commit the preregistered calendar experiment from this
spike.

### Phase A — Pin the current separation boundary

Before changing selection, add or strengthen deterministic tests proving:

- the outer loop bundle can call `llm-complete`, `eval-program`, and `log`;
- a model program cannot call those private tools;
- a role-selected `domain.example` component in today's one outer bundle is
  not callable by an inner model program;
- today the inventory mismatch exists: outer prompt exports can be rendered
  while the inner evaluator rejects them. This test may be replaced by the new
  correct behavior in Phase D, but it documents the bug S21 closes.

### Phase B — Extend role policy and surface-aware resolution

Implement the policy contract above in:

- `PtcRunner.PreludeRolePolicy.Grant`;
- `PtcRunner.PreludeRolePolicy` parsing, validation, selection, and fingerprint;
- `PtcRunner.PreludeRuntime` surface-aware resolution;
- focused policy/runtime tests.

Test at minimum:

- absent new keys default empty;
- exact refs and checksum-pinned maps parse for inner grants;
- duplicate inner grants fail;
- an inner default outside the inner allowlist fails policy parsing;
- a requested inner ref outside the grant fails before store resolution;
- explicit `inner_preludes: []` overrides a non-empty default;
- invalid requested type fails with an inner-specific path in the error;
- changing only an inner grant changes the role fingerprint;
- empty inner selection returns nil without weakening the required loop
  selection;
- dependency pins and conflicts behave identically on both surfaces.

### Phase C — Compile, validate, and freeze the inner artifact

Add a small kernel-owned inner validation module rather than scattering policy
checks through `Kernel.run/2`, for example
`PtcRunner.Kernel.InnerPrelude`. It should own:

- validation of loop/inner component and namespace disjointness;
- forbidden `agent.*`, provider, upstream, and dynamic-call checks;
- the bounded public error shape;
- the set of inner export refs used to filter runtime metrics.

Test direct and transitive violations. In particular, a permitted
`domain.calendar@2` that pins `agent.feedback@1` must fail after dependency
expansion and before the LLM callback.

Prove store freezing by resolving v1, mutating the store to v2 during the mock
run, and observing v1 behavior and hashes through completion.

### Phase D — Wire inventory and inner evaluation

Compile both artifacts near the start of `Kernel.run/2`, then pass only the
inner artifact to SymbolInventory and `run_inner_program`.

Required deterministic behavior tests:

- no-inner role reproduces the existing six-case mock behavior;
- a prompt-visible pure inner export appears once with correct kind/doc/usage;
- loop exports do not appear in model symbol facts;
- a model program can call a pure inner export and return its result;
- a typed-tool-wrapping inner export works only when the mission tool is
  granted and fails attachment otherwise;
- private inner helpers remain uncallable by model code;
- the model cannot redefine a selected inner namespace;
- the model still cannot reach private kernel tools;
- `runtime: nil` and `discovery_exec: nil` remain pinned by observable denial
  tests;
- multi-turn memory cases from Design Decision 6 pass.

Use a neutral `domain.example` fixture under `test/support` or inline test
source. Do not add calendar-specific prompt text or benchmark-shaped examples
to `priv/preludes/agent`.

### Phase E — Add honest call accounting

Implement `prelude_call_counts` in the general evaluator with focused Lisp
tests before consuming it in the kernel.

Required cases:

- one direct call counts once;
- a loop calling an export N times counts N;
- a dead branch counts zero;
- a ref passed as a value but never invoked counts zero;
- a value-position exported closure invoked through `map` or an alias counts
  actual applications;
- a call that enters and then fails counts once;
- recursive/recur paths preserve counts;
- counts survive return/fail signal propagation and do not expose private
  helper names;
- the kernel filters the general map to inner public refs and records the
  per-turn aggregate.

Keep this metric out of correctness or acceptance decisions in S21. It is
instrumentation for the later preregistration.

### Phase F — Split provenance in events and reports

Extend the ephemeral event sanitizer and canonical TurnEvent data bag with the
fields in Design Decision 8.

Update S19/FeedbackAB tests only where the stable event shape genuinely grows;
the feedback A/B still varies only the loop `agent.feedback` component and
should observe no inner bundle by default.

Add redaction sentinels to inner source, docstrings, private helper values, and
store metadata. Assert none appear in sanitized eval reports or TurnEvent
provenance. Do not assert that `(source ...)` can never reveal the attached
domain implementation to the executing model; D17 remains open and domain
preludes must contain no secrets.

### Phase G — Bless the existing eval path, not a parallel harness

Teach `PtcRunner.Kernel.Eval.run_cases/2` to pass the explicit role/store/loop/
inner selection options needed by S21. Add one deterministic custom case whose
mock program calls `domain.example` and whose exact oracle passes.

Do not add a second domain eval task or hardcode a calendar suite into
`mini_cases/0`. R10 owns the data-driven suite registry and constraint oracle;
R11 owns JSON/report/trace persistence. Once those land, domain suites plug
into `mix ptc.kernel_eval` through the same interfaces.

### Phase H — Documentation and closeout

After deterministic tests and `mix precommit` pass:

- mark S21 PASS in `spikes.md` with the exact commit and test commands;
- update `roadmap.md` and architecture D21 from proposed to resolved;
- update the Capability Model diagram to show separate loop and inner bundles;
- document the new role keys and `Kernel.run/2` options in the role guide if
  the kernel API is documented there;
- update `eval-domains-and-preludes-discussion.md` to say the channel exists
  but no domain-effectiveness claim has run;
- record any D17 source-discovery behavior observed rather than silently
  resolving it;
- run an independent review over the implementation commits, address every
  correctness/security finding, then run `mix precommit` again.

## Verification

Use focused tests while building. The final implementation session must run at
least:

```sh
mix test test/ptc_runner/prelude_role_policy_test.exs \
  test/ptc_runner/kernel_test.exs \
  test/ptc_runner/kernel/eval_test.exs \
  test/ptc_runner/kernel/feedback_ab_test.exs \
  test/ptc_runner/symbol_inventory_test.exs \
  test/ptc_runner/trace_log/turn_event_test.exs \
  test/ptc_runner/trace_log/turn_log_integration_test.exs
```

Add the focused evaluator/prelude test files introduced in Phase E to that
command. Then run:

```sh
mix ptc.kernel_eval --suite mini
mix precommit
```

Do not run `mix ptc.kernel_eval --live`, `mix ptc.kernel_feedback_ab --live`,
or any calendar comparison as part of S21.

## Pass Criteria

S21 passes only if all are true:

1. A role can select independent loop and inner PreludeStore closures, and the
   inner authorization is explicit in the role fingerprint.
2. The loop and inner artifacts are compiled once, disjoint, source-free in
   provenance, and frozen for the run.
3. The model inventory contains callable prompt-visible inner exports and no
   loop exports.
4. Model programs can call pure and granted typed-tool inner exports across
   turns while `runtime: nil` and `discovery_exec: nil` remain intact.
5. Direct or transitive `agent.*`, overlapping, upstream-backed, dynamic
   upstream, missing-tool, and ungranted inner selections fail before an LLM
   call.
6. Model-defined functions and value-position aliases using inner exports
   survive host-held memory across turns.
7. Runtime inner-prelude invocation counts are correct for direct and
   higher-order calls and are emitted in sanitized per-turn evidence.
8. Loop and inner component hashes are distinguishable in ephemeral reports
   and canonical TurnEvents without source leakage.
9. Existing mini eval and feedback A/B mock tests remain green with no inner
   bundle selected.
10. `mix precommit` passes.

## Stop Conditions

Stop and record the blocker instead of weakening the boundary if:

- inner helpers require attaching the `agent.*` loop artifact to model runs;
- role authorization cannot distinguish outer composition from inner
  callability;
- a transitive dependency can smuggle an `agent.*` namespace or component into
  the inner artifact;
- a useful domain helper requires giving model code the upstream runtime or a
  private kernel tool;
- attaching the inner artifact causes raw model memory, private prelude envs,
  source, or credentials to enter default provenance;
- frozen inner exports cannot coexist with host-held model definitions across
  turns;
- invocation counting would require an unbounded ledger or cannot survive
  evaluator effect propagation honestly;
- implementing the spike starts building R10/R11, calendar fixtures, a live
  A/B, or the self-improving loop.

## Non-Goals

- No claim that a domain prelude improves correctness, efficiency, or transfer.
- No calendar, graph, table, or JSON fixture generator.
- No Tier-2 case/oracle port, JSON report twin, trace directory, replay, or
  incumbent variant; those remain R10/R11.
- No DeepSeek shakedown or live model call; R12 remains the gate before
  conclusion-bearing runs.
- No statistical plan, sample-size choice, or experiment preregistration;
  R17/R18 and the calendar prereg own those.
- No deliberately fixture-aware overfit prelude.
- No prelude-edit proposer, candidate acceptance loop, or automatic store
  promotion.
- No caller-supplied expected-base guard for `prelude/edit`; that is required
  before concurrent/delayed self-improvement, not for this read-only frozen
  selection spike.
- No resolution of D17 for all prelude surfaces. S21 keeps loop and inner
  artifacts separate so attaching domain helpers does not expose `agent.*`
  through the inner prelude.
- No upstream runtime in the inner eval.

## What Follows S21

S21 is necessary but insufficient for a domain-prelude experiment. The next
claim-bearing work remains:

1. R10 data-driven case registry and fail-closed constraint oracle.
2. R11 JSON/Markdown report twins and persistent sanitized traces.
3. R12 incumbent DeepSeek shakedown before architectural attribution.
4. R15 trust/redaction decisions, especially D17 source exposure.
5. R17 power/randomization/multiple-comparison plan and R18 holdout/oracle
   audit.
6. A separate preregistered calendar pilot with frozen fixtures, reference
   solver, certificate validators, anti-leak scan, generic/domain/docstring-
   ablated cells, and a final holdout untouched by prelude iteration.

Only after one manual pilot completes end-to-end should the repo automate
prelude proposals and acceptance. Repeatedly scoring candidates on a set makes
that set training data; a future loop therefore needs separate proposal,
acceptance, and one-shot final-test sets plus a candidate budget and guarded
expected-base edits.
