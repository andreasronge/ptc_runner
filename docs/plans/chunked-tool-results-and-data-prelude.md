# Paginated Reads and Data Prelude — Plan

**Status (2026-06-14): partially implemented / still relevant.** The first
core blocker is shipped: in-eval tool-call ledger compaction landed in
`209b4bdf`, with large paged-result coverage in `bd7dba65`. A concrete
large-file MCP smoke path also exists through
`examples/large_file_log_introspection/` and e2e tests. That smoke path is a
backend-specific adapter for one third-party MCP server, not a core dependency.
What remains is the general `data/` prelude, page-source conventions as a
reusable API, M2 A/B measurement, and a rooted/chunk-capable file source
suitable for benchmark integrity.

## Context

The planted-anomaly pilot (`~/ptc-bench-comparison/notes/planted-pilot-results-2026-06-13.md`)
showed a real boundary in the PTC medium: agents analyze small-to-medium
tabular/log data competitively with full file/Python access, but table-scale
input handling is awkward under the sandbox budget. Agents hand-rolled chunking
every session, or avoided it and crashed.

A scale probe showed why, and a codex review of an earlier draft of this plan
killed the design we first reached for:

- A 540 KB JSONL file parses to ~1.6 MB of maps; eager `json/parse-lines` of the
  whole content blows the 10 MB sandbox max_heap. **You cannot read a large
  result whole.**
- The first design tried to hold a raw result *off-budget* and slice it later.
  **That is false against the code:** the sandbox arms
  `max_heap_size` with `include_shared_binaries: true`
  (`lib/ptc_runner/sandbox.ex:181`), so binaries acquired *during* eval are
  billed to the eval; the rebaseline only exempts data present *before* eval
  starts (`:204`). The probe that looked cheap had granted the content via
  `memory:` — the pre-eval baseline path. A mid-eval tool result is billed,
  binary bytes included. Plus the transport already decodes and caps responses
  at 2 MiB (`lib/ptc_runner/upstream/runtime.ex:14`), and the evaluator records
  every tool result in `eval_ctx.tool_calls` — so hiding it from the return
  value is not enough.

Therefore pagination is a **tool concern**: read a large source through a
paginated upstream tool, and fold over the pages in PTC-Lisp. Page position is
ordinary program data: an offset, chunk index, or continuation token passed in
the next `tool/call`.

The matching retention bug on the fold side was caught before implementation:
`(tool/call ...)` stores the **full result value** of every call in the in-eval tool ledger
(`tool_call = %{..., result: result}`, `lib/ptc_runner/lisp/eval.ex:1216`,
appended to `eval_ctx.tool_calls`). So a fold "discards" a page from its
variables but the ledger keeps it — N pages become O(total bytes) of live eval
state, billed to max_heap. Paging does not bound memory until the ledger stops
retaining full values. That core change is now shipped; everything else in this
plan is pure tool-arg threading plus Prelude V1 library code.

This is the M2 candidate for
[`turn-log-and-prelude-derivation.md`](turn-log-and-prelude-derivation.md):
a human-written prelude should pay for itself before P4 derivation starts.

## Shipped core change: bound the in-eval tool ledger

The in-eval `eval_ctx.tool_calls` ledger used to retain every call's full
result value (`eval.ex:1216`) and is only compacted *after* the eval (for the response
envelope). Fatal for a page fold: each page stays live in the ledger. The
change, now shipped in `209b4bdf`: **compact the ledger as it grows** — past
a per-eval bytes/entries cap,
keep each call's metadata (name, args hash, outcome, duration) and a bounded
preview, and drop the full result value **and large `:args`**. The program holds
the value as the `tool/call` return, so the ledger never needed it.

Verified safe (codex round 3): no in-eval code re-reads the full result value
from the ledger — the result is returned directly from the call path
(`eval.ex:1264`); the ledger is side-effect state appended at `context.ex:326`.
`ToolExecutionError` carries `eval_ctx` but only to build `step.tool_calls`
(metadata/error/preview survive); `*1` and turn history read result values, not
the ledger. So compaction is correctness-neutral.

