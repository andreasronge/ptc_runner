# Promoting model-authored source into an attested component

**Status:** proposed; awaiting review. Closes
[#1167](https://github.com/andreasronge/ptc_runner/issues/1167).

A model can already author a working library inside a run: source handed to
`kernel/eval-source` may contain `def`/`defn`, those definitions persist for
the life of the run, and they may call mission capabilities. What it cannot do
is leave one behind. A runtime `defn` is not in the `FrozenBundle`, is not
covered by any component source hash, is absent from `mission_inventory`, and
dies at end of run.

That gap is correct and stays. `mission_inventory_hash` is frozen into
`run-started` and folded into analysis-profile identity beside `bundle_hash`,
so one value answers "exactly what surface was this model shown, for this whole
run". This plan does not touch it. It closes the other loop: generated source
becomes a real component, compiled and attested, used by a *later* run.

`ComponentOverride` already does the dangerous part — two-sided hash
verification, confined single-open reads, verified identity recorded in
`run-started`, no manifest or program authority. Its moduledoc names the
boundary this plan implements from the outside:

> Nothing here writes. Materializing a candidate is a separate trusted host
> step, and promotion stays an explicit human decision.

## Decisions

### D1 — Promotion improves a selected component; it never introduces one

Adopt option 1 from the issue. A manifest that wants a generated helper
declares a placeholder component first, and the model rewrites it.

This preserves both hash checks unchanged, needs no kernel change, and keeps
`:override_component_not_selected` a hard error. Introducing a genuinely new
component ID stays the ordinary human workflow.

One consequence is load-bearing and must be documented, not discovered:
`ComponentOverride.apply/2` preserves the *installed* component's declared
dependencies, so a candidate cannot acquire a dependency the placeholder did
not already declare. The placeholder therefore fixes, up front, the dependency
surface the generated component is permitted to use. A placeholder is a
minimal valid `ns` with no exports and the intended dependency list.

### D2 — Materialization is a host command, never a runtime capability

Add one Mix task:

```text
mix ptc.materialize MANIFEST --component ID --source PATH --out DIR
    [--origin-run-id ID] [--origin-prompt-hash sha256:…]
    [--accept-widened-effect]
```

It resolves the installed component from the manifest, computes
`base_source_hash` from the bytes actually installed now, hashes the authored
source, runs the promotion gate (D3), and writes `candidate.clj` plus
`descriptor.json` into a confined output directory. It refuses to overwrite an
existing file and emits deterministic JSON.

A run cannot invoke this. A run only *emits* source through channels it already
has — its result value, `--output`, or a private sink. The operator carries
those bytes to the task. The descriptor path stays unreachable from anything a
run can influence, which is the property `ComponentOverride` depends on.

### D3 — The gate does not depend on `run --check`

`docs/plans/lisp-kernel/stable-cli-contract.md` removes `run --check` from the
target grammar while keeping `--component-override-descriptor`. Building the
promotion gate on `--check` would therefore be building on something scheduled
for deletion.

The gate instead compiles in-process: it applies the candidate to the selected
component list and calls `Kernel.compile_bundle/1` on the effective components,
which is exactly the assembly a run performs, without a provider session or a
model call. `mix ptc.materialize` is provider-free and never opens a session.

Follow-up, not in this plan: when the stable CLI reaches slice 9, fold this
task into the shared grammar as a `ptc candidate` command. The task is written
against `ApplicationPackage` and `Kernel.compile_bundle/1`, not against Mix
argv handling, so that fold is mechanical.

### D4 — Provenance is a closed, validated object, not free-form text

`origin` is a bounded free-form string today, hardcoded to
`"component-override"` in `ComponentOverride.load/1` and absent from the
descriptor schema, so a promoted component is anonymous source with a hash.

Add an optional `"origin"` object to the descriptor schema with a closed key
set — `run_id`, `prompt_hash`, `authored_at`, `model_id` — each individually
pattern-validated, `additionalProperties: false`, and canonically encoded into
`Component.origin` within its existing 1024-byte bound.

A closed object rather than a string is deliberate. The stable CLI privacy
contract forbids publishing filesystem paths and raw model selectors, and a
free-form origin that reaches `run-started` is an uncontrolled channel for
both. Resolution: the descriptor — an operator-local file — carries `model_id`
verbatim, but `ComponentOverride.identity/1` projects only `run_id`,
`prompt_hash`, `authored_at`, and a hash of `model_id` into the artifact.

### D5 — Component shaping is a template and a diagnostic, not a prompt hint

Wrapping authored forms in an `ns` with visibility, a namespace docstring, and
per-export `:signature` is the authoring application's job. The runtime ships a
documented component template and actionable gate diagnostics; it does not add
shaping hints to any system or planner prompt. Prompts stay domain-blind.

## Gate criteria

Checked in this order; each reports pass/fail independently so one run of the
task tells the operator everything that is wrong.

| ID | Criterion | Basis |
| --- | --- | --- |
| G1 | Candidate compiles and the effective bundle assembles | `Kernel.compile_bundle/1` |
| G2 | Every prompt-visible export declares a `:signature` and a non-empty docstring | `Prelude.prompt_exports/1`, `Export.signature`, `Export.doc` |
| G3 | No export widens its resolved effect relative to the base, and no new export reaches a capability the base did not | resolved export effect, as `mission_inventory` computes it |
| G4 | Declared dependencies are unchanged | already enforced by `ComponentOverride.apply/2`; restated so the report is complete |
| G5 | Source ≤ 1 MiB and descriptor ≤ 64 KiB | existing `ComponentOverride` bounds |

G2 matters because an export without a `:signature` and docstring has no
`export-meta`, so it is invisible to `fit/handles?` and useless to the next
run's model even though it compiled.

G3 is the one that must be surfaced rather than merely permitted. An override
"changes which source compiles, never what compilation permits", so a widening
candidate is not a security hole — but it is a different risk profile and must
not pass silently. A G3 failure is terminal unless the operator passes
`--accept-widened-effect`, which is recorded in the report and in the written
descriptor's origin.

## Implementation slices

Each slice is independently reviewable and committed separately.

1. **Descriptor provenance round-trip.** Extend the descriptor schema with the
   closed `origin` object, thread it through `ComponentOverride.load/1`,
   `load_application/3`, and `identity/1`, and record the projected identity in
   `run-started`. Absent `origin` keeps today's `"component-override"` default.
2. **Promotion gate.** New `PtcRunner.Kernel.CandidatePromotion` implementing
   G1–G5 against an `ApplicationPackage` and candidate source, returning a
   closed report. Pure with respect to the filesystem; no writes.
3. **Materialization task.** `mix ptc.materialize` — argument handling,
   confined non-clobbering writes, deterministic report rendering, non-zero
   exit on gate failure.
4. **Documentation.** The placeholder idiom and the promotion loop in the
   Kernel maintainer guide and the running-and-debugging guide; component
   template; `docs/plans/README.md` index entry.

## Verification

- Unit coverage for each gate criterion, including a candidate that widens an
  effect and one whose export lacks a signature.
- Round-trip test: materialize from authored source, then run with the produced
  descriptor and assert `run-started` names base hash, candidate hash, and the
  projected origin.
- One e2e proving the full loop on a real run: a mission authors source,
  `check-source` reports the same `sha256:` digest the descriptor carries, the
  task materializes and gates it, and a second run executes the promoted
  component.
- `mix precommit` before every commit.

## Non-goals

- Making `mission_inventory` mutable or re-hashable mid-run.
- Letting a manifest or a generated program name an override.
- Automatic promotion. Promotion stays an explicit human decision; this plan
  makes that decision cheap to reach and well-evidenced, not unnecessary.
- Creating genuinely new component IDs from generated source (D1).
