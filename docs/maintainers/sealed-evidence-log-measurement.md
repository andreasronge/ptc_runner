# Sealed evidence log measurement

> **Audience:** people and coding agents deciding the #1643 production
> inspection format.

Issue #1646 asked whether a small sealed evidence log plus private
admission-owned ETS indexes can support large artifacts without persisted
secondary indexes, CubDB, or external sorting. Production inspection routing
is unchanged. This page records the executable prototype, the measured
workloads, the configuration inventory, and the recommendation for #1643.

Reproduce the tables with `mix ptc.measure_sealed_evidence` (count rungs up
to 10 000) or `mix ptc.measure_sealed_evidence --full` (128/256/512 MiB
payload ladder plus count rungs up to `--max-records`, default 1 000 000).
The 1 000 000-record rung is an experiment safety ceiling: it did not
complete under the prototype heap envelope. Focused tests never invoke the
large ladder.

## Environment

One trial, no warm-up, OTP 29 / ERTS 17.0.3, 64-bit words, 4 schedulers,
Linux. Producer, admission, and query workers used the same 256 MiB
`max_heap_size` envelope (`kill: true`, `include_shared_binaries: true`)
and a 65 536-byte I/O buffer at every payload rung. Encoded evidence-frame
size was 67 108 864 bytes (64 MiB) on every payload rung.

## Prototype

The reference implementation lives under
`PtcRunner.Research.SealedEvidenceLog`. Layout:

```text
16-byte versioned header (PTCINS01)
length-framed deterministic JSON evidence
192-byte terminal footer (PTCIFTR1) with counts, identities, offsets, digests
```

Admission is one streaming pass. ETS holds bounded metadata only. Queries
select through ETS and read required ranges from a pinned file-server
handle. Cursors bind the admission snapshot digest and the logical query
identity; they do not rehash the complete evidence preimage.

## Payload-size ladder

| Target | Frames | Artifact bytes | Frame size | Producer ms | Admission ms | ETS bytes | Logical entries | Charged retained | `list_runs` | `generated_sources` limit 1 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| 128 MiB | 2 | 134 217 936 | 67 108 864 | 2 153 | 696 | 34 152 | 14 | 34 489 | ok, 0 ms | `result_limit_exceeded` (926 ms) |
| 256 MiB | 4 | 268 435 664 | 67 108 864 | 2 679 | 1 339 | 37 048 | 26 | 37 385 | ok, 0 ms | `heap_exceeded` (757 ms) |
| 512 MiB | 8 | 536 871 120 | 67 108 864 | 4 092 | 2 680 | 42 840 | 50 | 43 177 | ok, 0 ms | `heap_exceeded` (853 ms) |

Producer process memory stayed ~21 KiB; referenced binaries peaked at one or
two in-flight 64 MiB frames (128–201 MiB), not at the complete artifact.
Admission process memory stayed ~64 KiB; referenced binaries peaked at
134 217 912 bytes on every rung. Charged retained state after admission
grew by index rows (14 → 26 → 50 entries), not by payload. Scratch after
close was 0 bytes; the sealed input artifact remained until the harness
deleted it.

`list_runs` does not read evidence payloads. Returning a 64 MiB
`generated_sources` item exceeds the 1 000 000-byte result ceiling
(2-frame rung). Verifying every omitted 64 MiB frame before computing
exact `omitted_count` exceeded the 256 MiB query envelope at 4 and 8
frames. That is a contract finding, not a measurement gap: a frame counted
only in `omitted_count` is a query dependency in the current
`InspectionQuery` rules.

## Record-count ladder

Small `execution-prints` records. Prototype `max_records` was set to the
rung. Exact one-over refusal for `max_records`, `max_index_entries`, and
`max_logical_index_bytes` succeeded on a 3-record fixture.

| Records | Artifact bytes | ETS bytes | Logical bytes | Entries | Bytes/record | Producer ms | Admission ms | Cold query ms | Exact-count work |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 000 | 273 994 | 797 672 | 805 534 | 4 002 | 798 | 20 | 44 | 14 | 990 |
| 10 000 | 2 777 996 | 7 631 208 | 8 081 547 | 40 002 | 763 | 117 | 474 | 110 | 9 990 |
| 100 000 | 28 177 998 | 76 032 112 | 81 291 560 | 400 002 | 760 | 1 193 | 3 971 | 1 216 | 99 990 |
| 1 000 000 | — | — | — | — | — | 11 514 then `heap_exceeded` | — | — | — |

