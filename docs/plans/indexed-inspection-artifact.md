# Indexed inspection artifact architecture

This plan records the settled implementation contract for issue #1643. It
specifies planned behavior, not the current inspection artifact contract, but
the architecture and physical format decisions below are closed. Implementation
may now proceed without another format or publication spike.

The two investigations select one sealed container and identify the logical
indexes needed by every current `InspectionQuery` operation and join. The
container can use `PublicationHandle`'s existing private staging and hard-link
publication boundary, but production needs a new staged-stream append operation
for inspection handles. No general storage backend is part of this work.

## Selected container

One run produces one append-only container:

```text
fixed header
evidence record frames
canonical index pages
bounded manifest
fixed 288-byte terminal footer
```

Evidence is written first. An evidence frame is an unsigned 64-bit big-endian
payload length followed by one canonical JSON record without a newline. The
primary index points at the JSON payload, not the frame header. The length is
bounded before conversion to the platform's range type.

Canonical JSON is compact UTF-8. Schema-defined objects use the exact field
order declared by this contract: the evidence envelope uses
`schema_version`, `run_id`, `trace_id`, `sequence`, `timestamp`, `record_type`,
`correlation`, `payload`, and every manifest object uses the order declared in
the manifest schema below. Objects nested inside evidence values that do not
have a declared schema order sort keys by UTF-8 byte value. Arrays retain
source order; duplicate keys, non-finite numbers, and insignificant whitespace
are forbidden. One encoder implements these rules for evidence and the
manifest. Decoded map enumeration order is irrelevant.

Strings escape only quotation marks, reverse solidus, and control bytes; control
escapes use the shortest named escape where JSON defines one and lowercase
`\u00xx` otherwise. Solidus and valid non-ASCII UTF-8 are not escaped. Integers
use their shortest decimal form with no leading zero. Finite binary64 values use
the shortest round-trippable decimal form defined by RFC 8785 section 3.2.2.3;
negative zero is encoded as `0`. Invalid UTF-8, lone surrogates, duplicate keys,
and non-finite values are rejected before staging.

Indexes follow the final evidence frame. Index tables are sorted, page-bounded
streams. The manifest names each table's key codec, value codec, byte range,
entry count, page size, and page ranges and SHA-256 digests. It also contains
the unredacted run and trace identities, source class, schema, collection
counts, first and last timestamps, result sequence when present, turn-evidence
summary, canonical-run digest, and the limits installed for this artifact.

The canonical-run digest is SHA-256 over the exact byte preimage:

```text
"ptc-canonical-run-v1\0"
event_count:u64
repeat event_count times in canonical sequence order:
  event_bytes:u64
  canonical_json_event:event_bytes
```

The quoted separator is the 21 ASCII bytes ending in one NUL byte. The
snapshot re-derives this digest from the paired trace before trusting
trace-derived parent, status, prelude-graph, or completeness index values. The
manifest has its own finite byte and page-count ceiling.

The fixed header is 16 bytes:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | `PTCINS01` |
| 8 | 2 | container format version, big-endian |
| 10 | 2 | inspection schema version, big-endian |
| 12 | 4 | header size, big-endian |

The fixed terminal footer is 288 bytes:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | `PTCIFTR1` |
| 8 | 2 | container format version |
| 10 | 2 | inspection schema version |
| 12 | 4 | footer size, `288` |
| 16 | 8 | total container bytes |
| 24 | 8 | evidence offset |
| 32 | 8 | evidence bytes |
| 40 | 8 | index offset |
| 48 | 8 | index bytes |
| 56 | 8 | manifest offset |
| 64 | 8 | manifest bytes |
| 72 | 8 | record count |
| 80 | 8 | canonical index-entry count |
| 88 | 32 | SHA-256 of the UTF-8 run ID |
| 120 | 32 | SHA-256 of the UTF-8 trace ID |
| 152 | 32 | evidence-region SHA-256 |
| 184 | 32 | index-region SHA-256 |
| 216 | 32 | manifest SHA-256 |
| 248 | 32 | artifact digest |
| 280 | 8 | zero, reserved |

