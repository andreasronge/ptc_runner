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

Every decision rests on these facts, each checked against the source at the
commit this plan was written on, so review need not re-derive them.

| Fact | Location |
| --- | --- |
| An override is applied to **both** component lists and the environment is derived from which one matched; ambiguity and non-selection are hard errors | `application_package.ex:344-354`, `application_package.ex:369-370` |
| Override selection and environment resolution are **private**; the only public route that applies an override is acquisition | `application_package.ex:342-344` |
| Acquisition accepts an override: `acquire_directory/2` takes `:component_override_descriptor` (a path), `acquire_memory/3` takes a built `:component_override` | `application_package.ex:55-56` |
| The resolved environment is deleted before it reaches the package, and `identity/1` never carried it | `application_package.ex:375`, `component_override.ex:245` |
| A **second** deletion strips the environment from a content record whose name already encodes it — load-bearing for `application_content_digest` | `application_package.ex:492-493` |
| `identity/1` output, minus the environment, *is* the encoded override record payload, so anything added to it changes content identity | `application_package.ex:493-495` |
| `apply/2` copies the **installed** component's dependencies onto the replacement; a candidate supplies source only | `component_override.ex:225` |
| Descriptor keys are validated manually in `@keys` and `decode_value/1`; `schema/0` drives diagnostic paths only | `component_override.ex:38`, `component_override.ex:292`, `component_override.ex:324-336`, `command_path.ex:38` |
| `origin` is hardcoded to `"component-override"` on the filesystem load path | `component_override.ex:111` |
| Capability **names** survive on the export table as `requires` and `tool_refs`; the rendered inventory keeps only a coarse effect and its resolver is private | `export.ex:72-73`, `mission_inventory.ex:277` |
| Export visibility is `:prompt` or `:discoverable`; `signature`/`type` are nullable and `doc` defaults to `nil`; the inventory projects a `nil` doc and contract without objection | `export.ex:57`, `export.ex:76-77`, `export.ex:88`, `mission_inventory.ex:161`, `mission_inventory.ex:258` |
| The capability-requirement check compares **names only** — granted capability keys plus implicit ones against export `tool_refs` | `environment.ex:67-79` |
| Real `%Capability{}` values exist only after provider acquisition | `run_builder.ex:768` |
| Providers statically declare the capability names they grant, as `provides` | `provider_descriptor.ex:28` |
| An export with no requirements and no declared effect resolves to `:unknown`, not `:read`, because `join_effects([])` falls through to `:unknown` | `compiler.ex:1030`, `compiler.ex:1511-1517` |
| Secure publication already exists: exclusive link, refuse-clobber, 0700 temp sibling, 0600 for private, ancestor ownership and permission checks | `result_artifact.ex:12-30` |
| `SourceCheck` fingerprints source with the same `sha256:` convention a descriptor carries | `source_check.ex:143` |
| `run --check` exists today but is deleted by the accepted stable-CLI grammar, which keeps `--component-override-descriptor` | `ptc.run.ex:70`, `stable-cli-contract.md` command surface |

## Scope note

The issue names four missing pieces: materialization, authoring provenance, a
promotion gate, and component shaping — and says of the gate's third criterion,
"the last one matters most". This plan delivers all four rather than
materialization alone.

The gate is not a policy engine. G2 and G3 are a null check and a per-export
set difference over an export table the compiler already produces. What makes
them worth building is that without them, "the model wrote something better"
stays unfalsifiable, which is the issue's stated reason for existing.

## Decisions

### D1 — Promotion replaces a selected component; it never introduces one

Adopt option 1 from the issue. A manifest that wants a generated helper
declares a placeholder component first, and the model rewrites it. This
preserves both hash checks, needs no kernel change, and keeps
`:override_component_not_selected` a hard error.

Two consequences must be documented, not discovered:

- `apply/2` copies the installed component's dependencies onto the
  replacement, so the placeholder fixes, up front, what the generated component
  may *consume*. A candidate cannot acquire a new dependency.
- The placeholder's dependency list does not control who may consume it. Any
  component that will call the generated exports must already declare a
  dependency on the placeholder, or promotion produces a component nothing can
  reach.

A placeholder is therefore a minimal valid `ns` with no exports, the intended
dependency list, and at least one declared consumer.

### D2 — Materialize first, then gate through the real acquisition path

Override selection and environment resolution are private, and the only public
operation that applies an override is acquisition. Rather than add a seam or
reimplement selection — either of which lets the gate's view drift from a run's
— the task materializes first and gates the materialized artifact.

```text
mix ptc.materialize MANIFEST --component ID --out DIR
    (--source PATH | --from-result PATH --result-pointer /json/pointer)
    [--origin-run-id ID] [--origin-prompt-hash sha256:…]
    [--origin-authored-at RFC3339] [--accept-widened-effect]
```

Order of operations:

1. Acquire the manifest with no override; locate the installed component in
   the package's public `workflow_components`/`mission_components` and hash its
   source to get `base_source_hash`.
