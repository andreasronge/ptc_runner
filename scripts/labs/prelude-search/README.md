# Prelude-search lab

This maintainer lab checks reproducibility and measures checked prelude repair.
It is source-checkout tooling, not a shipped example. Phase 0 is credential-free
and never calls a model; Phase 1 uses a live model or retained replay fixtures.

The lab contains three purpose-written PTC-Lisp subjects: interval merging,
text normalisation, and two-ledger reconciliation. For each subject it chooses
one of five seeded semantic mutations, freezes both the original and mutated
application bundles, and generates seeded inputs. The five mutation operators
are comparator flip, boundary off-by-one, dropped edge-case clause, swapped map
key, and a wrong private-helper default. `ground-truth.json` records the
subject, function, changed form, and operator.

Every input is run against both frozen bundles. The first four fifths of the
inputs are marked `visible`; the remainder are marked `held-out`. The oracle
result is retained only in the private lab artifacts and is not an input to
any later model phase. `reached_mutation` means that the observed result hash
differs from the oracle result hash. That difference is an intentional proxy
for reaching the mutation, not statement-level coverage.

Each recorded execution is a real PtcRunner run. It leaves a canonical JSONL
trace and a private `.ptcins` inspection artifact containing the selected input
and result. `executions.json` indexes relative artifact paths, artifact digests,
and frozen bundle identities. Retain the whole output directory, including its
application manifests and component sources; there are no input sidecars.

Phase 0 reconstructs applications from the retained files, reads inputs from
private inspection records, verifies artifact and bundle identities, and
compares strict JSON result hashes. The separate replay command below runs in
a fresh VM and also works after moving the output directory. It does not read
the lab's original subject files. This checks no-provider reconstruction on the
same runtime version; it does not establish replay of live providers, timing,
or concurrent scheduling. The reported time includes rebuilding each run.
Any unequal result fails the command.

Run all subjects with the default seed and 100 recorded executions per subject
(40 visible inputs and 10 held-out inputs, each run once as oracle and once as
observed):

```console
mix run scripts/labs/prelude-search/run.exs --phase 0
```

Select one subject, seed, execution count, or artifact directory:

```console
mix run scripts/labs/prelude-search/run.exs --phase 0 \
  --subject intervals --seed 20260917 --executions 10 --output /tmp/prelude-search
```

The execution count must be a positive even number because every generated
input has an oracle and observed execution. Treat the `.ptcins` files and the
oracle records as private even though Phase 0 uses no credentials.

Replay an existing recording in a fresh process:

```console
mix run scripts/labs/prelude-search/run.exs --replay-artifacts /tmp/prelude-search
```

The current research protocol (data separation, matched budgets, and decision
rules) is in `docs/research/prelude-search.md`. Historical report 001 used a
separate retained harness and does not establish final-test accuracy.

## Corrective E1/E2 pilot

Phase 1 runs one-turn E1, three-turn E1, and independent sampling at K=2 and
K=4. Every condition has the same total ceilings: 320,000 tokens and USD 0.10
per instance. These are equal ceilings, not equal measured spend; the report
retains actual cost and cannot claim cost efficiency from pass rates alone.
The model is explicitly `openrouter:deepseek/deepseek-v4-flash`; general
`.env` model overrides do not select the experiment model.

Provide `OPENROUTER_API_KEY` in the environment. Start with a small live pilot:

```console
mix run scripts/labs/prelude-search/run.exs --phase 1 --instances 1 \
  --subject intervals --budget-microusd 500000 --output /tmp/prelude-pilot
```

The default matrix has twenty seeds per subject, starting at 20260930, and a
USD 5 issue cap. An output directory must be new: a resumed run cannot silently
reset spend. `protocol.json` freezes conditions before requests;
`reservation.json` records the next case's reservation. Missing usage stops
the matrix and retains that case's full reservation. A failed command also
leaves its reservation in place; account for it before starting another run.

Each instance has 40 visible, 20 selection, and 20 final inputs. The harness
checks partition disjointness and requires each mutation to affect selection
and final examples before making any model request. Oracle values and the
mutation-reached flag never enter proposal data. A recorded no-model workflow
selects the first passing candidate, then evaluates only that candidate on
final tests. Source compilation failures remain unsuccessful attempts.

`results.json` retains every candidate, usage, chosen index, and final-test
outcome. `summary.json` includes all-candidate diagnosis scores, paired case
observations, and a stratified paired bootstrap interval (2,000 resamples,
fixed seed). Pilot verdicts stay inconclusive; intervals from tiny or
homogeneous samples are not reliable precision claims. Citation scoring checks
that quoted observed values match the cited visible examples, not that the
model's reasoning follows from them. Form accuracy requires the exact planted
fragment; empty text and arbitrary containing functions do not count.

Every model case also retains a canonical trace under `traces/` and renames its
inspection artifact to the correlated run reference. If a command or fixture
export fails, the harness stops normally after writing the completed prefix to
`results.json`, the available fixture index, and `summary.json`. The summary
names the failed case and unresolved reservation; it does not add a scored row
or invent usage for that case.

Replay in another new directory using the retained per-case fixture index:

```console
mix run scripts/labs/prelude-search/run.exs --phase 1 --instances 1 \
  --subject intervals --replay --fixtures /tmp/prelude-pilot/fixtures \
  --budget-microusd 500000 --output /tmp/prelude-pilot-replay
```

For a stopped experiment, add `--partial-replay` to replay only the indexed
prefix. This mode is valid only with `--replay`; it stops at the first missing
fixture with `partial_replay_complete` rather than treating the unrecorded case
as a new experiment failure. The declared instance and budget bounds still
apply.

Keep the same seeds, subjects, and instance count. Fixtures preserve successful
usage and classified provider failures. Compare candidate outcomes and reported
usage, excluding run ids and wall time. Kernel deadline and post-provider admission failures stop fixture export; their
settled usage and timing cannot be reconstructed from a provider error. Keep
the original artifacts and budget reservation when export stops.
A generic candidate index in each proposal distinguishes concurrent request
hashes, so replay cannot swap answers between candidates. Per-case fixtures
avoid sharing response cursors across runs. Retain fixtures
on the experiment branch, not in a report-only pull request.
