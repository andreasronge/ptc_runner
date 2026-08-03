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

## Verified basis

Every decision below rests on these facts, each checked against the source at
the commit this plan was written on. They are recorded here so review does not
have to re-derive them.

| Fact | Location |
| --- | --- |
| An override is applied to **both** component lists, and the environment is derived from which one matched | `application_package.ex:344` |
| Ambiguity and non-selection are already hard errors: `:ambiguous_override_target`, `:override_component_not_selected` | `application_package.ex:369` |
| The resolved environment is already recorded on the override identity | `application_package.ex:353` |
| `apply/2` copies the **installed** component's dependencies onto the replacement; a candidate supplies source only | `component_override.ex:225` |
| Descriptor keys are validated twice — declaratively in `schema/0` and manually in `@keys` plus `decode_value/1` | `component_override.ex:38`, `component_override.ex:292` |
| `origin` is hardcoded to `"component-override"` on the filesystem load path | `component_override.ex:111` |
| Capability **names** survive on the export table as `requires` (`"tool:"`-prefixed) and `tool_refs`; the rendered inventory keeps only a coarse resolved effect and `resolved_export_effect/2` is private | `export.ex:72`, `mission_inventory.ex:277` |
| Export visibility is `:prompt` or `:discoverable`; `doc`, `signature`, and `type` are all nullable, and the inventory projects a `nil` doc and a `nil` contract without objection | `export.ex:68`, `export.ex:88`, `mission_inventory.ex:161`, `mission_inventory.ex:258` |
| `SourceCheck` fingerprints source with the same `sha256:` convention a descriptor carries | `source_check.ex:143` |
| `run --check` exists today but is deleted by the accepted stable-CLI grammar, which keeps `--component-override-descriptor` | `ptc.run.ex:70`, `stable-cli-contract.md` command surface |

## Decisions

### D1 — Promotion replaces a selected component; it never introduces one

Adopt option 1 from the issue. A manifest that wants a generated helper
declares a placeholder component first, and the model rewrites it. This
preserves both hash checks, needs no kernel change, and keeps
`:override_component_not_selected` a hard error.

The materialization task does **not** re-implement component selection. It
drives the existing `ApplicationPackage` override path, which already resolves
the target environment, rejects an ID selected in both environments as
`:ambiguous_override_target`, and rejects an unselected ID. Reusing it is what
keeps the gate's view of the effective application identical to a run's.

Two consequences must be documented, not discovered:

- `apply/2` copies the installed component's dependencies onto the
  replacement, so the placeholder fixes, up front, what the generated component
  may *consume*. A candidate cannot acquire a new dependency.
- The placeholder's own dependency list does not control who may consume it.
  Any component that will call the generated exports must already declare a
  dependency on the placeholder, or promotion produces a component nothing can
  reach.

A placeholder is therefore a minimal valid `ns` with no exports, the intended
dependency list, and at least one declared consumer.

### D2 — Materialization is a host command, never a runtime capability

Add one Mix task:

```text
mix ptc.materialize MANIFEST --component ID --out DIR
    (--source PATH | --from-result PATH --result-pointer /json/pointer)
    [--origin-run-id ID] [--origin-prompt-hash sha256:…]
    [--origin-model-id ID] [--origin-authored-at RFC3339]
    [--accept-widened-effect]
```

Source acquisition is explicit because `ptc.run --output` writes a JSON result
artifact, not raw Lisp. `--source` takes a file of raw candidate bytes.
`--from-result` reads a run's result artifact and extracts one string at a JSON
pointer, bounded by the existing `@max_source_bytes`, rejecting a non-string or
absent target. No other extraction is supported; the task never decodes an
arbitrary shape looking for something source-like.

Provenance values are supplied by the operator, not inferred. `authored_at`
defaults to the task's wall clock only when the flag is absent, and is recorded
as `:utc_datetime`.

A run cannot invoke this. A run only *emits* source through channels it already
has. The descriptor path stays unreachable from anything a run can influence,
which is the property `ComponentOverride` depends on.

Both files are written atomically: the task materializes into a fresh sibling
temporary directory and renames it into place, so a half-written
candidate/descriptor pair is never observable and a check-then-write race
cannot silently clobber.

### D3 — The gate does not depend on `run --check`

`docs/plans/lisp-kernel/stable-cli-contract.md` deletes `run --check` while
keeping `--component-override-descriptor`, so building the gate on `--check`
would build on something scheduled for removal.

The gate instead assembles in-process. It applies the candidate through
`ApplicationPackage`, takes the resolved environment from that result, and
compiles the affected environment's components with
`Kernel.compile_bundle/1`. Workflow and mission components are separate lists
compiled separately; the plan does not claim one call reproduces a whole run.
The gate is provider-free and never opens a session.

Follow-up, not in this plan: when the stable CLI reaches slice 9, fold the task
into the shared grammar as a `ptc candidate` command. It is written against
`ApplicationPackage` and `Kernel.compile_bundle/1`, not Mix argv handling, so
the fold is mechanical.

### D4 — Provenance is a closed object, carried on the override

`origin` is a bounded free-form string today, hardcoded on the filesystem load
path and absent from the descriptor schema, so a promoted component is
anonymous source with a hash.

Add an optional `"origin"` object to the descriptor with a closed, individually
pattern-validated key set and `additionalProperties: false`:

