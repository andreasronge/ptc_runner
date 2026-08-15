# Self-repair adversarial spike

Date: 2026-08-15

This spike asks a second PTC run to diagnose a failed run, propose a complete
replacement component, and then lets the host gate and trial that candidate.
It deliberately separates navigation, causal judgment, candidate publication,
and behavioral testing. None of the model-authored reports can choose paths,
credentials, validation inputs, expected results, provider authority, or
promotion.

## Questions and stopping rule

The experiment tested four questions:

1. Can a debugger traverse a failure through generated source and more than one
   prelude dependency without being distracted by an unrelated component?
2. Does a small typed `debug.nav/follow` helper materially outperform direct
   use of the native `runs/open/read` evidence API?
3. Will the debugger abstain when evidence admits more than one repair?
4. Can a generated candidate pass static compatibility gates and host-owned
   observed plus held-out live cases without replay?

The planned models were `openai/gpt-5.6-luna` and
`deepseek/deepseek-v4-flash`. After one diagnosis iteration and one fairness
correction to the raw wrapper documentation, prompt tuning stopped.

## Fixtures

- `deep`: `orders/place` calls `pricing.tax/add-standard`, which delegates to
  `pricing.rule/apply-standard`. The rule adds 2 while the captured user task
  externally requires subtotal plus 20. `pricing.discount` is an unused decoy.
- `ambiguous`: two independent components return 80 and 20 and the caller sums
  them. The external contract rejects the total, but the retained evidence does
  not establish which component or expectation is wrong. The safe result is
  `insufficient-evidence`.
- `typed`: the debugger uses shipped `debug.nav` and follows unchanged typed
  relationships.
- `raw`: the debugger uses the same provider's native `runs/open/read` pages and
  manually applies relationship target collections and filters.

## First matrix: ambiguity in the experiment itself

Target runs were `cmd-6psvqnn4d081gdxrqh1f4kc6v4` (`deep`) and
`cmd-2ay9bsrbj8srafedktsare91yv` (`ambiguous`). The deep task did not yet state
which behavior was externally required. Luna/typed safely abstained. Both raw
models found the dependency chain and proposed changing `pricing.rule`, while
DeepSeek/typed proposed changing the downstream invariant instead. Those
opposite repairs were both compatible with the retained evidence. Several
reports also failed the result contract because the prompt did not state that
`evidence` and `validation_plan` were arrays.

This was not evidence that one navigation API was better. It showed that the
fixture had no identifiable cause and that contract-valid structured output is
a separate concern from diagnosis quality.

The revision made the external plus-20 requirement part of the captured target
turn and stated the generic report field types. It also required external
expectation evidence before proposing code. The ambiguity fixture was left
without that evidence.

## Revised matrix

Target runs:

- Deep: `cmd-0m05wjqpk4q7g5v61vhmb3gpm4`
- Ambiguous: `cmd-22992vemqa2d3d94pfshj9sjj3`

| Case | Interface | Model | Debugger run | Outcome | Model / evidence calls |
| --- | --- | --- | --- | --- | --- |
| deep | typed | Luna | `cmd-6vjx3p43nc8q0d8h9kk7hcw5z9` | correct `pricing.rule` candidate | 6 / 15 |
| deep | typed | DeepSeek | `cmd-77ck9emnegj87tswbkapcawbzx` | correct `pricing.rule` candidate | 12 / 11 |
| deep | raw, equal docs | Luna | `cmd-0dacx3ryyqp0zt7dfc2xr5dvgg` | correct `pricing.rule` candidate | 11 / 31 |
| deep | raw, equal docs | DeepSeek | `cmd-3f6t9bsxvz5c1swjgmwt9axsjv` | correct `pricing.rule` candidate | 11 / 10 |
| ambiguous | typed | Luna | `cmd-71jgxksk3vg8pbfgj337x8ys3x` | correct abstention | 14 / 18 |
| ambiguous | typed | DeepSeek | `cmd-3n4ws4wtrq8hhsnx572jd9tpp7` | turn limit, no report | 14 / 14 |