Two retention paths this does **not** cover, and must be preserved or scoped,
not blanket-dropped:

- **`tool_cache`** stores full results separately (`eval.ex:1155/1255`). The
  synthetic upstream `"call"` is **not** cache-enabled, so the page fold is
  safe, but this is why the change fixes the *paged-fold* case, not "any
  tool-heavy eval." Cache-enabled local tools are out of scope here.
- **`child_step`** (SubAgent nested traces, `eval.ex:1236`) is another in-eval
  retention path. The compaction must **preserve `child_trace_id`/`child_step`
  metadata** (needed for the trace hierarchy) while dropping bulk result bytes.

This is a **public `Step.tool_calls` contract change**: `call.result` may now be
a bounded preview, not the full value. The matching tests and envelope
expectations were updated with the shipped change. Byte accounting must remain
real (e.g. `:erlang.external_size/1` over result + args + previews + list
overhead), not "bounded in name only."

## Core design: paginate at the tool, fold in Lisp

The rule, forced by the probe and the review: **never read a large result
whole — read it a page at a time through a paginated tool.**

1. A large source is exposed by an upstream tool that returns one bounded
   **page** per call (e.g. `read_lines` with `:offset`/`:limit`, or any tool
   that returns a page plus a continuation).
2. The program (via the `data/` prelude) folds over pages: call the tool, parse
   the page's rows into the program budget, reduce into a bounded accumulator,
   discard the page, advance to the next page, repeat.
3. The whole parsed population never exists. Each page's result is small —
   well under the 2 MiB transport cap and well under max_heap when parsed.

The page position is ordinary program state the fold carries: the next offset,
chunk index, or continuation token from the previous page. Each page is a
normal upstream tool call.

A program that ignores this and reads the whole source fails closed at max_heap
(demonstrated) — and that fail-closed teaches the model to use the paginated
tool (see "Teaching signal").

### What ptc_runner provides vs relies on

- **Relies on:** the source being reachable through a **paginated tool**. Many
  already are — paginated HTTP/OpenAPI endpoints, databases, APIs with
  `limit`/`offset` or cursor tokens.
- **Adds one core change:** the in-eval tool-ledger bound above (without it
  paging does not bound memory).
- **Provides:** the `data/` prelude (fold + analyses) that turns "a paginated
  tool" into "stream this table," plus the page-sizing and bounds story below.

The one gap for the M2 benchmark: the default filesystem MCP server
(`@modelcontextprotocol/server-filesystem`) has only `head`/`tail`, **no
offset** — it cannot forward-page. So M2 needs **one** chunk-capable line-read
tool that returns a bounded page per call (offset/limit, or a chunk-index +
lines-per-chunk equivalent). `@willianpinho/large-file-mcp` provides this
shape through its own `read_large_file_chunk` schema (`filePath`, `chunkIndex`,
`linesPerChunk`) plus file search/navigation helpers. The repo now has an e2e
smoke path using that server for turn-log introspection, confirming the
paginated-read + Lisp-fold design works end to end. It is a bounded upstream
tool, not host infrastructure, and authority stays behind the normal tool
grant. Core code should depend on the generic page-source shape, not this
server's exact MCP API.