Linear fit on the three completed rungs: ETS bytes ≈ `759.97 * N + 34 749`.
Do not treat the observed marginal value as a constant; intercept is the
fixed table/owner overhead. Other charged retained bytes stayed 338–340
(paired trace facts and owner metadata). Producer checkpoint memory did
not grow with record count after first/last samples replaced a per-frame
list.

The 1 000 000-record rung is the experiment safety ceiling, not a
candidate production authority. Last successful rung: 100 000. Headroom
versus today’s internal snapshot `max_retained_bytes` of 128 000 000 is
about 1.68× at 100 000 small records (76 MB charged). Query deadline 15 s
covered exact `omitted_count` at 100 000 tiny records (1.2 s, 100 010 hash
operations).

## Semantic workloads

Differential parity against `InspectionQuery.compile/3` and `query/6`
passed for all twelve operations on the mixed corpus, including filter
absence/`nil`/presence, legal conjunctions, the negative
same-generated-source turn conjunction, ascending and descending order,
multi-run `list_runs`/`get_run`/`result`, pagination, invalid cursor
reuse, unknown keys, and invalid filter types. Snapshot-hash values and
opaque cursor bytes were ignored; each implementation walked with its own
cursors.

Dense filter postings (32 generated sources, `limit` 3, `mission_name`
present): `omitted_count` 29, 32 postings visited, 32 candidate frames
verified.

## Fault matrix

| Event | Outcome |
| --- | --- |
| Trailing, truncated, or malformed bytes before open | `malformed_source`; no snapshot |
| Footer counts/identities/digest mismatch | `malformed_source`; no snapshot |
| Append, truncate, or overwrite during admission | `source_changed`; no snapshot |
| Append or truncate after admission | next query `source_changed`, including `get_run` / `result` |
| Relevant same-size overwrite | next query `source_changed` |
| Unrelated same-size overwrite | `list_runs` may succeed; the dependent collection returns `source_changed` |
| Path replacement after admission | queries continue against the pinned handle |
| Admission caller death | admission worker cancelled; no snapshot |
| Quota / retained-ceiling refusal | no snapshot; tables deleted; input artifact remains |
| Snapshot owner death | ETS tables undefined; handles unusable |
| Normal close | tables deleted; handles unusable |
| Query caller death | query worker cancelled; snapshot remains usable |

## Configuration inventory

Class `host_facing` is the public JSON/API path under a
`ptc_inspection_snapshot` installation. Everything else is internal.

| Path or “internal only” | Class | Phase | Unit | Compiled / installed / hard max | File meaning | Consumer |
| --- | --- | --- | --- | ---: | --- | --- |
| `install.ptc_inspection_snapshot.ceilings.max_files` | host_facing | admission | files | 1 024 / 1 024 / 1 024 | directory | `HostConfig` inspection snapshot ceilings |
| `install.ptc_inspection_snapshot.ceilings.max_source_bytes` | host_facing | admission | bytes | 64 000 000 / 64 000 000 / 64 000 000 | aggregate | `HostConfig` inspection snapshot ceilings |
| `install.ptc_inspection_snapshot.ceilings.max_result_bytes` | host_facing | query | bytes | 1 048 576 / 1 048 576 / 1 048 576 | selected or directory | `HostConfig` inspection snapshot ceilings |
| internal only | snapshot_internal | admission | bytes | 128 000 000 | selected or directory | `InspectionSnapshot` `max_retained_bytes` |
| internal only | snapshot_internal | admission | files | 1 024 | directory | `InspectionSnapshot` `max_files` |
| internal only | snapshot_internal | admission | entries | 4 096 | directory | `InspectionSnapshot` `max_directory_entries` |
| internal only | snapshot_internal | admission | bytes | 16 000 000 | selected file | `InspectionSnapshot` `max_artifact_bytes` / `InspectionArtifact` |
| internal only | producer | producer | bytes | 2 000 000 | selected file | `InspectionSink` `max_record_bytes` |
| internal only | producer | producer | bytes | 16 000 000 | selected file | `InspectionSink` `max_total_bytes` |
| internal only | prototype | producer | bytes | 67 108 864 | selected file | research `max_record_bytes` |
| internal only | prototype | producer | bytes | 536 871 120 | selected file | research `max_total_bytes` |
| internal only | prototype | admission | records | 1 000 000 | selected file | research `max_records` (experiment ceiling; 1 000 000 did not complete) |
| internal only | prototype | admission | entries | 8 000 000 | selected file | research `max_index_entries` |
| internal only | prototype | admission | bytes | 536 870 912 | selected file | research `max_logical_index_bytes` |
| internal only | prototype | query | bytes | 67 108 864 | selected file | research verified range-byte ceiling |
| internal only | prototype | query | milliseconds | 15 000 / 15 000 / 15 000 | selected or directory | research query deadline |
| internal only | prototype | admission | bytes | 536 870 912 | selected or directory | research `max_retained_bytes` |
| internal only | prototype | query | bytes | 1 000 000 | selected or directory | research `max_result_bytes` |
| internal only | prototype | producer | bytes | 268 435 456 | selected file | research producer heap envelope |
| internal only | prototype | admission | bytes | 268 435 456 | selected file | research admission heap envelope |
| internal only | prototype | query | bytes | 268 435 456 | selected file | research query heap envelope |
| internal only | maintained_guard | admission | schema_version | 8 | selected file | `InspectionArtifact` / prototype schema |
| internal only | maintained_guard | query | items | 1 000 max / 100 default | selected or directory | `InspectionQuery` page limit |