All offsets are absolute unsigned 64-bit byte offsets. A reader rejects
overflow, overlap, gaps not assigned by the format, nonzero reserved bytes,
section order changes, a total size different from the opened file, or a
footer/header version mismatch before following any range.

The artifact digest is SHA-256 over every byte of the container with footer
bytes 248 through 279 replaced by 32 zero bytes. This convention covers the
header, evidence, indexes, manifest, all footer offsets, sizes, identities, and
component digests without a self-reference or a seek-back patch. The writer can
calculate it incrementally, hash a zero-digest footer, and append the real
footer once. The digest—not a path, inode, timestamp, object version, or open
descriptor—is the canonical artifact identity.

The inspection snapshot digest that binds cursors is SHA-256 over this exact
byte preimage:

```text
"ptc-inspection-snapshot-v1\0"
paired_trace_capture_sha256:32
pair_count:u64
repeat pair_count times, sorted by raw UTF-8 run ID bytes:
  run_id_bytes:u64
  run_id_utf8:run_id_bytes
  artifact_sha256:32
```

The quoted separator is the 27 ASCII bytes ending in one NUL byte. Both digest
fields are raw 32-byte SHA-256 values, not hexadecimal text.
`paired_trace_capture_sha256` is obtained by unpadded base64url-decoding the
exact `TraceSnapshot.info/1` `capture_id` paired with this inspection snapshot;
admission requires that value to decode to exactly 32 bytes and does not hash
or reinterpret it again. This deliberately preserves the current trace capture
identity, including its trace-source domain and sanitized/private provenance.
Those are authority semantics, not a POSIX or cloud adapter identity; the
preimage still contains no path, inode, descriptor, object key, or credential.
Run IDs are valid UTF-8 and unique within the snapshot, so the sorted framed
pairs have one canonical representation.

## Frozen physical format

All multibyte integers in the container are unsigned big-endian. All reserved
bytes and unassigned flag bits must be zero. Unless an exact field layout below
declares a narrower width, sequences, ordinals, counts, lengths, and absolute
offsets are unsigned 64-bit values. Page ordinal, entry count, and payload bytes
are the explicit `u32` exceptions. Zero is reserved for a missing optional
sequence or offset and record sequences start at one. Arithmetic is checked
before conversion to a platform range or file position.

The format-version-1 numeric registries are closed:

| Registry | ID | Meaning |
| --- | ---: | --- |
| record type | 1..13 | `capability-input`, `capability-exception`, `capability-output`, `evaluation-source`, `evaluation-analysis`, `prelude-source`, `mcp-request`, `mcp-response`, `mcp-stderr`, `execution-prints`, `execution-error`, `explicit-failure-value`, `run-result`, in that order |
| table | 1..8 | `record_by_sequence`, `capability_join`, `provider_join`, `evaluation_join`, `prelude_occurrence`, `turn_projection`, `collection_order`, `filter_posting`, in that order |
| collection | 1..9 | `turns`, `model_exchanges`, `capability_calls`, `provider_exchanges`, `generated_sources`, `effective_preludes`, `execution_prints`, `execution_errors`, `explicit_failure_values`, in that order |
| filter | 1..12 | `stream_id`, `capability_id`, `evaluation_id`, `parent_evaluation_id`, `prelude_call`, `prelude_component`, `input_sequence`, `mission_name`, `name`, `request_id`, `component_id`, `environment`, in that order |
| evaluation role | 1..5 | source, analysis, prints, error, explicit failure |
| locator kind | 1..6 | record sequence, capability-input sequence, MCP-request sequence, evaluation-source sequence, prelude-source sequence, turn ordinal |

Unknown or context-invalid IDs are malformed. Registries change only with a
new container format version; names in the manifest are diagnostic duplication
and must exactly match these registries.

`H(value)` is SHA-256 over `"ptc-inspection-value-v1\0"`, an unsigned 64-bit
payload length, a one-byte type tag (`1` UTF-8 string, `2` positive integer,
`3` nil), and the canonical payload. String payloads are raw UTF-8, integers
are unsigned 64-bit big-endian, and nil has an empty payload. A hash collision
between unequal admitted values makes sealing or admission fail closed rather
than producing duplicate index keys.

