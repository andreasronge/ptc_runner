# Debug a failed run with another PTC run

This credential-free pair shows one PTC application navigating another
application's immutable failed run. No model, network access, or credential is
involved: both runs are deterministic.

`target/` prices an order through `orders` → `pricing.tax`, which branches to
`pricing.base` and `pricing.rule`. The rule adds 2 while its own docstring
states the flat charge is 20 and the captured call requires the subtotal plus
20, so the run fails. `pricing.discount` is an unused decoy: nothing in the
failing call reaches it.

`debugger/` installs the target's frozen trace and inspection directories as
snapshot providers and walks the evidence with the shipped `debug.nav` prelude.
It reports what the evidence shows and how completely the host proved each
edge. It never names a suspect.

## Run it

Capture the failed run first. It exits nonzero by design:

```console
ptc init debug-a-failed-run --example debug-a-failed-run
ptc run debug-a-failed-run/target.ptc-project.json
```

Then navigate that capture:

```console
ptc run debug-a-failed-run/debugger.ptc-project.json
```

The debugger is a private run, so its value goes to
`debug-a-failed-run/debugger/.ptc/results/` rather than stdout:

```console
cat debug-a-failed-run/debugger/.ptc/results/*.private.json
```

It reports the boundary failure, the exact generated program including the
required total, the complete frozen dependency closure, and the source of each.
The decoy never appears, because the walk follows frozen dependency edges
rather than the manifest component list, and `closure_complete` says whether
the walk saw the whole closure or stopped early.

## Check the diagnosis

The evidence supports one change: `pricing.rule/apply-standard` adds 2 where
the captured call requires 20. Edit `target/pricing.rule.clj`, remove the stale
capture, and rerun the target to see it pass:

```console
rm -rf debug-a-failed-run/target/.ptc
ptc run debug-a-failed-run/target.ptc-project.json
```

## Optional: let a model walk it

`debugger-agent/` runs the shipped agent loop over the same authority. It is
the one part of this example that needs a credential. Name the environment file
on the command line rather than placing one in this directory, which ships
inside the published package:

```console
ptc run debug-a-failed-run/debugger-agent.ptc-project.json --env-file .env
cat debug-a-failed-run/debugger-agent/.ptc/results/*.private.json
```

Selecting the inspection snapshot fixes the run's class to
`private_inspection`, so the model installation declares
`"accepts_data": ["normal", "private_inspection"]`. That is an operator
decision to send captured private evidence to a model vendor.

A verified live run traced the branching chain and correctly named
`pricing.rule`. Earlier runs, against a capture whose generated program did not
carry the order values, correctly abstained instead — and one run was
confidently wrong, blaming `orders` for not calling the unused decoy. That is
the point of the decoy, and the reason this layer reports evidence rather than
choosing a diagnosis.

## Optional: close the loop with a generated repair

`repair-agent/` extends the same incident into a bounded repair loop: the host
assembles an immutable incident packet from the capture before model turn one,
a phased agent run reads it under a tool-free `synthesize` mission, and the
model completes through exactly one typed terminal action —
`repair.terminal/propose` with a complete replacement component, or
`repair.terminal/abstain` with the missing evidence. The result contract
refuses anything else.

This leg uses `mix ptc.repair`, a maintainers surface that runs from a source
checkout rather than the standalone executable, so the commands below use
`mix ptc` from the repository root against `examples/debug-a-failed-run/`.

Capture the failure, then let the model propose:

```console
mix ptc run examples/debug-a-failed-run/target.ptc-project.json
mix ptc run examples/debug-a-failed-run/repair-agent.ptc-project.json --env-file .env
cat examples/debug-a-failed-run/repair-agent/.ptc/results/*.private.json
```

A verified live run proposed replacing `pricing.rule` with the 20-unit charge
its docstring states, citing the contradiction between the implementation and
its own contract. The proposal is model-authored and untrusted; nothing has
been executed or changed yet.