`Limits.inventory/0` is the executable copy of this table.

### Mapping for #1643

- Keep host-facing `max_files`, aggregate `max_source_bytes`, and
  `max_result_bytes`. Do not add ETS table type, key layout, concurrency,
  word counts, cache, backend, sorting, or compaction knobs.
- `max_retained_bytes` stays internal and means all charged derived
  snapshot state (actual ETS allocation plus disjoint owner metadata,
  paired trace facts, and cache). Shared binaries that appear in both
  owner metadata and an ETS row are charged in both places.
- Writer authority stays on the producer/sink internals
  (`max_record_bytes`, `max_total_bytes`), not on inspection-provider
  installation ceilings.
- Add one internal admission guard `max_records`. Proposed production
  **default 16 384**, **hard maximum 65 536** (about 50 MB ETS at the
  measured ~760 B/record slope, under 128 MB `max_retained_bytes`, with
  headroom from the 100 000 successful rung). The 1 000 000 experiment
  ceiling is not a production authority.
- Production `max_record_bytes` remains 2 000 000. The prototype 64 MiB
  record size is research-only.
- Range-byte and query-deadline ceilings stay internal. 15 s covered
  exact `omitted_count` for 100 000 tiny records. Deadlines do not need to
  become host-facing for the environments measured here.
- Selected-file `max_artifact_bytes` / producer `max_total_bytes`
  (16 000 000 today) can remain the production per-artifact cap until a
  later cutover raises them; the prototype proved 512 MiB artifacts under
  a research envelope.

## `omitted_count` contract

Exact `omitted_count` that re-verifies every omitted evidence frame is
acceptable for small records (100 000 prints, 1.2 s, inside 15 s). It is
not acceptable for payload-heavy few-record artifacts: verifying four or
eight omitted 64 MiB frames exceeds a 256 MiB query envelope, and a single
returned 64 MiB item exceeds `max_result_bytes`.

#1643 should keep exact dependency verification for **returned items and
their join/turn dependencies**, and specify `omitted_count` as the ETS
locator cardinality whose admission digests were already checked. A
same-size overwrite of an omitted frame may remain latent until that
frame is selected. That is a deliberate replacement for the current
“every omitted frame is a query dependency” rule, justified by this
ladder. Do not silently weaken the prototype: it still verifies omitted
frames, and the harness records the resulting `heap_exceeded`.

## Recommendation for #1643

**ETS-only V1** is sufficient. Do not add CubDB or `:file_sorter` for this
cutover.

The simple sealed log plus private ETS indexes supports:

- payload-heavy artifacts with artifact-independent retained memory;
- record counts through 100 000 small rows under today’s 128 MB retained
  ceiling, with a finite `max_records` guard;
- the complete current query/filter surface on a mixed corpus;
- pinned-handle mutation detection and deterministic cleanup.

#1643 should restore `ready-for-implementation` on an ETS-only sealed log
with the `omitted_count` contract change above, internal `max_records`,
and the existing host-facing inspection ceilings. Persisted secondary
indexes are not required for the measured workloads.