2. Publish `candidate.clj` and `descriptor.json` into `DIR` through the
   **existing secure-publication primitive**, not a bespoke one. Model-authored
   source is treated as private unconditionally: 0700 directory, 0600 files,
   exclusive create, refuse-clobber, ancestor ownership and permission checks.
   This is not optional hardening — `--from-result` may read a *private* result
   artifact, and publishing its contents world-readable would declassify
   private model output. Slice 3 extracts that primitive from `ResultArtifact`
   rather than duplicating it.
3. Re-acquire the manifest with
   `component_override_descriptor: DIR/descriptor.json` — the exact path a run
   takes. Selection, ambiguity, non-selection, and both hash checks are
   enforced by production code, not by a copy of it.
4. Compile and compare export tables (G1–G3).
5. On any terminal failure, remove `DIR` and exit non-zero. A gate failure
   leaves nothing behind.

Source acquisition is explicit because `ptc.run --output` writes a JSON result
artifact, not raw Lisp. `--source` takes raw candidate bytes. `--from-result`
reads a result artifact under the existing document byte, JSON depth, and node
limits, then resolves one RFC 6901 pointer to one string, rejecting a
non-string or absent target. No other extraction is supported.

A run cannot invoke this. A run only *emits* source through channels it already
has, and the descriptor path stays unreachable from anything a run can
influence — the property `ComponentOverride` depends on.

### D3 — The gate is static, and says so

The accepted stable-CLI grammar deletes `run --check`, so building on it would
build on something scheduled for removal. But the replacement must not
overclaim either: `Environment.assemble/4` needs real `%Capability{}` values,
and those exist only after provider acquisition. A materialization task with no
host configuration cannot assemble, and passing an empty capability map would
reject every valid provider-backed requirement.

The gate therefore performs the **same name-based comparison** that
`bundle_requirements/3` performs — export `tool_refs` against granted
names — but sources those names statically from the package's provider
`provides` declarations plus the environment's implicit capabilities. No host
config, no provider session, no model call.

This is a **pre-filter, not a proof**. Run-time assembly remains authoritative;
the gate catches the typo and the ungranted name early, and the report says so
in those words. Overstating it as "assembles" would be false.

### D4 — Provenance is operator-asserted and kept out of content identity

`origin` is a bounded free-form string today, hardcoded on the filesystem load
path and absent from the descriptor, so a promoted component is anonymous
source with a hash.

Add an optional `"provenance"` object to the descriptor — named separately from
`origin`, which stays an opaque diagnostic label — with a closed, individually
validated key set and `additionalProperties: false`:

| Key | Descriptor shape |
| --- | --- |
| `run_id` | bounded ID |
| `prompt_hash` | `sha256:…` |
| `authored_at` | RFC 3339 string, parsed to `:utc_datetime` internally |
| `accept_widened_effect` | boolean |

There is no `model_id` field. The stable CLI privacy contract forbids
publishing raw model selectors, and `descriptor.json` is a published artifact,
so "descriptor-only" does not resolve the conflict; hashing does not either,
because model identifiers are a small enumerable domain and an unkeyed
SHA-256 of one is trivially reversed by dictionary. The authoring model is
identified through `run_id`, whose own run artifact records model identity on a
channel already authorized to carry it.

These values are **operator-asserted, not attested**. Nothing verifies that
`run_id` names the run that produced the bytes; `--from-result` does not
cross-check it. The report and the guide must say so, or provenance reads as a
guarantee the runtime never made.

**Provenance and environment must not enter `identity/1`.** That map *is* the
override record payload, so adding an asserted timestamp or an acceptance flag
to it would make `application_content_digest` depend on operator claims about
authorship rather than on content. Instead:

- `identity/1` stays exactly as it is — component ID and both hashes.
- A new `attribution/1` returns the resolved environment plus provenance.
- The package carries attribution in a field that does **not** feed content
  records, and `run-started` publishes it.

This also means neither existing deletion moves. The one at
`application_package.ex:375` keeps environment out of the package-facing
identity, and the one at `:493` keeps it out of the record payload where the
record *name* already encodes it. Both stay.

### D5 — Component shaping is a template and a diagnostic, not a prompt hint

Wrapping authored forms in an `ns` with visibility, a namespace docstring, and
per-export `:signature` is the authoring application's job. The runtime ships a
documented component template and actionable gate diagnostics; it adds no
shaping hints to any system or planner prompt. Prompts stay domain-blind.

## Gate criteria

Each criterion reports `pass`, `fail`, or `blocked` — G2 and G3 have no export
table when G1 fails, and calling that `fail` would misattribute the cause.