| Key | Shape | Projected into `run-started`? |
| --- | --- | --- |
| `run_id` | bounded ID | yes |
| `prompt_hash` | `sha256:…` | yes |
| `authored_at` | RFC 3339 UTC | yes |
| `accept_widened_effect` | boolean | yes |
| `model_id` | bounded ID | **no** |

`model_id` is descriptor-only. It is not projected in any form — not verbatim,
because the stable CLI privacy contract forbids publishing raw model selectors,
and not hashed, because model identifiers are a small enumerable domain and an
unkeyed SHA-256 of one is trivially reversed by dictionary. An operator who
wants the model in the artifact must publish it through a channel already
authorized to carry it.

`accept_widened_effect` is part of the closed set precisely because G3 records
the operator's acknowledgement there; omitting it would make the schema reject
the task's own output.

Structured provenance lives on the `ComponentOverride` struct and flows to the
artifact through `identity/1`, which already carries the environment.
`Component.origin` keeps a fixed diagnostic label. Encoding a canonical JSON
blob into that opaque bounded binary would be needless coupling to a field
whose only job is diagnostics.

### D5 — Component shaping is a template and a diagnostic, not a prompt hint

Wrapping authored forms in an `ns` with visibility, a namespace docstring, and
per-export `:signature` is the authoring application's job. The runtime ships a
documented component template and actionable gate diagnostics; it adds no
shaping hints to any system or planner prompt. Prompts stay domain-blind.

## Gate criteria

Each criterion reports `pass`, `fail`, or **`blocked`** — G2 and G3 have no
export table to inspect when G1 fails, and reporting that as `fail` would
misattribute the cause.

| ID | Criterion | Basis |
| --- | --- | --- |
| G1 | Candidate applies to exactly one environment and that environment's bundle compiles | `ApplicationPackage` override path, `Kernel.compile_bundle/1` |
| G2 | Every `:prompt`-visible export declares a `:signature` (or `:type` for a value) and a non-empty docstring | `Export.visibility`, `Export.signature`, `Export.type`, `Export.doc` |
| G3 | No export widens its effect, and the candidate's exports require no capability name the base's did not | `Export.effect`, `Export.requires`, `Export.tool_refs` |
| G4 | Declared dependencies are unchanged — **preserved by construction**, reported for completeness, not enforced | `component_override.ex:225` |
| G5 | Candidate ≤ 1 MiB; the encoded descriptor ≤ 64 KiB, checked after final encoding | existing `ComponentOverride` bounds |

G2 is a **promotion policy**, not a claim that the runtime rejects such
exports. It does not: the inventory projects `nil` contracts and empty docs
without objection. That is exactly why the gate has to impose the requirement —
an export promoted without a signature and docstring compiles, ships, and is
then useless to the next run's model.

G3 compares capability name sets, not the rendered effect projection, because
the projection discards the names and its resolver is private. Widening is
defined over the effect lattice `read < unknown < write`, matching the existing
resolver's precedence. Comparison is by export `ref`:

- an export present in both whose effect moves up the lattice is a widening;
- an export whose `requires`/`tool_refs` set gains a name absent from the union
  of the base's is a widening;
- an export removed or renamed is reported as a **surface change**, not a
  widening, and never silently ignored.

A G3 widening is terminal unless the operator passes
`--accept-widened-effect`, which is recorded in the report and in the written
descriptor's origin. An override "changes which source compiles, never what
compilation permits", so a widening candidate is not a security hole — but it
is a different risk profile and must not pass silently.

## Implementation slices

Landing as one PR; separate commits.

1. **Descriptor provenance round-trip.** Add the closed `origin` object. This
   touches more than `schema/0`: `@keys` and `decode_value/1` validate keys
   manually and both currently require every key, so optional-key handling,
   duplicate-key path reporting, the struct, `load/1`, `load_application/3`,
   and `identity/1` all change together. Absent `origin` keeps today's default.
2. **Promotion gate.** New `PtcRunner.Kernel.CandidatePromotion` implementing
   G1–G5 against an `ApplicationPackage` and candidate source, returning a
   closed `pass | fail | blocked` report. No filesystem writes.
3. **Materialization task.** `mix ptc.materialize` — argument handling, both
   source-acquisition modes, atomic directory rename, deterministic report,
   non-zero exit on gate failure.
4. **Documentation.** The placeholder idiom, its consumer requirement, and the
   promotion loop in the Kernel maintainer guide and running-and-debugging
   guide; component template; `docs/plans/README.md` index entry.

## Verification

- Unit coverage per gate criterion: a widened effect, a newly required
  capability name, a `:prompt` export missing a signature, a removed export, a
  candidate that fails to compile (asserting G2/G3 report `blocked`), and an ID
  selected in both environments (asserting `:ambiguous_override_target`).
- Round-trip test: materialize, then run with the produced descriptor and
  assert `run-started` names base hash, candidate hash, environment, and the
  projected origin — and that `model_id` appears nowhere in the artifact.
- One e2e proving the loop: a mission authors source, `check-source` reports
  the same `sha256:` digest the descriptor carries, the task materializes and
  gates it, and a second run executes the promoted component.
- `mix precommit` before every commit.

## Non-goals

- Making `mission_inventory` mutable or re-hashable mid-run.
- Letting a manifest or a generated program name an override.
- Automatic promotion. Promotion stays an explicit human decision; this plan
  makes that decision cheap to reach and well-evidenced, not unnecessary.
- Creating genuinely new component IDs from generated source (D1).
- A general result-artifact extraction language. `--from-result` resolves one
  JSON pointer to one string.