**Hard integrity requirement: the read tool must be rooted to the corpus.**
`large-file-mcp` takes absolute paths and the probe read outside the corpus,
which would let an agent read the manifests/scorer by path and defeat the A/B.
The chosen tool must confine reads to the corpus directory (like
`server-filesystem`'s allowed-dir), or be wrapped/sandboxed to it.

## Relationship to P3b large-file `log/` backend

[`turn-log-and-prelude-derivation.md`](turn-log-and-prelude-derivation.md)'s
P3b is the narrow proving lane for this architecture. It keeps the existing
semantic `log/` API and swaps only the backend: instead of the host-bound
`TraceLog.Introspection.tools/1` backend, a backend-specific example prelude
reads turn-log JSONL pages through `@willianpinho/large-file-mcp` and projects
`log/sessions`, `log/programs`, and `log/tool-calls` in PTC-Lisp.

This plan is the generalization: a reusable `data/` prelude over paginated
sources. There is no conflict. P3b should avoid growing one-off paging helpers
that cannot later be factored into the `data/` source-spec/fold conventions.

## Non-Goals

- No capture of full tool results off-budget (the sandbox bills them anyway).
- No change to ordinary `(tool/call ...)` *call* semantics or the 2 MiB
  transport cap. (The one core change is to ledger *retention*, not call
  behavior — results still return to the program unchanged.)
- No host-side analytics engine (analysis stays in PTC-Lisp).
- No new authority-bearing builtin (the paginated tool is a normal grant).

## Pagination conventions (program-level)

The `data/` prelude folds over a **source spec** that describes how to page a
given tool. Two conventions, both threaded at the program level:

- **Offset/limit** (V1 primary): next offset = offset + rows returned; `:done`
  when a short/empty page comes back.
- **Continuation token:** the next call passes the token the previous page
  returned; `:done` when the token is absent.

The page-position args (`offset`/`limit`, or the token) go inside `:args` —
`(tool/call ...)` accepts only `:server`, `:tool`, and `:args`, and **raises on
unknown top-level keys** (`lib/ptc_runner/upstream/call_tool.ex:44`), so a
top-level page key is a hard error, not silently dropped. The `:page` block is
prelude-side metadata describing *how* to fill `:args` and read the result; it
is never passed to `tool/call`.

```clojure
;; offset/limit source — page position lives in :args
{:server "files" :tool "read_lines" :args {:path "trips.jsonl"}
 :page {:mode :offset :limit 1000
        :offset-arg :offset :limit-arg :limit   ; which :args keys carry position
        :rows-at [:value "lines"]}}

;; continuation-token source
{:server "api" :tool "list_events" :args {...}
 :page {:mode :token :token-arg :cursor
        :token-at [:value "next"] :rows-at [:value "items"]}}
```

`:rows-at` locates the page's rows inside the (usually wrapped) result; the
prelude writes the next offset/token into `:args` under the named keys before
each call.

## Page size — the central tuning knob

Each page is a real upstream call, so page size trades two limits against each
other:

- **Too small** → many calls. Two ceilings, and the timeout is the tighter one:
  the per-eval upstream-call cap (default 50, the upstream `RunContext` cap at
  `lib/ptc_runner/upstream/run_context.ex:59`), **and** the 1 s sandbox timeout,
  which is an absolute parent-side deadline that **counts time blocked on each
  upstream round-trip** (`lib/ptc_runner/sandbox.ex:220`). So the real bound is
  `pages × per-call-latency < 1 s`. For local stdio tools that may allow a few
  dozen pages; for remote tools, far fewer. 25–50 round-trips in one eval is
  **unproven and must be measured** — do not assume it.
- **Too large** → a page's parsed rows blow max_heap (the whole-read failure in
  miniature).

So pages must be **byte/row-bounded to fit max_heap when parsed**, and **large
enough to keep call-count under the cap and round-trips under the timeout**. A
JSONL page of ~1–2K lines parses to ~1 MB (well under 10 MB max_heap), and keeps
a 3 K-row file to 2–3 calls, a 50 K-row file to ~25–50. Chunked-read tools
typically return the total line count in every page (the probed one did), so the
prelude can size pages **adaptively** — `linesPerChunk ≈ ceil(totalLines / N)`
for a target page count N under the call cap, capped so a parsed page fits
max_heap — rather than a fixed default.

