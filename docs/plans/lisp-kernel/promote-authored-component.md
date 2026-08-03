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
| An override is applied to **both** component lists, and the environment is derived from which one matched | `application_package.ex:344` |
| Ambiguity and non-selection are already hard errors | `application_package.ex:369`, `application_package.ex:370` |
| The resolved environment is computed but deleted before it reaches the package, and `identity/1` never carried it | `application_package.ex:375`, `component_override.ex:245` |
| A **second** deletion strips the environment from content records, where it is already encoded in the record name — this one is load-bearing for `application_content_digest` | `application_package.ex:493` |
| Override selection and environment resolution are **private**; the only public route that applies an override is acquisition | `application_package.ex:342` |
| Acquisition accepts an override: `acquire_directory/2` takes `:component_override_descriptor` (a path), `acquire_memory/3` takes a built `:component_override` | `application_package.ex:55`, `application_package.ex:56` |
| `apply/2` copies the **installed** component's dependencies onto the replacement; a candidate supplies source only | `component_override.ex:225` |
| Descriptor keys are validated manually in `@keys` and `decode_value/1`; `schema/0` drives diagnostic paths, not validation | `component_override.ex:38`, `component_override.ex:292` |
| `origin` is hardcoded to `"component-override"` on the filesystem load path | `component_override.ex:111` |
| Capability **names** survive on the export table as `requires` (`"tool:"`-prefixed) and `tool_refs`; the rendered inventory keeps only a coarse resolved effect and its resolver is private | `export.ex:72`, `export.ex:73`, `mission_inventory.ex:277` |
| Export visibility is `:prompt` or `:discoverable`; `signature` and `type` are nullable, `doc` defaults to `nil`, and the inventory projects a `nil` doc and `nil` contract without objection | `export.ex:76`, `export.ex:77`, `export.ex:88`, `mission_inventory.ex:161`, `mission_inventory.ex:258` |
| Capability requirements are validated during **environment assembly**, not bundle compilation | `environment.ex:17` |
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
    [--origin-model-id ID] [--origin-authored-at RFC3339]
    [--accept-widened-effect]
