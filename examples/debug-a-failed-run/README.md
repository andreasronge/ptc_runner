# Debug a failed run with another PTC run

This credential-free pair shows one PTC application navigating another
application's immutable failed run. No model, network access, or credential is
involved: both runs are deterministic.

`target/` prices an order through `orders` → `pricing.tax`, which branches to
`pricing.base` and `pricing.rule`. The rule adds 2 while the captured call
requires the subtotal plus 20, so the run fails. `pricing.discount` is an
unused decoy: nothing in the failing call reaches it.

`debugger/` installs the target's frozen trace and inspection directories as
snapshot providers and walks the evidence with the shipped `debug.nav` prelude.
It reports what the evidence shows and how completely the host proved each
edge. It never names a suspect.

## Run it

Capture the failed run first. It exits nonzero by design:

```console
mix ptc run examples/debug-a-failed-run/target.ptc-project.json
```

Then navigate that capture:

```console
mix ptc run examples/debug-a-failed-run/debugger.ptc-project.json
```

The debugger is a private run, so its value goes to
`examples/debug-a-failed-run/debugger/.ptc/results/` rather than stdout:

```console
cat examples/debug-a-failed-run/debugger/.ptc/results/*.private.json
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
rm -rf examples/debug-a-failed-run/target/.ptc
mix ptc run examples/debug-a-failed-run/target.ptc-project.json
```

## Optional: let a model walk it

`debugger-agent/` runs the shipped agent loop over the same authority. It is
the one part of this example that needs a credential. Name the environment file
on the command line rather than placing one in this directory, which ships
inside the published package:

```console
mix ptc run examples/debug-a-failed-run/debugger-agent.ptc-project.json --env-file .env
cat examples/debug-a-failed-run/debugger-agent/.ptc/results/*.private.json
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

## What each file does

| Path | Role |
| --- | --- |
| `target/ptc.json` | the failing application and its `pricing` mission |
| `target.ptc-project.json` | captures trace, inspection, result, and envelope under `target/.ptc` |
| `ptc-host.json` | installs the target's capture as `failed-run-traces` and `debug.nav` |
| `debugger/ptc.json` | selects `debug.nav` and the snapshot providers into the `evidence` mission |
| `debugger/evidence.walk.clj` | the bounded walk over runs, errors, generated source, and prelude source |
| `debugger-agent/ptc.json` | the optional live-model variant over the same mission authority |

The inspection snapshot provider must be selected under the alias `debug.nav`,
because the shipped prelude binds `<alias>.runs`, `<alias>.open`, and
`<alias>.read`.

Inspection artifacts hold generated source, capability payloads, and frozen
component sources. They are not sanitized traces and should not be shared as
such. The complete walkthrough is in
[Debug a failed run](../../docs/guides/debugging-a-failed-run.md).