Validation is host policy and makes no model call. `mix ptc.repair` binds the
report to the currently installed component by source hash, materializes the
candidate through the static G1–G4 gate, and runs the host-owned suite —
`repair-agent/suite.json` holds the observed order plus two held-out cases the
model never saw:

```console
mix ptc.repair examples/debug-a-failed-run/target/ptc.json \
  --report examples/debug-a-failed-run/repair-agent/.ptc/results/*.private.json \
  --out examples/debug-a-failed-run/repair-agent/.ptc/candidate \
  --validation-suite examples/debug-a-failed-run/repair-agent/suite.json \
  --validation-out examples/debug-a-failed-run/repair-agent/.ptc/trial \
  --allow-live-validation
```

Promotion stays a separate, explicit decision. Run the same failing target
under the validated candidate without editing any file:

```console
mix ptc run examples/debug-a-failed-run/target.ptc-project.json \
  --component-override-descriptor examples/debug-a-failed-run/repair-agent/.ptc/candidate/descriptor.json
```

The run that exited 5 now exits 0 with `{"total":120}`. Passing cases prove
only the named inputs; they do not prove the candidate unique or correct
beyond them.

### Let the model navigate instead

The default repair arm deliberately front-loads a complete bounded incident
packet, then gives the model a tool-free synthesis phase. The navigable variant
tests a more coding-agent-like division of work. Its deterministic seed contains
only the failed-run summary, boundary failure, and collection catalog. The model
then chooses which `debug.nav` reads and relationship hops to make for up to six
turns. It can return an evidence summary to finish investigation early; either
way the host reserves two final turns for at most one decisive evidence read
and the typed terminal action:

```console
mix ptc run examples/debug-a-failed-run/repair-agent-navigable.ptc-project.json --env-file .env
cat examples/debug-a-failed-run/repair-agent-navigable/.ptc/results/*.private.json
```

The same application and prompt run without domain-specific changes against
the underdetermined and workflow-control captures:

```console
mix ptc run examples/debug-a-failed-run/repair-agent-navigable-ambiguous.ptc-project.json --env-file .env
mix ptc run examples/debug-a-failed-run/repair-agent-navigable-workflow-control.ptc-project.json --env-file .env
```

This is an experiment rather than a replacement recommendation. The comparison
asks whether adaptive evidence selection improves generality enough to justify
the extra model calls, navigation failures, and transcript volume.

Observed DeepSeek trials did not justify replacing deterministic curation. The
fully preloaded agent solved each attributable repair in one call and abstained
on the underdetermined arm. Navigable trials spent seven or eight calls: one
correctly abstained on the underdetermined arm, but the attributable mission arm
either exhausted its budget, abstained before reading its leaf sources, or
found the exact repair and lost it to terminal metadata validation. The
workflow-control arm found the faulty `main` source and authored the right
replacement expression, but used its reserved completion turns for another
read and a bare function fragment instead of submitting the report.

The useful shape is therefore not “preload everything” or “let the model browse
everything.” Keep a deterministic, provenance-preserving incident closure as
the default. Treat adaptive navigation as an escape hatch for a clearly named
missing evidence edge. A general agent also needs a framework-enforced way to
reserve a final terminal action while still permitting at most one last read;
prompt wording and a shared turn count did not enforce that protocol reliably.

### The abstain arm

`target-ambiguous/` plants a failure the evidence cannot attribute: two
constant components sum to the wrong total, and no contract pins either one.
The same repair agent — same manifest, same prompt, only the snapshot install
differs — must refuse to guess:

```console
mix ptc run examples/debug-a-failed-run/target-ambiguous.ptc-project.json
mix ptc run examples/debug-a-failed-run/repair-agent-ambiguous.ptc-project.json --env-file .env
cat examples/debug-a-failed-run/repair-agent-ambiguous/.ptc/results/*.private.json
```

