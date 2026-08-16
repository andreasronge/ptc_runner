# Bind inspection prelude-source records to the canonical bundle identity

Closes #1145. Disposable plan — delete before the final PR.

## Problem

`prelude-source` records are the only private inspection record type whose
content is bound to nothing canonical.

- `valid_shape?/2` (`inspection_artifact.ex:572-587`) proves only
  self-consistency: `source_hash == sha256(source)`. A forger computes that.
- `validate_record_correlation/5` (`inspection_artifact.ex:888-903`) accepts a
  record when its `component_id` is a member of the canonical projection's id
  set. Nothing about content.
- For contrast, `evaluation-source` (`:832-849`) binds
  `{source_hash, source_bytes}` to the canonical `evaluation-started` event.

So a fabricated artifact can present arbitrary source as the prelude that
actually executed, and `InspectionQuery` stamps it with the `sha256:` prefix
that `--component-override-descriptor` consumes as `base_source_hash`.

The same validation runs on the read paths (`trace_snapshot.ex:269`,
`viewer_adapter.ex:43`, `inspection_snapshot.ex:319`), so an artifact that
reads as fully validated is partly unvalidated. `InspectionArtifact.load/1`
alone does shape and join validation only — it is not canonical validation.

### Scope of the damage

Evidence integrity, not candidate-byte injection. `ComponentOverride.apply/2`
(`component_override.ex:260`) re-hashes `installed.source` and rejects a forged
`base_source_hash` before compilation, and candidate bytes come from the
descriptor-confined path with their own hash check. A forged record misleads an
operator or a model reading `inspection/effective-preludes`; it does not reach
the compiler.

## Approach

The issue proposes adding per-component hashes to the canonical projection
first. That is not required. `FrozenBundle`'s hash is already a pure function
of `(component_id, sorted-unique dependencies, source_hash)` per component
(`bundle_compiler.ex:382-408`), and the canonical projection already publishes
`component_ids`, `dependency_indices`, and `hash`. The artifact already carries
a per-component `source_hash` that `valid_shape?/2` ties to the actual bytes,
computed identically as bare lowercase hex in both places
(`bundle_compiler.ex:379` vs `run_builder.ex:977`).

So the validator can recompute the bundle identity from canonical structure
plus artifact source hashes and require it to equal the canonical hash.

Tradeoff versus per-component hashes: this keeps the canonical payload the same
size but couples the validator to the `ptc.frozen-bundle.v2` algorithm. Per-
component hashes would be simpler to validate but grow every `run-started`
payload — which is measured against `limits.event_payload_bytes`
(`run_config.ex:345-350`) and against the query result ceiling on the read path
— and would still need the same set-completeness check. Neither is stronger;
this one is cheaper and additionally ties the dependency edges to the committed
identity.

### Precondition: capture is complete and fail-closed

`capture_bundle_sources/5` (`run_builder.ex:954-971`) emits exactly one record
per id in `bundle.component_ids`, and a rejected record aborts the run. The
inspection sink has no drop path — oversized records are rejected at emit
(`inspection_sink.ex:280`). A nil bundle projects to an empty id set and emits
nothing. So set equality holds for genuinely produced artifacts.

Component overrides do not break this: `ComponentOverride.apply/2` runs at
`application_package.ex:364`, the bundle compiles from
`package.workflow_components` (`run_builder.ex:552`), and capture reads that
same post-override list (`run_builder.ex:675`, `:921`). The two lists cannot
drift. This is the one path where the fix could silently fail on real runs, so
it gets its own test.

### Blocker: the canonical projection is not producer-grade at load

`TraceLog.valid_workflow_prelude?/1` (`trace_log.ex:2490-2510`) checks only that
`component_ids` is a list of strings, `hash` is nil-or-string, and each index is
a non-negative integer. It permits duplicate ids, absent `dependency_indices`,
a dependency list whose length does not match `component_ids`, duplicate /
unsorted / forward / out-of-range indices, and an arbitrary hash string.