```

Order of operations:

1. Acquire the manifest with no override; locate the installed component in
   the package's public `workflow_components`/`mission_components` and hash its
   source to get `base_source_hash`.
2. Create `DIR` with an exclusive `File.mkdir/1`. Existing directory is
   `:eexist` and terminal. This, not a rename, is the no-clobber primitive:
   POSIX `rename` may replace an existing empty destination directory, so an
   exclusive create is the only publication that cannot silently clobber.
3. Write `candidate.clj` and `descriptor.json` into `DIR`.
4. Re-acquire the manifest with
   `component_override_descriptor: DIR/descriptor.json` — the exact path a run
   takes. Selection, ambiguity, non-selection, and both hash checks are
   enforced by production code, not by a copy of it.
5. Assemble and compare export tables (G1–G3).
6. On any terminal failure, remove `DIR` and exit non-zero. A gate failure
   leaves nothing behind.

Source acquisition is explicit because `ptc.run --output` writes a JSON result
artifact, not raw Lisp. `--source` takes raw candidate bytes. `--from-result`
reads a result artifact under the existing document byte, JSON depth, and node
limits, then resolves one RFC 6901 pointer to one string, rejecting a
non-string or absent target. No other extraction is supported.

A run cannot invoke this. A run only *emits* source through channels it already
has, and the descriptor path stays unreachable from anything a run can
influence — the property `ComponentOverride` depends on.

### D3 — The gate does not depend on `run --check`

The accepted stable-CLI grammar deletes `run --check` while keeping
`--component-override-descriptor`, so building the gate on `--check` would
build on something scheduled for removal. Acquisition plus assembly needs no
provider session and no model call.

The gate assembles as well as compiles. Capability requirements are checked in
`Environment.assemble/4`, not in `Kernel.compile_bundle/1`, so a candidate
naming an ungranted capability would otherwise pass materialization and fail
only inside a later run.

Follow-up, not in this plan: when the stable CLI reaches slice 9, fold the task
into the shared grammar as a `ptc candidate` command.

### D4 — Provenance is operator-asserted, closed, and separate from `origin`

`origin` is a bounded free-form string today, hardcoded on the filesystem load
path and absent from the descriptor, so a promoted component is anonymous
source with a hash.

Add an optional `"provenance"` object to the descriptor — named separately from
`origin`, which stays an opaque diagnostic label on both `ComponentOverride`
and `Component` — with a closed, individually validated key set and
`additionalProperties: false`:

| Key | Descriptor shape | Projected? |
| --- | --- | --- |
| `run_id` | bounded ID | yes |
| `prompt_hash` | `sha256:…` | yes |
| `authored_at` | RFC 3339 string, parsed to `:utc_datetime` internally | yes |
| `accept_widened_effect` | boolean | yes |
| `model_id` | bounded ID | **no** |

These values are **operator-asserted, not attested**. Nothing verifies that
`run_id` names the run that produced the bytes; `--from-result` does not
cross-check it. The report and the guide must say so, or provenance reads as a
guarantee the runtime never made.

`model_id` is descriptor-only, projected in no form — not verbatim, because the
stable CLI privacy contract forbids publishing raw model selectors, and not
hashed, because model identifiers are a small enumerable domain and an unkeyed
SHA-256 of one is trivially reversed by dictionary.

`accept_widened_effect` is in the closed set because G3 records the operator's
acknowledgement there; omitting it would make the schema reject the task's own
output.

**This requires two explicit projection changes**, because neither value
reaches an artifact today: `identity/1` must carry the resolved `environment`,
and the package-identity path at `application_package.ex:375` must stop
deleting it. Without both, the round-trip assertion below has nothing to
assert.

The deletion at `application_package.ex:493` must be left alone. It strips the
environment from a **content record** whose name already encodes it
(`"mission/component-id"`), so removing that call would double-encode the
environment and change `application_content_digest` — an identity-bearing value
— for every application that uses an override. The two deletions look
identical and are not. A regression test must pin the content digest of an
override-bearing application across this change.

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
| G1 | Candidate resolves to exactly one environment, its bundle compiles, and the environment assembles with its granted capabilities | acquisition, `Kernel.compile_bundle/1`, `Environment.assemble/4` |
| G2 | Every `:prompt`-visible export declares a `:signature` (or `:type` for a value) and a non-empty docstring | `Export.visibility`, `Export.signature`, `Export.type`, `Export.doc` |
| G3 | No export widens, compared **per export** | `Export.effect`, `Export.requires`, `Export.tool_refs` |
| G4 | Declared dependencies unchanged — **preserved by construction**, reported, not enforced | `component_override.ex:225` |
| G5 | Candidate ≤ 1 MiB and the encoded descriptor ≤ 64 KiB, checked on the bytes actually written | existing `ComponentOverride` bounds |

G2 is a **promotion policy**, not a claim the runtime rejects such exports. It
does not: the inventory projects `nil` docs and contracts without objection.
That is exactly why the gate must impose it — an export promoted without a
signature and docstring compiles, ships, and is then useless to the next run's
model.

G3 compares capability **name sets per export ref**, never an
application-wide union. A union comparison silently misses the main case: if
base export `A` uses `read-tool` and base export `B` uses `write-tool`, then
`A` gaining `write-tool` adds no name outside the union while materially
widening `A`. Effect widening is ordered `read < unknown < write`, matching the
existing resolver's precedence.

| Export | Rule |
| --- | --- |
| In base and candidate | Widening if its effect moves up the lattice, or its `requires`/`tool_refs` set gains a name |
| Added | Widening unless it requires nothing. There is no baseline to compare against, and silence would make the export-free placeholder case — the primary one — vacuously safe |
| Removed or renamed | Reported as a **surface change**, never silently ignored, and never counted as widening |

The added-export rule means the first promotion of an export-free placeholder
is a widening by construction and requires `--accept-widened-effect`. That is
the honest reading: going from no capability reach to some reach is exactly the
change an operator should have to acknowledge once.

A widening is terminal without that flag, which is recorded in the report and
in the descriptor's provenance. An override "changes which source compiles,
never what compilation permits", so a widening candidate is not a security
hole — but it is a different risk profile and must not pass silently.

G5 is evaluated inside materialization, on the final encoded bytes, because
descriptor size is not knowable until path, provenance, and the acceptance
decision are all encoded.

## Implementation slices

Landing as one PR; separate commits.

1. **Descriptor provenance round-trip.** Add the closed `provenance` object.
   This touches more than `schema/0`: `@keys` and `decode_value/1` validate
   manually and currently require every key, so optional-key handling,
   duplicate-key path reporting, the struct, `load/1`, `load_application/3`,
   and `identity/1` all change together. Carry `environment` through to the
   package instead of deleting it. Absent provenance keeps today's default.
2. **Promotion gate.** New `PtcRunner.Kernel.CandidatePromotion` implementing
   G1–G4 over an acquired effective package, returning a closed
   `pass | fail | blocked` report. No filesystem writes.
3. **Materialization task.** `mix ptc.materialize` — argument handling, both
   acquisition modes, exclusive-create publication with failure cleanup, G5 on
   final bytes, deterministic report, non-zero exit on gate failure.
4. **Documentation.** The placeholder idiom, its consumer requirement, the
   operator-asserted nature of provenance, and the promotion loop in the Kernel
   maintainer guide and running-and-debugging guide; component template;
   `docs/plans/README.md` index entry.

## Verification

- Unit coverage per criterion: an effect widening; a capability name added to
  one export while present on another (the union-comparison trap); an added
  export against an empty base; a removed export; a `:prompt` export missing a
  signature; a candidate naming an ungranted capability (must fail G1 at
  assembly, not survive to a run); a candidate that fails to compile (G2/G3
  `blocked`); an ID selected in both environments
  (`:ambiguous_override_target`).
- Publication: `--out` pointing at an existing directory fails `:eexist`, and
  an existing **empty** directory is not replaced.
- `application_content_digest` of an override-bearing application is unchanged
  by slice 1, pinning that only the package-identity deletion moved.
- Round-trip: materialize, run with the produced descriptor, assert
  `run-started` names base hash, candidate hash, environment, and projected
  provenance — and that `model_id` appears nowhere in the artifact.
- One e2e: a mission authors source, `check-source` reports the same `sha256:`
  digest the descriptor carries, the task materializes and gates it, and a
  second run executes the promoted component.
- `mix precommit` before every commit.

## Non-goals

- Making `mission_inventory` mutable or re-hashable mid-run.
- Letting a manifest or a generated program name an override.
- Automatic promotion, and any claim that provenance is attested rather than
  asserted.
- Creating genuinely new component IDs from generated source (D1).
- A general result-artifact extraction language. `--from-result` resolves one
  RFC 6901 pointer to one string.