Pagination is N upstream round-trips per fold, bounded by the call cap and
(more tightly) the 1 s timeout. Lean to **few large pages**, not many small
ones. Fine for the benchmark sizes if a parsed page fits max_heap; this is the
scaling limit for very large sources. Mitigations if needed: raise the per-fold
call cap and/or the eval timeout for paged reads, or move a specific workload
to a specialized upstream that performs more aggregation server-side.

## Data Prelude

Reusable functions in a protected namespace (`data/`), ordinary Prelude V1
(D3): protected namespace, curated docs via `doc`/`apropos`, source hash
recorded.

**Authority note (D3), corrected against the compiler.** The `data/` helpers
build the `(tool/call ...)` map dynamically from the `source` arg, so the
prelude compiler **cannot** infer a per-upstream-tool requirement — it infers
`upstream:<server>/<tool>` only for *literal* `tool/call` maps
(`lib/ptc_runner/lisp/prelude/compiler.ex:558`), and the bridge's granted typed
tool is the generic `"call"`. So attach can only prove the dispatcher exists,
not that a specific paginated op is granted. Authority is therefore
**runtime-enforced, not attach-proven** — with a lazy-catalog caveat. `CallTool`
fails closed for unconfigured servers and for missing tools **when the catalog
is materialized** (`call_tool.ex:85`); but live MCP runtimes start with lazy
`tools: nil` (`runtime.ex:298`), and while the catalog is unmaterialized the
specific-tool check is skipped and enforcement is delegated to transport/server
rejection (`call_tool.ex:92`). So: fails closed for unconfigured servers and for
missing tools once the catalog is known; lazy MCP relies on the transport/server
rejecting an ungranted op. Do not claim attach-time proof for the generic fold.
(A per-op attach proof would require specializing each helper to a literal
upstream op or explicit `requires` metadata — deferred.)

```clojure
(data/fold-pages source init step-fn)   ; generic escape hatch
(data/field-presence source)            ; per-field present/missing counts
(data/group-count source fields)        ; count by scalar field(s)
(data/key-collisions source fields)     ; records sharing a composite key
(data/sample source n)
```

One call, one turn — the fold loops the paginated tool internally:

```clojure
(defn data/fold-pages [source init step]
  (loop [pos (page-start source) acc init]
    (let [page (tool/call (page-call source pos))     ; one upstream call
          rows (get-in page (:rows-at source))
          acc2 (reduce step acc rows)                  ; parse+reduce this page
          nxt  (next-pos source page pos)]             ; offset+n, or token
      (if (page-done? source page) acc2 (recur nxt acc2)))))
```

Helper names are deliberately generic and must not name a planted finding (see
leakage note): `field-presence`, `group-count`, `key-collisions` — not
`coverage`, `duplicates`.

## Accumulator state — an orthogonal bound

Paging fixes **input materialization**; it does not bound **accumulator state**.

- **O(1)-state** (counts, sums, field presence): tiny accumulator. Solved, any
  size.
- **O(n)-state** (composite-key dedup, distinct-grouping, sort): the accumulator
  grows toward O(distinct keys) and hits max_heap mid-eval regardless of page
  size. The state is the limit, not the input — and **raising the heap does not
  fix this either**, it only moves the wall.

V1 answer: a **max-distinct-keys / max-entries cap** on count/collision helpers,
enforced in Lisp via `count` and failing closed past N. (Exact accumulator
*byte* size is **not** expressible in a Prelude V1 — there is no exposed
term-size builtin, and `json/generate-string` is only an approximate allocating
proxy. So bound by entry/key count, not bytes; if a byte-exact bound is ever
needed, add a small host `term-size` builtin.) Approximate structures
(Bloom/HLL/count-min) and host-side accumulator spill are later options, not
built here.

## Teaching signal (fail-closed, recoverable)

When a program reads a large source whole and hits max_heap, the failure must be
a clear, **recoverable** signal — "result too large; read it through a paginated
tool / `data/` helper" — not an opaque crash, so the model learns to switch
rather than thrash. The sandbox already emits a distinguishable setup-phase
error for over-large grants; this wants the analogous eval-side hint on the heap
kill.