Worse, `validate_current_event_data("run-started", data)` (`:2454-2466`) applies
it only to `data["workflow_prelude"]`. `data["missions"]` is checked for
`is_map` and nothing else, so every mission prelude projection is entirely
unvalidated today.

Reconstruction against unvalidated structure would either mis-reconstruct or
reject artifacts for accidental reasons. Tightening the loader comes first.

`docs/trace-log-contract.md:333-339` already describes the strict contract, so
this closes a doc/impl gap rather than inventing a rule.

## Steps

Ordered. Steps 1-2 are prerequisites, not cleanup.

1. **Tighten the canonical projection contract** — `trace_log.ex`,
   `:malformed_source`. Require unique component ids; `dependency_indices`
   present and exactly aligned with `component_ids`; each index list unique,
   ascending, every index strictly less than its own position; `hash` nil iff
   `component_ids` is empty, otherwise bare lowercase 64-hex. Apply the same
   validation to each mission's `prelude`. Update
   `docs/trace-log-contract.md`.

2. **Extract the framing to one owner.** Move `bundle_hash_bytes/1` and
   `bundle_component_record/1` from `BundleCompiler` into `FrozenBundle`, whose
   moduledoc already owns the `ptc.frozen-bundle.v2` contract. `BundleCompiler`
   calls it. No cycle: `FrozenBundle` aliases only `Attestation`. Do not copy
   the framing or the JSON helper into `InspectionArtifact` — the duplication
   gate blocks that, and a second implementation could drift from the compiler.

3. **Replace the union reducer** (`inspection_artifact.ex:672-677`,
   `:1000-1022`). Require exactly one `run-started` among the identity-filtered
   events and take its projection whole, keyed by `{environment, mission_name}`.
   Reuse the same strict projection for `evaluation-analysis.prelude_calls`.

4. **Bind the records.** Per `{environment, mission_name}` group: require exact
   component-id set equality with the canonical projection; resolve dependency
   indices to ids; recompute the identity through the shared `FrozenBundle`
   function using each record's `source_hash`; require equality with the
   canonical `hash`. Error stays `:inspection_correlation_missing` — a new atom
   would widen the public oracle without helping callers.

5. **Documentation.** Update the `InspectionArtifact` moduledoc to state that
   prelude source is bound to the canonical bundle identity, and the trace
   contract for step 1.

## Tests

Failing first, in `test/ptc_runner/kernel/inspection_sink_test.exs` (which owns
the correlation cases), with fixtures from
`test/support/private_inspection_fixture.ex`:

- forged source for one component of a real compiled two-component bundle with
  one dependency edge, complete record set — currently `:ok`, must become
  `{:error, :inspection_correlation_missing}`;
- record set missing one canonical component id;
- record set with an id not in the canonical projection (must keep failing);
- an override run: descriptor applied, artifact still validates;
- malformed projection rejected at trace load (`:malformed_source`) — aligned
  length, ordering, range, and hash format, workflow and mission alike;
- a second `run-started` rejected rather than unioned.

## Fallout

- Schema stays V6. The record envelope and payload vocabulary do not change;
  this is correlation hardening.
- Producer-generated V6 artifacts stay valid. Previously accepted incomplete,
  synthetic, or hand-built V6 artifacts will now reject — acceptable for a 0.x
  library, and the point of the change.
- Synthetic fixtures with placeholder hashes or malformed projections break.
  `private_inspection_fixture.ex:169-172` is one: `component_ids` of length 1
  with `dependency_indices: []` and `hash: "prelude-hash"`.
- Future bundle-hash changes stay safe only while the validator and compiler
  share the one versioned identity function — hence step 2.

## Gates

`mix precommit` (duplication and compile-cycle gates both matter here), and
`mix ptc.gen_docs` if the contract edit trips the generated-artifact check.
Up to three `codex review` rounds before the PR.