### Fixed table rows

Every table has one fixed key width and one fixed value width. Optional
sequences are zero. Hash-only identity fields are always verified against the
referenced evidence before a result is returned.

| Table | Key bytes | Value bytes |
| --- | --- | --- |
| `record_by_sequence` | `sequence:u64` (8) | `record_type:u16`, `flags:u16=0`, `reserved:u32=0`, `payload_offset:u64`, `payload_length:u64`, `payload_sha256:32` (56) |
| `capability_join` | `H(capability_id):32` | input, exception, and output sequences (`3*u64`); environment, mission-or-nil, and name hashes (`3*32`); class `u8` (`1` model, `2` ordinary); flags `u8` (bits 0 exception, 1 output); `reserved:6` (128) |
| `provider_join` | `H(capability_id):32`, `request_id:u64` (40) | request, response, and stderr sequences (`3*u64`); transport and mission-or-nil hashes (`2*32`) (88) |
| `evaluation_join` | `H(evaluation_id):32`, `role:u8`, `reserved:7` (40) | `sequence:u64` (8) |
| `prelude_occurrence` | environment, mission-or-nil, and component hashes (`3*32`) (96) | first sequence and occurrence count (`2*u64`) (16) |
| `turn_projection` | `turn_ordinal:u64` (8) | input and output sequences, stream number, turn number, generated-list absolute offset and count (`6*u64`); generated-list SHA-256; flags `u32` (bit 0 predecessor ambiguity, bit 1 generated-source ambiguity); `reserved:u32` (88) |
| `collection_order` | `collection_id:u16`, `reserved:6`, `ordinal:u64` (16) | locator kind `u8`, `reserved:7`, locator ID `u64` (16) |
| `filter_posting` | `collection_id:u16`, `filter_id:u16`, `reserved:u32`, `H(value):32`, `ordinal:u64` (48) | the same 16-byte locator layout |

The only variable-width index value is the generated-source sequence list
referenced by `turn_projection`. These lists form the **turn-list arena** at
the start of the index region. Each list is the concatenation of its associated
record sequences as `u64`, in generated-source collection order, with no header
or padding. Lists are packed in turn-ordinal order. Empty lists use offset zero,
count zero, and SHA-256 of the empty binary. A non-empty offset is absolute, must
be inside the arena, and must satisfy `(offset - arena_offset) mod 8 == 0`; the
arena itself need not be absolutely aligned because it follows variable-length
evidence. Lists are non-overlapping and exactly `count * 8` bytes. The row
digest covers those exact bytes.

Postings are unique per `(collection, filter, value, ordinal)`: multiple nested
matches within one collection item do not duplicate that item. Only the
collection/filter combinations named in the query inventory are legal.

### Canonical pages

The turn-list arena is followed immediately by table pages in table-ID and page
ordinal order. A page has a 96-byte header, `entry_count * (key_width +
value_width)` payload, and a 48-byte trailer:

| Header offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | `PTCIPG01` |
| 8 | 2 | container format version |
| 10 | 2 | table ID |
| 12 | 4 | header size, `96` |
| 16 | 4 | zero-based page ordinal |
| 20 | 4 | entry count |
| 24 | 2 | key width |
| 26 | 2 | value width |
| 28 | 4 | payload bytes |
| 32 | 32 | SHA-256 of first key, or zero for an empty page |
| 64 | 32 | SHA-256 of last key, or zero for an empty page |

| Trailer offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | `PTCIPEND` |
| 8 | 8 | total page bytes |
| 16 | 32 | payload SHA-256 |

