# Debug a failed run with another PTC run

This credential-free pair shows one PTC application navigating another
application's immutable failed run. No model, network access, or credential is
involved: both runs are deterministic.

`target/` prices an order through a three-component mission. `pricing.rule`
adds 2 while the captured call requires the subtotal plus 20, so the run fails.
`pricing.discount` is an unused decoy: nothing in the failing call reaches it.

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
required total, the frozen dependency closure `orders` → `pricing.tax` →
`pricing.rule`, and the source of each. The decoy never appears, because the
walk follows frozen dependency edges rather than the manifest component list.

## Check the diagnosis

The evidence supports one change: `pricing.rule/apply-standard` adds 2 where
the captured call requires 20. Edit `target/pricing.rule.clj`, remove the stale
capture, and rerun the target to see it pass:

```console
rm -rf examples/debug-a-failed-run/target/.ptc
mix ptc run examples/debug-a-failed-run/target.ptc-project.json
```

## What each file does

| Path | Role |
| --- | --- |
| `target/ptc.json` | the failing application and its `pricing` mission |
| `target.ptc-project.json` | captures trace, inspection, result, and envelope under `target/.ptc` |
| `ptc-host.json` | installs the target's capture as `failed-run-traces` and `debug.nav` |
| `debugger/ptc.json` | selects `debug.nav` and the snapshot providers into the `evidence` mission |
| `debugger/evidence.walk.clj` | the bounded walk over runs, errors, generated source, and prelude source |

The inspection snapshot provider must be selected under the alias `debug.nav`,
because the shipped prelude binds `<alias>.runs`, `<alias>.open`, and
`<alias>.read`.

Inspection artifacts hold generated source, capability payloads, and frozen
component sources. They are not sanitized traces and should not be shared as
such. The complete walkthrough is in
[Debug a failed run](../../docs/guides/debugging-a-failed-run.md).