A verified live run returned `insufficient-evidence`, naming exactly the
ambiguity: either component could absorb the difference, and one observed case
cannot distinguish them. `mix ptc.repair` refuses an abstention
(`repair_not_proposed`) — nothing is materialized from insufficient evidence.

### A workflow-control arm

`target-workflow-control/` changes the failure class without changing the
repair machinery. Inventory correctly returns a reservation identifier and
shipping correctly preserves the identifier it receives. The workflow calls
both missions in the right order but routes the incoming order identifier into
shipping instead of the reservation identifier returned by inventory. Its
cross-step invariant catches the mismatch and fails the run.

This arm tests whether diagnosis is overfit to faulty mission components. The
incident packet includes both generated mission programs, the frozen mission
source closure, and the bounded workflow source set. It does not name which
source is faulty. A repair must target the workflow `main` component and leave
the two correct mission components unchanged:

```console
mix ptc run examples/debug-a-failed-run/target-workflow-control.ptc-project.json
mix ptc run examples/debug-a-failed-run/repair-agent-workflow-control.ptc-project.json --env-file .env
cat examples/debug-a-failed-run/repair-agent-workflow-control/.ptc/results/*.private.json
```

Validate a proposed workflow replacement against the observed order and two
held-out identifier shapes:

```console
mix ptc.repair examples/debug-a-failed-run/target-workflow-control/ptc.json \
  --report examples/debug-a-failed-run/repair-agent-workflow-control/.ptc/results/*.private.json \
  --out examples/debug-a-failed-run/repair-agent-workflow-control/.ptc/candidate \
  --validation-suite examples/debug-a-failed-run/repair-agent/workflow-control-suite.json \
  --validation-out examples/debug-a-failed-run/repair-agent-workflow-control/.ptc/trial \
  --allow-live-validation
```

Promotion again uses the validated override rather than editing the example:

```console
mix ptc run examples/debug-a-failed-run/target-workflow-control.ptc-project.json \
  --component-override-descriptor examples/debug-a-failed-run/repair-agent-workflow-control/.ptc/candidate/descriptor.json
```

## What each file does

| Path | Role |
| --- | --- |
| `target/ptc.json` | the failing application and its `pricing` mission |
| `target.ptc-project.json` | captures trace, inspection, result, and envelope under `target/.ptc` |
| `ptc-host.json` | installs the target's capture as `failed-run-traces` and `debug.nav` |
| `debugger/ptc.json` | selects `debug.nav` and the snapshot providers into the `evidence` mission |
| `debugger/evidence.walk.clj` | the bounded walk over runs, errors, generated source, and prelude source |
| `debugger-agent/ptc.json` | the optional live-model variant over the same mission authority |
| `repair-agent/ptc.json` | the phased repair agent: packet acquisition, then a tool-free terminal decision |
| `repair-agent/preloaded.clj` | host workflow that acquires the incident packet before model turn one |
| `repair-agent/navigable.clj`, `repair-agent/ptc-navigable.json` | minimal-seed workflow and bounded model-navigated repair variant |
| `repair-agent/case.clj`, `repair-agent/workspace.clj` | the packet projection and the derived frozen working set |
| `repair-agent/repair.terminal.clj` | the two typed terminal actions: propose a replacement, or abstain |
| `repair-agent/suite.json` | host-owned validation cases, including held-out inputs the model never saw |
| `target-workflow-control/` | correct inventory and shipping missions connected by deliberately faulty workflow routing |
| `repair-agent/workflow-control-suite.json` | host-owned workflow validation across three identifier shapes |
| `target-ambiguous/` | the underdetermined variant whose evidence supports no single repair |

The inspection snapshot provider must be selected under the alias `debug.nav`,
because the shipped prelude binds `<alias>.runs`, `<alias>.open`, and
`<alias>.read`.

Inspection artifacts hold generated source, capability payloads, and frozen
component sources. They are not sanitized traces and should not be shared as
such. The complete walkthrough is in
[Debug a failed run](../../docs/guides/debugging-a-failed-run.md).