Keys are compared as unsigned lexicographic byte strings and must be strictly
increasing across the entire table. Duplicate keys are rejected. For each
table, `page_payload_bytes` is the largest multiple of its row width no greater
than the installed `page_payload_bytes` maximum. The installed maximum is in
`160..4_294_967_295`, so every registered row fits and `payload_bytes` fits its
`u32` field. Before writing, both computed `entry_count` and `payload_bytes`
must fit `u32`. Each table has between one and `4_294_967_295` pages, the
installed aggregate `index_pages` limit is at most `4_294_967_295`, and every
zero-based page ordinal must fit `u32`. A violation is a limit failure rather
than truncation. Every non-final page contains the maximum number of whole rows
that fit; the final page contains the remainder. Empty tables have exactly one
canonical empty page. No padding or alternative page packing is allowed. The
manifest page digest is SHA-256 of the complete header, payload, and trailer.

### Manifest schema

The manifest is one canonical JSON object with exactly these top-level keys in
this order: `format`, `format_version`, `inspection_schema_version`, `run_id`,
`trace_id`, `source_class`, `evidence`, `turn_list_arena`, `tables`, `claims`,
and `limits`. `format` is `ptc-indexed-inspection`; `source_class` is
`private-inspection`.

`evidence` contains exactly `offset`, `bytes`, `record_count`, and `sha256`.
`turn_list_arena` contains exactly `offset`, `bytes`, and `sha256`. Every
manifest SHA-256 value is exactly 64 lowercase hexadecimal characters. `tables` is
an array in table-ID order. Each entry contains exactly `id`, `name`,
`key_codec`, `value_codec`, `key_bytes`, `value_bytes`, `offset`, `bytes`,
`entry_count`, `page_payload_bytes`, and `pages`. Pages are in ordinal order
and contain exactly `ordinal`, `offset`, `bytes`, `entry_count`, `first_key`,
`last_key`, and `sha256`; non-empty boundary keys use exactly two lowercase hex
characters per key byte and empty-page boundary keys are the empty string.
Codec names are exactly the table name with underscores replaced by hyphens,
followed by `-key-v1` or `-value-v1`.

`claims` contains exactly `run_counts`, `first_timestamp`, `last_timestamp`,
`result_sequence`, `turn_evidence`, and `canonical_run_sha256`, in that order.
`run_counts` preserves the current `list_runs`/`get_run` shape and contains
exactly these unsigned fields in this order: `model_exchanges`,
`incomplete_model_exchanges`, `capability_calls`, `capability_exceptions`,
`incomplete_capability_calls`, `generated_sources`, `evaluation_analyses`,
`effective_preludes`, `provider_exchanges`, `execution_prints`,
`execution_errors`, and `explicit_failure_values`. It does not add a `turns`
count. Admission reconstructs the first five fields from capability rows and
their class/exception/output flags, `evaluation_analyses` from analysis-role
evaluation rows, and the remaining fields from their canonical collection
orders. The timestamps are canonical UTC strings or nil; result sequence is a
positive integer or nil. `turn_evidence` contains exactly `complete`,
`canonical_complete`, `missing_exchange_count`, and `ambiguity_count`.

`limits` contains exactly these keys in this order: `artifact_bytes`,
`record_bytes`, `record_count`, `index_bytes`, `index_entries`, `index_pages`,
`page_payload_bytes`, `verified_range_bytes`, `writer_staging_bytes`,
`admission_staging_bytes`, `retained_manifest_bytes`, `retained_cache_bytes`,
`open_handles`, `storage_requests`, `producer_deadline_ms`, `seal_deadline_ms`,
`admission_deadline_ms`, `query_deadline_ms`, `cleanup_deadline_ms`, and
`cleanup_entries`. Every value is a positive integer no greater than the
reader's configured maximum; `page_payload_bytes` additionally obeys the
version-1 range above and `index_pages` is at most `4_294_967_295`. Policy
limits are validated, not derived from evidence. Unknown, missing, duplicate,
misordered, or incorrectly typed manifest fields are malformed.

The footer duplicates the authoritative section offsets, sizes, counts, and
component digests. Those values must exactly match the manifest and reconstructed
content. The manifest never contains the artifact digest, avoiding a second
self-reference.

## Query inventory

Index rows are scoped to one artifact, so `run_id` is not repeated in every
key. A directory snapshot retains a separately bounded catalog from run ID to
artifact digest and sealed reader. Every collection has a stable ordinal in its
documented order. Descending reads traverse the same postings in reverse.