| ID | Criterion | Basis |
| --- | --- | --- |
| G1 | Candidate resolves to exactly one environment and that environment's bundle compiles | acquisition, `Kernel.compile_bundle/1` |
| G2 | Every `:prompt`-visible export declares a `:signature` (or `:type` for a value) and a non-empty docstring | `Export.visibility`, `Export.signature`, `Export.type`, `Export.doc` |
| G3 | No export widens, compared **per export ref** | `Export.effect`, `Export.requires`, `Export.tool_refs` |
| G4 | Every `tool_refs` name is statically declared by some provider `provides` or is implicit for that environment | mirrors `environment.ex:67-79`, sourced from `provider_descriptor.ex:28` |
| G5 | Declared dependencies unchanged — **preserved by construction**, reported, not enforced | `component_override.ex:225` |
| G6 | Candidate ≤ 1 MiB and encoded descriptor ≤ 64 KiB, checked on the bytes actually written | existing `ComponentOverride` bounds |

G2 is a **promotion policy**, not a claim the runtime rejects such exports. It
does not: the inventory projects `nil` docs and contracts without objection.
That is exactly why the gate must impose it — an export promoted without a
signature and docstring compiles, ships, and is then useless to the next run's
model.

G3 compares capability name sets **per export ref**, never an
application-wide union. A union comparison silently misses the main case: if
base export `A` uses `read-tool` and `B` uses `write-tool`, then `A` gaining
`write-tool` adds no name outside the union while materially widening `A`.
Effect widening is ordered `read < unknown < write`, matching `join_effects/1`.

| Export | Rule |
| --- | --- |
| In base and candidate | Widening if its effect moves up the lattice, or its `requires`/`tool_refs` set gains a name |
| Added | Widening if it requires any capability name, or its effect is `:write` |
| Added, `:unknown` effect, no requirements | **Indeterminate** — reported, not failed |
| Removed or renamed | Reported as a **surface change**, never counted as widening |

The indeterminate row exists because `join_effects([])` returns `:unknown`, so
an ordinary pure helper with no declared effect lands there. Failing on it
would make every added helper a widening and train operators to pass
`--accept-widened-effect` reflexively, which destroys the flag's meaning.

An added export that requires anything *is* a widening, so the first promotion
of an export-free placeholder into something that reaches a capability requires
`--accept-widened-effect` once. That is the honest reading: going from no reach
to some reach is exactly what an operator should acknowledge.

A widening is terminal without that flag, which is recorded in the report and
in the descriptor's provenance. An override "changes which source compiles,
never what compilation permits", so a widening candidate is not a security
hole — but it is a different risk profile and must not pass silently.

G6 is evaluated inside materialization, on the final encoded bytes, because
descriptor size is not knowable until path, provenance, and the acceptance
decision are all encoded.

## Implementation slices

Landing as one PR; separate commits.

1. **Descriptor provenance round-trip.** Add the closed `provenance` object.
   This touches more than `schema/0`: `@keys` and `decode_value/1` validate
   manually and currently require every key, so optional-key handling,
   duplicate-key path reporting, the struct, `load/1`, `load_application/3`,
   and the new `attribution/1` all change together. `identity/1` is untouched.
   Absent provenance keeps today's default.
2. **Promotion gate.** New `PtcRunner.Kernel.CandidatePromotion` implementing
   G1–G5 over an acquired effective package, returning a closed
   `pass | fail | blocked` report. No filesystem writes.
3. **Materialization task.** `mix ptc.materialize` — argument handling, both
   acquisition modes, secure private publication via the primitive extracted
   from `ResultArtifact`, G6 on final bytes, deterministic report, non-zero
   exit and directory removal on gate failure.
4. **Documentation.** The placeholder idiom, its consumer requirement, the
   operator-asserted nature of provenance, the gate's pre-filter status, and
   the promotion loop in the Kernel maintainer guide and running-and-debugging
   guide; component template; `docs/plans/README.md` index entry.

## Verification

- Unit coverage per criterion: an effect widening; a capability name added to
  one export while present on another (the union-comparison trap); an added
  export requiring a capability against an empty base; an added pure helper
  (must report indeterminate, not fail); a removed export; a `:prompt` export
  missing a signature; a candidate naming a capability no provider declares
  (must fail G4); a candidate that fails to compile (G2/G3 `blocked`); an ID
  selected in both environments (`:ambiguous_override_target`).
- Publication: `--out` at an existing directory fails, an existing **empty**
  directory is not replaced, files are `0600` inside a `0700` directory, and a
  candidate extracted from a private result artifact is never world-readable.
- `application_content_digest` of an override-bearing application is byte-for-
  byte unchanged by slice 1, both with and without provenance present —
  pinning that attribution stayed out of content identity.
- Round-trip: materialize, run with the produced descriptor, assert
  `run-started` names base hash, candidate hash, environment, and projected
  provenance.
- One e2e: a mission authors source, `check-source` reports the same `sha256:`
  digest the descriptor carries, the task materializes and gates it, and a
  second run executes the promoted component.
- `mix precommit` before every commit.

## Non-goals

- Making `mission_inventory` mutable or re-hashable mid-run.
- Letting a manifest or a generated program name an override.
- Automatic promotion, and any claim that provenance is attested rather than
  asserted, or that the gate proves what run-time assembly proves.
- Creating genuinely new component IDs from generated source (D1).
- A general result-artifact extraction language. `--from-result` resolves one
  RFC 6901 pointer to one string.