## Safety and Bounds

Enforced **by the host** (the one core change):

- in-eval tool-ledger bound: full page values dropped past a bytes/entries cap,
  metadata + preview kept (this is what actually bounds a page fold's memory).

Enforced **in the prelude** (Lisp, via `count`), all fail-closed:

- max accumulator **entries / distinct keys** (the O(n)-state cap — bytes-exact
  is not expressible without a host term-size builtin, see above);
- max pages per fold (backstop against runaway paging / token loops);
- max output examples per summary.

Enforced **by existing limits** (fail closed automatically):

- per-eval upstream-call cap (default 50) and the 1 s timeout bound page count
  (see "Page size"); a too-large parsed page hits max_heap. The prelude's
  page-size defaults aim to keep normal files inside all three, but "a parsed
  page fits max_heap" is not *guaranteed* by the prelude (it depends on the
  upstream's page bytes and parse-expansion ratio) — it fails closed if wrong.

## Leakage note (benchmark integrity)

The prelude's vocabulary must not hand over the answer key. Names echoing a
planted defect class (`duplicates`, `coverage`) would prime an agent browsing
`apropos` toward the scored findings — finding-shaped leakage even though the
concepts are domain-blind. Mitigations (both applied): name helpers after
generic primitives (`field-presence`, `key-collisions`, `group-count`); and
extend `bench-gen/leakage_audit.py` to check prelude export names and docstrings
for planted-class vocabulary before the M2 A/B.

## Why Not Host-Side Analytics?

The host provides nothing but the normal tool path; analysis lives in PTC-Lisp.
This dogfoods the language and produces the human-written Prelude V1 artifact M2
needs. Host-side summaries are added later only when a pattern is both common and
impossible to express safely as a bounded page fold.

## Test Plan

Prelude/runtime tests (against a fake paginated tool):

- `data/fold-pages` folds across pages without holding all rows, for both
  `:offset` and `:token` conventions;
- `:done` detection: short/empty page (offset) and absent token (token);
- `data/field-presence`, `data/group-count`, `data/key-collisions` correct;
- accumulator-size and max-distinct-keys caps fail closed;
- max-pages backstop fails closed (e.g. a token loop);
- a fold over a source several× the program budget stays within max_heap (the
  probe's failing whole-read case now passes via paging);
- attach fails without the paginated `tool:<name>` grant;
- leakage audit passes on prelude names/docstrings.

Integration / M2 tests:

- planted pilot corpus served through the chunk-capable read-lines tool;
- bare PTC (must hand-roll paging) vs PTC + `data/` prelude;
- measure eval count, turns, cost, hard failures, heap/limit failures, judge
  score;
- adoption metric: whether the agent calls `data/` helpers;
- expected: same-or-better discovery quality, fewer turns/tokens, no heap-
  avoidance behavior.

## Benchmark Decision Rule (M2 value hypothesis)

> A human-written paginating data prelude reduces eval turns, tokens, and heap
> pressure on planted audit tasks without reducing finding quality, because it
> replaces the per-session paging boilerplate agents already hand-roll.

First A/B: A = PTC baseline; B = PTC + `data/` prelude, both over the
chunk-capable read-lines tool. Same model, seeds, judge; no scorer/rubric/
prelude-name leakage. Primary process metrics: eval count, turns, cost,
heap/limit failures. Guardrail: discovery score must not regress.

If B does not reduce turns/tokens or is not adopted, this M2 candidate fails and
P4 derivation must not use it as the gold standard. If B pays for itself, it
becomes the human reference artifact for P4: the derivation agent should later
rediscover the page-fold pattern from recorded runs.

## Sequencing

1. **Chunk-capable read-lines tool.** Use an existing chunked-read MCP server
   (offset/limit or chunk-index + lines-per-chunk). The e2e smoke uses
   `@willianpinho/large-file-mcp` as one backend-specific probe, but the
   benchmark source must be rooted to the corpus or wrapped/sandboxed before
   M2. Note the page envelope may be
   double-wrapped (MCP text block holding a JSON string whose field holds the
   `\n`-joined lines), so the prelude's row extraction is: unwrap →
   `json/parse-string` → take the lines field → `json/parse-lines`.
2. **Done: bound the in-eval tool ledger** (drop full result values past a
   bytes/entries cap, keep metadata + preview). This landed in `209b4bdf`, with
   large paged-result coverage in `bd7dba65`.
3. **`data/` prelude** (fold + offset/token conventions in `:args` + field-first
   helpers), tested against a fake paginated tool. Authority is runtime-enforced
   (call fails closed if the tool is not granted), not attach-proven, for the
   dynamic `source` fold.
4. **Page-size defaults** measured against max_heap **and** the 1 s timeout
   (round-trip latency × pages); confirm the benchmark's local stdio tool is
   fast enough for the needed page count, or raise the timeout/cap for paged
   reads.
5. **Teaching signal** on the whole-read heap kill (recoverable "use paged
   read").
6. **M2 A/B** on the planted harness.

## Verified against code (codex round 2) vs unproven

**Verified sound (rounds 2–3):**

- Page position is ordinary upstream/tool state threaded through `:args`.
- The in-eval ledger retains full result values (`eval.ex:1216`); **no in-eval
  code re-reads them** (result returned directly at `eval.ex:1264`; ledger is
  side-effect state at `context.ex:326`) — so the compaction is
  correctness-neutral. `ToolExecutionError`, `*1`, and turn history are
  unaffected.
- `(tool/call ...)` accepts only `:server`/`:tool`/`:args` and **raises** on
  unknown top-level keys (`call_tool.ex:44`).
- Prelude V1 can express the page-fold loop (`loop`/`recur` over `tool/call`,
  `eval.ex:323`); attach fail-closed exists.
- Upstream defaults: 50-call per-eval cap (`run_context.ex:59`), 2 MiB response
  cap (`runtime.ex:14`).
- The 1 s sandbox timeout is one parent deadline that includes time blocked on
  upstream round-trips (`sandbox.ex:260`).
- Dynamic `(tool/call (page-call ...))` is not attach-proven (literal-only
  inference, `compiler.ex:814`).

**Still unproven / remaining (resolve during implementation):**

- That a fold of the needed page count fits the 1 s timeout for the benchmark's
  local stdio tool — **measure before relying on it.**
- That a chosen page size keeps every parsed page under max_heap for the corpus
  (depends on parse-expansion ratio) — measure; it fails closed if wrong.
- That the in-eval ledger bound fully bounds the intended M2 data-prelude fold
  under realistic page sizes and stdio latency. The core mechanism is covered;
  the benchmark workload still needs measurement.
- That metadata + preview is enough for every downstream `Step.tool_calls`
  consumer outside the tests already updated. `tool_cache` and `child_step`
  retain full data via separate paths and are out of scope / preserved
  respectively.

## Explicitly deferred

- Approximate-state structures and host-side accumulator spill for O(n)
  analyses.
- Raising the per-fold upstream-call cap for very large sources (only if a real
  workload needs more pages than the cap allows).

## Open Questions

- The exact source-spec shape (`:page` conventions, `:rows-at`/`:token-at`
  addressing) — keep minimal for V1 (offset/limit + token).
- Default page size: measure against max_heap (parsed-page fit) and the 1 s
  timeout (round-trips per fold).
- Whether to expose a small `(data/fold-pages ...)` power-user path in V1 or
  ship only field-based helpers first.
- Whether the chunk-capable read-lines tool is an external MCP server or a
  ptc_runner-native upstream (external keeps authority behind the tool
  boundary; native avoids a second process).