| `InspectionQuery` operation | Current order and filters | Required source |
| --- | --- | --- |
| `list_runs` | run ID ascending; no filters | bounded snapshot run catalog plus manifest run summary |
| `get_run` | exact run ID | run catalog plus manifest run summary |
| `result` | exact run ID | manifest result sequence, then one verified record range |
| `turns` | reconstructed stream/turn order; `stream_id`, `capability_id`, `evaluation_id`, `parent_evaluation_id`, `prelude_call`, `prelude_component` | persisted turn projection plus six posting families |
| `model_exchanges` | input sequence; `capability_id`, `input_sequence` | capability join classified as workflow `llm-request`, plus two posting families |
| `capability_calls` | input sequence; `capability_id`, `mission_name`, `name` | non-model capability join plus three posting families |
| `provider_exchanges` | request sequence; `capability_id`, `mission_name`, `request_id` | provider join plus three posting families |
| `generated_sources` | record sequence; `evaluation_id`, `parent_evaluation_id`, `mission_name`, `prelude_call`, `prelude_component` | evaluation join, canonical parent edge, and five posting families |
| `effective_preludes` | record sequence; `component_id`, `environment`, `mission_name` | prelude occurrence plus three posting families |
| `execution_prints` | record sequence; `evaluation_id` | record-type order plus one posting family |
| `execution_errors` | record sequence; `evaluation_id` | record-type order, one posting family, and relationship joins |
| `explicit_failure_values` | record sequence; `evaluation_id` | record-type order plus one posting family |

The canonical index contains these logical tables:

| Table | Exact key | Value or purpose |
| --- | --- | --- |
| `record_by_sequence` | `sequence` | record type, payload offset, payload length, payload SHA-256 |
| `capability_join` | `H(capability_id)` | input sequence, optional exception and output sequences, environment, mission and name hashes, model/capability class |
| `provider_join` | `(H(capability_id), request_id)` | request, response, and optional stderr sequences plus transport and mission hash |
| `evaluation_join` | `(H(evaluation_id), role)` | sequence for source, optional analysis, prints, error, or explicit failure |
| `prelude_occurrence` | `(environment, H(mission_name-or-nil), H(component_id))` | prelude sequence and occurrence count |
| `turn_projection` | `turn_ordinal` | model input/output sequences, stream ID, turn number, associated generated-source sequences, and ambiguity flags |
| `collection_order` | `(collection_id, ordinal)` | a record, join, or turn-projection locator |
| `filter_posting` | `(collection_id, filter_id, H(value), ordinal)` | the same item locator |

`H(value)` is SHA-256 over a domain-separated, length-framed canonical value;
integers and `nil` have distinct encodings. Hashes make rows fixed-width.
Every selected row is verified against the decoded evidence or derived turn
entry before it is returned, so a collision cannot turn into a false match.
The primary row already carries record type, and `collection_order` enumerates
every queryable type, so a separate persisted record-type index would be
redundant. Temporary sealing spools may still sort by record type for
validation.

`filter_posting` has one family for every filter named in the query table. A
query with several filters performs a streaming intersection of the sorted
postings and verifies the surviving items. This avoids the 100-plus composite
indexes that all legal filter combinations would otherwise require. It also
keeps exact `omitted_count` semantics: the intersection is consumed to its end
under the query deadline and range-request limits, while only the requested
page and bounded decoder/cache state remain in memory. The cursor continues to
carry a logical result offset and binds the artifact/snapshot digest, operation,
filters, and order; index offsets are never cursor authority.

## Join inventory

The following joins are observable today and therefore cannot be replaced by
record-type scans in the new reader:

| Join | Exact key or comparison | Planned materialization |
| --- | --- | --- |
| capability input/exception/output | `capability_id`; environment, mission, and name must agree; exception precedes output; output after exception must be the synthetic non-retryable `provider_error`/`exception` result | `capability_join`; input-only and exception-only remain explicitly incomplete |
| MCP request/response/stderr | `(capability_id, request_id)`; transport and mission must agree | `provider_join`; request and response sets must be identical |
| generated source/static analysis | `evaluation_id` | `evaluation_join`; analysis remains optional |
| generated source/canonical parent | canonical trace `evaluation_id -> parent_evaluation_id` | parent value and posting on the generated item, revalidated against the paired trace snapshot |
| model exchange/canonical completeness | capability ID against expected workflow `llm-request` IDs | manifest turn-evidence counts and state |
| conversation predecessor | prior normalized `messages ++ [assistant]` is a proper prefix of the next request's normalized `messages`; longest unique predecessor wins | bounded external prefix join during sealing, then `turn_projection` |
| turn/generated source | exact tool-call `args.program` bytes equal evaluation-source bytes | source-digest external join with byte verification, then generated-source sequences in `turn_projection` |
| generated/prelude call | source and analysis share `evaluation_id`; call has `ref` and `component_id` | generated filter postings for both call fields |
| prelude occurrence | `(environment, mission_name, component_id)` | `prelude_occurrence`; counts preserve unavailable/complete/ambiguous states |
| prelude dependency | occurrence key plus the canonical trace graph for `(environment, mission_name)` | resolve lazily from `prelude_occurrence` and paired trace facts |
| error/boundary activity | error `evaluation_id` plus canonical evaluation status | resolve lazily from paired trace facts |
| error/direct producer | boundary producer evaluation IDs, canonical parent/status, and generated-source count by evaluation ID | generated postings plus paired trace facts |
| generated source/producing turn | associated evaluation ID and exact source match | `turn_projection` and turn evaluation postings |
| embedded generated relationship mirror | `(record sequence)` within the run | reuse the generated item's computed relationships when assembling a turn |
| terminal result | one `run-result`, strict JSON self-hash, successful canonical `run-stopped` hash | manifest result sequence plus paired trace validation |
| private/canonical identity validation | capability identity, evaluation identity/source, complete prelude bundle identity, and proven dropped-count allowances | sealing validation over externally sorted correlation facts |

Conversation reconstruction is the reason `turn_projection` is canonical index
material rather than a cache. Reconstructing it on the first query would retain
or rescan the full set of model requests and histories. During sealing, the
writer emits bounded temporary rows for completed-message digests, every input
prefix digest, and generated-program/source digests. External sort/merge joins
select the same longest-predecessor and ambiguity outcomes as
`ConversationProjection.compile/3`. The comparison representation preserves
its existing rule that missing, nil, empty, and whitespace-only `content` on an
assistant message with tool calls are equivalent; all other fields and values
remain exact. Canonical normalized bytes are reread on digest matches, while
raw request and response records remain unchanged for returned items.
Only the final turn rows and postings enter the artifact. Temporary sort runs
are private, quota-limited staging and are removed after seal or refusal.

Capability correlation preserves the current lifecycle in full. A capability
has one input, at most one exception, and at most one output. An exception after
an output is invalid. If an exception exists, a following output is valid only
when its result is the synthetic `%{"status" => "error", "kind" =>
"provider_error", "reason" => "exception", "retryable?" => false}` value.
Admission tests cover input-only, exception-only, successful input/output,
valid exception/error-output, duplicate, mismatched, and misordered cases.

## Streaming producer consequence

`InspectionSink` will no longer own `records` or expose `records/1`. On each
emit it will normalize, validate depth and shape, encode one canonical record,
enforce the record and artifact quotas, and append one frame directly to the
private publication handle. The append operation must return the actual start
offset from the handle owner so offset assignment and file mutation remain one
atomic owner operation.

The sink writes fixed-size correlation and posting candidates to bounded
private sort spools. Cross-record uniqueness, ordering, completeness, canonical
trace correlation, prelude bundle proof, and the two conversation joins run at
seal with a bounded sort buffer. A failure in sorting, validation, index
construction, footer creation, sync, or publication fails the run closed and
discards unpublished staging.

The production handle extension should be narrow:

```elixir
PublicationHandle.reserve_stream(path, :inspection, 0o600)
PublicationHandle.append(handle, iodata) # => {:ok, absolute_offset}
```