Both typed deep runs followed `producing_turn`,
`referenced_prelude_source`, and transitive `dependency_prelude_source`
relationships. Both raw runs reached the same evidence manually. Typed
navigation substantially reduced Luna's discovery work and was neutral for
DeepSeek. It is therefore a useful convenience, not a required diagnosis
oracle and not evidence for a coarse `latest-failure` API.

The raw wrapper initially omitted that it returns unwrapped pages. DeepSeek
treated a successful page as a `{status, value}` envelope and explicitly failed
on its first turn (`cmd-532be0054djzrh0cypzeh0echd`). The fair raw rows above
come from the rerun after matching the typed wrapper's documentation.

## Candidate gate and live trial

The frozen Luna/typed report authored a complete replacement whose source hash
is `sha256:524fcae05a7f8787ed20ffbc7b341bfd4fa8952ba6ca7040bdcd09dcc2bd3a48`.
The host supplied three exact normal-data cases: observed subtotal 100 and
held-out subtotals 0 and -10.

The first trial exposed an API defect before provider activity: suites forced
every case through `--private-input`, upgrading the data class beyond what the
normal target model installation admitted. `ptc.repair` now accepts exactly one
`input` or `private_input` per case while retaining all outputs as private.

The final trial passed all three cases. PTC private analysis verified that each
run was successful and installed the exact candidate override:

| Case | Validation run | Status |
| --- | --- | --- |
| observed 100 | `cmd-6g8c385yj6v624qgyvdyg7j4xq` | pass |
| held-out 0 | `cmd-3r5ytvb38trc6fejx8xr1zpaq3` | pass |
| held-out -10 | `cmd-0m1z9tbafp1wt0v3hstd9mvr0s` | pass |

Validation artifacts now group each case's `traces` and `inspection` into
physically separate sibling directories so `private-run-analysis-v1` can open
them directly. The local private evidence root is
`/private/tmp/ptc-self-repair-adversarial-20260815-b`; it is intentionally not
versioned.

## Product conclusions

Ship the general primitives, not a diagnosis policy:

- Preserve exact occurrence identity and frozen dependency edges in the core
  evidence model. A bare component ID is not an identity when it can occur in
  workflow and multiple missions.
- Keep `debug.nav` small: `runs`, `open`, `read`, and safe `follow`. It should
  preserve native pagination, cursors, completeness, and relationship state.
- Keep repair host-controlled. Static G1-G4 checks, exact base/candidate hashes,
  no removed exports, explicit live-effects acknowledgement, multiple
  host-owned cases, private artifacts, and a separate promotion decision are
  all necessary.
- Treat a passing live suite as evidence for named cases, not proof of a general
  repair. Replay is not required for this path, but deterministic providers or
  more held-out cases remain preferable when available.

Do not ship the earlier coarse incident aggregator. It hid pagination and
relationship state, conflated occurrences, stopped at immediate dependencies,
and embedded a failure-selection policy that the experiment did not justify.

## Remaining limits and useful next experiments

- This is still a small sample: one transitive functional bug, one ambiguity
  control, two models, and one application family. DeepSeek's failure to finish
  the ambiguity control shows that abstention efficiency is unresolved.
- Run the same frozen debugger against a removed-export regression, a wrong
  provider/data-policy declaration, and a workflow-component bug. Those test
  different failure phases without changing the debugger prompt.
- Add a deterministic no-provider candidate case to separate repair semantics
  from LLM ceremony and cost.
- Compare one larger dependency graph with pagination and repeated component
  IDs across workflow and two missions. The core relationship tests cover the
  identity rule, but the model experiment does not yet stress it at scale.
- Promotion remains intentionally manual. Automatic promotion needs a separate
  policy and stronger evidence than this spike provides.

## PTC-analysis friction observed

- A natural `failures` collection query is rejected; callers must discover and
  combine `activity` and `execution_errors` from `open`.
- Collection descriptors do not advertise the read limit maximum. A request
  for 200 was rejected with the hidden maximum of 100.
- Before the case-directory change, trial traces and inspection files shared a
  parent that could not be used directly as physically separate PTC analysis
  resources. The new layout fixes this for generated trial artifacts.

Every target, debugger, and final validation run in this report was inspected
through `mix ptc repl --profile private-run-analysis-v1
--private-unattended`; JSON success or process exit status alone was not used as
the quality verdict.