`reserve/3` remains the one-shot writer. Its current non-append `write/2`
seeks to byte zero for every call and therefore cannot implement streaming.
`reserve_append_for/4` already demonstrates the necessary missing-target
staging behavior, but it deliberately accepts only `:trace` and also covers
mutation of an existing trace. The inspection API must accept only a missing
destination and must never expose a partial target.

## Publication prototype result

A publication-only executable spike used the current missing-target
`reserve_append_for/4` path with a trace-kind handle as a stand-in for the
planned inspection stream. It performed separate appends for representative
header, evidence, index, manifest, and footer bytes. Those representative bytes
deliberately do not implement or validate the frozen row, page, or manifest
codecs; production codec tests own that proof. The spike validates only staged
append/publication behavior and incremental zeroed-footer hashing. After
`PublicationHandle.sync/1`, the destination was still absent. One
`PublicationHandle.publish/1` installed the complete inode, and a reader
recomputed the stored artifact digest successfully.

A second case appended and synchronized a complete terminal footer, then killed
its controller before publication. The publication owner exited normally,
removed the staging file, temporary sibling directory, and reservation, and
left no destination. A new owner then reserved the same destination, proving
that cleanup also removed the global reservation rather than only the sibling
staging path. Owner cleanup uses the same path for an earlier partial write.
Both cases passed as focused ExUnit prototypes on macOS.

This validates the single-file publication shape:

1. Reserve one collision-safe missing destination.
2. Append evidence, indexes, manifest, and the terminal footer in private
   staging.
3. Sync the complete staged inode.
4. Validate the footer and section accounting while the destination is still
   absent.
5. Hard-link the staged inode to the destination and sync its parent directory.
6. Remove the staging name and reservation without removing a committed
   destination.

Normal cancellation and owner death are already recoverable in-process.
Abrupt VM or host loss can leave only an unlinked-to-destination temporary
sibling or a complete destination that crossed the hard-link boundary; bounded
age- and count-limited orphan reaping remains implementation work.

## Independent admission

The artifact digest supplies content identity and integrity. It does not prove
that PtcRunner produced an honest artifact, and writer-side sealing is never
reader authority. Admission therefore treats evidence, stored indexes, and the
manifest as mutually untrusted inputs and uses separate staging, handle,
deadline, heap, and cleanup quotas from the writer.

Before returning a snapshot capability, admission must:

1. Stream the entire opened container, validate header/footer accounting and
   the artifact and component digests, and decode every evidence frame
   independently of stored indexes.
2. Require each evidence payload to be canonical JSON, validate its complete
   schema and per-record limits, and reproduce all current sequence, uniqueness,
   capability/provider lifecycle, result, private/canonical identity, prelude,
   and completeness checks.
3. Emit normalized validation, correlation, collection, posting, conversation,
   and manifest facts into quota-limited admission staging.
4. Externally sort those facts with the canonical codecs and reconstruct the
   turn-list arena, all eight tables and their exact canonical page packing,
   every run-summary count, result sequence, evidence-derived timestamp, and
   turn-evidence claim.
5. Compare the reconstructed arena and table bytes with the stored index
   region, including missing and extra tables, pages, rows, postings, list
   entries, and noncanonical alternative packings.
6. Recompute trace-derived claims from the paired trace snapshot and compare
   the canonical run digest, run/trace identity, parent/status/prelude graph,
   expected model exchanges, terminal result proof, and completeness fields.
7. Validate declarative format fields against the frozen registries and policy
   fields against caller-installed maxima; neither category is inferred from
   self-declared manifest values.
8. Retain only the admitted bounded manifest, page directory, paired trace
   facts, source identity, cache state, and pinned raw reader, then return the
   snapshot capability. Any earlier failure cleans admission staging and closes
   its handle.

Writer sealing may reuse the canonical JSON codec, fact codecs, external sorter,
and index builder. It may not reuse a prior writer success result as proof that
reader admission occurred. Tests construct self-consistent forged containers
with recomputed hashes but omitted/extra postings, false counts, invalid joins,
and false trace claims; all must fail admission.

## Lazy query and mutation boundary

After admission, each query reads only the exact index pages, turn-list ranges,
evidence frames, and retained manifest or trace facts that transitively
influence candidate selection, filtering, ordering, joins, counts, pagination,
and the returned page. Every file-backed range in that dependency set is
verified against the digest admitted for the artifact before its value affects
the result. Adapter-local file identity, size, mode, and change metadata are
checked before and after the batch. A digest, length, identity, or metadata
mismatch returns `source_changed`; no partial result or replacement cursor is
returned.

The pinned handle makes path replacement irrelevant. Range verification proves
that every byte influencing a query belongs to the admitted artifact. It does
not cryptographically inspect an unrelated range on every query, so corruption
outside the dependency set may remain latent until a later query reads it.
POSIX change metadata can detect more changes opportunistically but is not part
of artifact or cursor identity and is not claimed as cryptographic proof of an
unread negative. This per-query dependency verification is the selected
contract; version 1 does not copy the artifact into sealed-session backing or
rehash the entire container for every page.

## Mandatory rejection behavior

Before following a range, the reader rejects bad magic or versions, unknown
IDs, nonzero reserved fields, integer overflow, misalignment, gaps, overlaps,
out-of-order sections, a footer not at end of file, total bytes unequal to file
size, truncation, or trailing bytes. It also rejects a noncanonical evidence
frame or manifest, duplicate JSON keys, invalid UTF-8 or numbers, record-count
or digest mismatch, an index range outside the index section, malformed page
framing, wrong row widths, noncanonical page packing, duplicate or unsorted
keys, illegal collection/filter pairs, invalid locators, inconsistent page or
table counts, overlapping turn lists, unknown manifest fields, and any missing
or extra table/page/entry/claim discovered by reconstruction.

Admission failures use the existing malformed/source-limit/source-changed
taxonomy according to whether bytes were invalid initially, a configured bound
was exceeded, or the opened source changed during admission. Post-admission
dependency mismatches always return `source_changed`. Errors disclose no
private content, path, backend identifier, key, offset, digest, or credential.

## Breaking cutover implied by this plan

The implementation replaces, rather than wraps, the current whole-file path:

- `InspectionSink.records/1` and the retained `records` list disappear;
- `ArtifactPublisher` no longer receives `{:ok, records}` for inspection;
- `InspectionArtifact.persist_handle/4`, whole-file `encode`, `load`, and JSONL
  decoding are replaced by the container writer and sealed reader;
- `InspectionSnapshot` retains sealed readers and bounded metadata rather than
  `InspectionQuery.compile/3` collections;
- `InspectionQuery.compile/3` and the eager collection merge disappear;
- `ConversationProjection.compile/3` becomes the bounded sealing algorithm,
  while page presentation/compaction may remain;
- `RunAnalysisRelationships.attach/2` becomes lazy item assembly over index
  joins and paired trace facts; and
- `.inspection.jsonl` routing, Viewer fixtures, transcript assumptions, tests,
  module documentation, and references change in the same breaking cutover.

There is no legacy JSONL reader, version negotiation, converter, dual query
path, or cloud backend.

## Implementation readiness

The format authority, streaming producer, publication boundary, logical and
physical indexes, independent admission, lazy mutation semantics, rejection
rules, storage-neutral identity, and limit vocabulary are now selected. Numeric
default tuning and heap/disk measurements are implementation acceptance work,
not unresolved architecture: implementations must expose every named limit,
may initially choose conservative values, and may change them only after the
required measurements while remaining below fixed configured maxima.

Implementation proceeds as one breaking cutover. It starts with shared codecs,
fact staging/index construction, and `PublicationHandle.reserve_stream/3` plus
owner-atomic `append/2`; then replaces the producer, admission, snapshot/query,
Viewer/transcript, tests, and documentation paths. No additional architecture
spike, legacy path, or cloud-storage abstraction blocks that work.

Before the implementation PR is merged, the settled format and admission
contract moves from this disposable plan into a retained maintainer
specification and this completed plan is deleted. Production module and user
documentation must link only to the retained specification.
