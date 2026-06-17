# Prelude Evolution and Versioning — Plan

**Status:** implementation in progress. E1–E5 and in-memory E6a
default/history controls are implemented; durable persistence remains deferred.
This is the implementation-facing plan. Detailed rationale and review history live in
[`live-prelude-evolution-review.md`](live-prelude-evolution-review.md).

Companion docs:
[`turn-log-and-prelude-derivation.md`](turn-log-and-prelude-derivation.md),
[`prelude-source-discovery.md`](prelude-source-discovery.md), and
[`capability-prelude-discovery.md`](capability-prelude-discovery.md).

## Goal

Make trace-driven prelude improvement possible without restarting the MCP
server or hand-editing files for every A/B attempt:

```text
worker run -> turn logs -> editor run -> prelude write -> verifier run
```

The runtime may attach a newly written prelude to a **fresh** session/run. It
must not hot-patch an already-running worker's Lisp runtime or silently change
an LLM's already-seen context.

The user-facing editing workflow should be available through PTC-Lisp and
configuration, not only through Elixir modules. The host owns storage,
authority, limits, and validation; the model-facing API lives in a `prelude/`
capability prelude.

## Non-Goals

- No live self-mutation of an active worker session.
- No broad artifact store; `PreludeStore` is prelude-specific.
- No database/upstream persistence in V1.
- No first-class diff/patch primitive in V1; full namespace source writes are
  enough until usage proves otherwise.
- No prompt/discovery visibility system beyond `visibility: :private` for V1.

## Core Decisions

- **Core first.** MCP is a projection over core `Session`/SubAgent/store APIs.
- **Compile-on-write.** A write compiles immediately. Failed compile or failed
  bounds stores nothing.
- **Consumer-bound authority.** Stored preludes do not grant tools. `requires`
  are validated against the consuming run's tools/runtime at attach/eval time.
- **Store id is one namespace.** Store-managed entries are keyed by one
  namespace id such as `"log"`, `"paged"`, or `"prelude"`. A store write is
  accepted only if compiled namespaces are exactly `[id]`.
- **Every successful write is a version.** Versions are append-only.
- **Candidates and bundles are values.** Individual `%PreludeCandidate{}` values
  and frozen attach bundles are copied by value.
- **The live store is handle-backed.** The growing collection of all versions is
  not captured into tool closures. Store tools capture a small handle.
- **Composition is concatenate-then-compile.** Selected candidate sources are
  concatenated and compiled once into the single `%PtcRunner.Lisp.Prelude{}`
  artifact accepted by `Lisp.run/2`.
- **Bundle provenance is component-level.** A compiled bundle's aggregate
  source hash is not enough. Turn logs must also record the resolved
  candidates that produced it.
- **The `"prelude"` id is special.** Writes to the editor prelude never
  auto-default; promotion requires an explicit host/default-selection step.
- **Store ids are restricted.** A store id must be a valid prelude namespace id,
  must not contain `@`, and must not collide with protected, built-in, or
  curated namespaces.
- **Private backing tools reserve their names.** `prelude_store_*` names are
  host-reserved. Collisions with app/user tools fail closed.

## Architecture Pattern

Use the same split as `TraceLog.Introspection.tools/2` + `log/`:

```text
Elixir substrate        owns state, authority, validation, limits
host-bound tools        small closures over that substrate
capability prelude      Lisp-facing workflow API over those tools
Session/SubAgent/MCP    selects preludes and grants
```

For prelude editing:

```text
PreludeStore            source/version store
prelude_store_* tools   private host-bound backing tools
prelude/ prelude        model-facing list/source/write helpers
session start           resolves and freezes selected bundle
```

## Core Data

### PreludeCandidate

Wrap the existing compiled `%PtcRunner.Lisp.Prelude{}`. Do not invent another
compiled shape.

```elixir
%PtcRunner.PreludeCandidate{
  id: "paged",
  version: 8,
  source: "...",
  compiled: %PtcRunner.Lisp.Prelude{},
  origin: {:file, path} | {:memory, session_id} | {:upstream, ref},
  metadata: %{
    "reason" => "Add row_count and better docs",
    "parent_version" => 7,
    "parent_checksum" => "...",
    "source_session_id" => "...",
    "created_by" => "agent"
  }
}
```

`checksum` is an accessor for `compiled.source_hash`, not a separate stored
digest.

### PreludeStore

Minimal V1 API:

```elixir
PtcRunner.PreludeStore.new(opts \\ [])
PtcRunner.PreludeStore.list(store)
PtcRunner.PreludeStore.read(store, id_or_ref)
PtcRunner.PreludeStore.write(store, id, source, metadata \\ %{})
```

`list/1` is the core inventory contract. V1 returns one bounded row per prelude
id, ordered deterministically by id unless a caller projection chooses a
different presentation. It does not return source or full version history.

Each row reports the version that a bare id resolves to, plus enough summary
data for a caller or Lisp prelude to decide whether to read next:

```elixir
%{
  id: "paged",
  current_version: 8,
  latest_version: 8,
  versions_count: 8,
  checksum: "<current source_hash>",
  namespaces: ["paged"],
  exports: ["inspect", "profile"],
  origin: {:memory, session_id},
  metadata: %{},
  created_at: ~U[...],
  updated_at: ~U[...]
}
```

`current_version` is what bare-name selection resolves to. `latest_version` is
the newest successful write. They are usually equal in a scratch memory store,
but may differ later when persistent/shared stores add review policy. Full
history listing is deferred to E6 or to an evolved `prelude/` helper built on
explicit version reads.

Elixir `read/2` returns `{:ok, candidate}` / `{:error, map}`. The candidate
contains the compiled artifact and is Elixir-only. Lisp-facing tools must return
`PreludeCandidate.public_view/1`, never the compiled struct or `private_env`.

`write/4` returns one public success shape across backends:

```elixir
{:ok,
 %{
   id: "paged",
   version: 8,
   checksum: "<new source_hash>",
   namespaces: ["paged"],
   exports: ["inspect", "profile"],
   metadata: %{"reason" => "Add row_count and better docs"}
 }}
```

Error taxonomy:

- `:prelude_compile_error` — syntax/semantic errors repairable by source edits.
- `:prelude_namespace_violation` — wrong namespace id, invalid id syntax, or
  protected/built-in/curated namespace collision.
- `:stale_base` — supplied `parent_checksum` does not match the stored parent.
- bounds errors — source bytes, compile timeout, heap cap, version count, TTL.

Writes must wrap the whole compile in store-side bounds. `Compiler.compile/1`
runs parse/spec/source-index/hash work in the caller process; only prelude
constant evaluation is sandbox-bounded.

Stored source and metadata are untrusted prompt surfaces. Public views must
bound source bytes, bound metadata bytes, allow only documented metadata keys,
and preserve provenance tags. Generated comments/docstrings are not authority.

### Store Backing

Use a supervised single-owner `PreludeStore.Server` with an ETS table of
append-only version rows.

- The store server/table is owned by the derivation harness, embedding app, or
  MCP server and outlives any one session.
- A session/run receives only a small grant handle into the store.
- Writes route through the owner GenServer so append + version assignment +
  ordinary-id default flip are serialized.
- Reads may use the table directly through the store handle only if they cannot
  observe a partial append/default update. Otherwise route default reads through
  the owner.
- In-memory V1 stores may lose data on store-server crash; durable persistence is
  E6.
- `:persistent_term` is only for frozen read-only defaults, not active editing.

This avoids copying the whole version collection into the sandbox through
captured tool closures.

Compile placement is an implementation choice, but it must satisfy both
constraints:

- compiling inside the store owner must not allow one slow candidate to block
  unrelated store operations indefinitely;
- compiling outside the owner must re-check the supplied parent/version after
  compile and before append, or return `:stale_base`.

## Bundle Selection

Refs:

- `"paged"` — current default.
- `"paged@7"` — version sugar, no checksum assertion.
- `%{id: "paged", version: 7, checksum: "..."}` — canonical reproducible pin.

The `@` form is valid only because store ids reject `@`. If a future id grammar
permits `@`, version refs must become map-only.

If both version and checksum are supplied, version selects the row and checksum
verifies that row's `source_hash`; mismatch fails closed.

At session/SubAgent/MCP start:

1. Resolve selected refs through the store.
2. Reject duplicate namespace ids before concatenation.
3. Concatenate selected sources.
4. Compile once into a single `%PtcRunner.Lisp.Prelude{}`.
5. Freeze the compiled bundle for the session/run lifetime.
6. Record resolved ids, versions, checksums, and origins in turn-log provenance.

`Lisp.run/2` continues to validate `requires` against the consuming run's own
tools/runtime. Storage never discharges `requires`.

Concatenation must be deterministic: preserve explicit selection order or a
documented stable order, insert safe form separators, and hash the exact
compiled source. The bundle trace must retain both the aggregate hash and the
component refs.

## Session API

`PtcRunner.Session` becomes the embedding-friendly stateful surface for
selection.

```elixir
session =
  PtcRunner.Session.new(
    prelude_store: store,
    preludes: ["log", "paged"],
    tools: tools,
    upstream_runtime: runtime
  )

{:ok, preludes} = PtcRunner.Session.preludes(session)

{{:ok, step}, session} =
  PtcRunner.Session.eval(session, "(paged/profile ...)")
```

`prelude_store:` and `preludes:` are new options. `Session.new`/`eval` must
consume them instead of forwarding unknown options downstream.

## Private Store Tools

Editor sessions use a `prelude/` prelude over private backing tools:

```elixir
tools = %{
  "prelude_store_list" =>
    {fn _ -> ... end,
     signature: "() -> [:map]",
     expose: :ptc_lisp,
     visibility: :private},

  "prelude_store_read" =>
    {fn %{"id" => id} -> ... end,
     signature: "(id :string) -> :map",
     expose: :ptc_lisp,
     visibility: :private},

  "prelude_store_write" =>
    {fn %{"id" => id, "source" => src, "metadata" => meta} -> ... end,
     signature: "(id :string, source :string, metadata :map) -> :map",
     expose: :ptc_lisp,
     visibility: :private}
}
```

Tool wrappers must:

- project candidates through `PreludeCandidate.public_view/1`;
- normalize `{:ok, value}` / `{:error, map}` into plain Lisp-facing maps;
- catch substrate exits/raises and return `reason: :prelude_store_error` maps;
- never expose compiled artifacts or private envs;
- never persist full `source` in session tool-call history, MCP inspection
  state, or turn-log argument projections; use size-bounded summaries and
  hashes for private tool args.

Add `visibility: :private` to `%PtcRunner.Tool{}` normalization/validation.
Unknown `visibility:` values must fail closed, not be silently dropped.

Private tool semantics:

- Omit from prompt inventory and discovery.
- Reject direct user-program calls.
- Allow calls only while executing a prelude export whose compiled `tool_refs`
  include that private tool.
- Validate tool args against signature before invoking the Elixir function.
- Disable caching for private store tools unless the cache key includes an
  explicit store epoch/version. Writes are never cacheable.

This requires an evaluator origin stack. Namespace-only closure tags are not
enough. Runtime dispatch must know the current export ref and allowed tool refs.
Escaped closures must not silently retain private-tool authority when re-entered
later from user code.

## `prelude/` Prelude

The model-facing API is a normal capability prelude:

```clojure
(ns prelude
  "Read and write versioned capability preludes."
  {:visibility :prompt})

(defn list [] (tool/prelude_store_list {}))
(defn source [id] (get (tool/prelude_store_read {:id id}) "source"))
(defn write [candidate] (tool/prelude_store_write candidate))
```

Expected calls:

```clojure
(prelude/list)
(prelude/source "paged")
(prelude/source-with-deps "paged/profile")
(prelude/write
  {:id "paged"
   :source new-source
   :metadata {:reason "Add row_count and better docs"}})
```

`prelude/list` is a projection over `PreludeStore.list/1`, not the source of
truth. It may later add filtering, grouping, or history helpers without changing
the core store contract.

`source-with-deps` should be bounded. It returns one export's source, same-namespace
private helpers needed by that export, and declared `requires`/`tool_refs`. It
should consume structured compiler metadata, not parse rendered comment text.
Whole-namespace editing uses `source`; export-scoped repair uses
`source-with-deps`.

Child SubAgents must not inherit prelude editing authority implicitly.

## MCP Projection

MCP adds only:

```text
lisp_session_list_preludes
lisp_session_start(preludes: [...])
```

`lisp_session_eval` remains the execution/editing path. Existing session
lifecycle tools are unchanged.

The MCP layer owns transport concerns only: argument validation, owner checks,
envelopes, output limits, and turn-log events. It should not compile, diff,
checksum, or persist preludes itself.

## Turn-Log Provenance

Current provenance records namespaces and source hash. Extend it when the host
knows more:

```json
{
  "source_hash": "<aggregate bundle source_hash>",
  "namespaces": ["paged", "log"],
  "components": [
    {
      "id": "paged",
      "version": 7,
      "checksum": "<candidate source_hash>",
      "origin": "file:examples/paged_data_prelude/paged_data.clj"
    }
  ]
}
```

E1 only adds `origin`; `version` waits until a store assigns versions. Once
composition exists, provenance must not collapse component refs into only the
aggregate source hash.

## Phases

### E1. Manual Loop + Provenance

- Keep file edits and fresh agent runs.
- Record before/after traces and compare correctness, turns, cost, and public
  doc/source use.
- Report pass rates with intervals, not single-run anecdotes.
- Extend turn-log prelude provenance with `origin` when known.

### E1.5. Selection-Only In-Process A/B

- Add a thin selection helper over today's single-artifact `Lisp.run/2` path.
- Allow two compiled preludes to be A/B'd in process without a store.
- This proves the no-restart value before E2.

### E2. Core PreludeStore

- Add `PreludeCandidate` and `PreludeStore.list/read/write`.
- Implement handle-backed `PreludeStore.Server` + ETS rows.
- Serialize same-id writes and assign monotonic versions.
- Reject invalid ids, `@` ids, and namespace collisions with protected,
  built-in, or curated namespaces.
- Implement write bounds and error taxonomy.
- Implement explicit version/checksum reads.
- Do not implement persistent defaults, `set_default`, or `history` yet.

### E3. Session Integration

- Let `PtcRunner.Session` resolve `prelude_store:` + `preludes:` at start.
- Concatenate selected sources and compile once.
- Reject duplicate namespace ids before concatenation.
- Produce deterministic bundle hashes and component-level provenance.
- Freeze bundle for session lifetime.
- Emit active prelude provenance.
- Add strict-subset-grant fail-closed regression.

### E4a. Authority Kernel

- Add evaluator origin stack.
- Add `visibility: :private` tool normalization/validation.
- Enforce private-tool calls by current export's `tool_refs`.
- Add signature validation and recoverable diagnostics for private tool args.
- Land before any `prelude_store_*` tools are wired.

### E4b. Store Tools + `prelude/`

- Add private `prelude_store_list/read/write` tools.
- Add public projection and guarded wrapper behavior.
- Build and bootstrap the host-shipped `prelude/` prelude.
- Reserve `prelude_store_*` tool names and fail closed on collisions.
- Summarize/hash private `source` args in session/MCP/trace projections.
- Keep `"prelude"` writes non-default until explicit host promotion.

### E4c. SubAgent Integration

- Let SubAgent accept `prelude_store:` and `preludes:`.
- Consume those options before lower layers.
- Prevent implicit inheritance of edit authority into child agents.

### E5. MCP Projection

- Add `lisp_session_list_preludes`.
- Extend `lisp_session_start` with `preludes: [...]`.
- Keep MCP logic thin.

### E6. Persistent Defaults / Policy

- Add in-memory `set_default/history` after versioned writes and verifier
  sessions have proven useful.
- Add filesystem or other persistence.
- Keep default changes explicit and auditable for persistent/shared stores.

## Implementation Chunks

Do not implement the full plan as one change. Land it in small PR-sized chunks
with review gates where authority, provenance, or transport surfaces change.

1. **Selection-only bundle helper.**
   Add deterministic multi-prelude selection, concatenation, compile, duplicate
   namespace rejection, and aggregate/component provenance in core. No store, no
   private tools, no MCP changes. This validates composition before introducing
   mutable state.

2. **Core `PreludeStore`.**
   Add `PreludeCandidate`, handle-backed in-memory `PreludeStore`, `list/read/write`,
   id validation, compile-on-write, bounds, stale-base checks, and monotonic
   versions. This chunk should be reviewable without touching evaluator
   authority.

3. **Session attach integration.**
   Add `prelude_store:` and `preludes:` to `PtcRunner.Session`, resolve refs at
   start, freeze the compiled bundle, and emit component-level provenance. This
   gives fresh-session A/B with versioned preludes before editor tooling exists.

4. **Private tool authority kernel.**
   Add `visibility: :private`, hide private tools from prompt/discovery, reject
   direct user calls, add evaluator origin tracking, validate private tool args,
   and prove escaped closures do not retain private-tool authority. Run
   `codex-review` in `challenge` mode on this chunk before merging because it is
   the security boundary.

5. **Store tools and `prelude/`.**
   Add private `prelude_store_list/read/write`, source-arg summarization in
   session/MCP/trace projections, reserved-name collision checks, and the public
   `prelude/` wrapper. Run `codex-review` in `review` mode, with specific
   attention to source leakage, tool cache staleness, and public projection
   bounds.

6. **SubAgent and MCP projection.**
   Thread `prelude_store:` / `preludes:` through SubAgent and add MCP
   `lisp_session_list_preludes` plus `lisp_session_start(preludes: [...])`.
   Run `codex-review` in `review` mode if the diff touches MCP ownership,
   lifecycle, or output envelope code.

7. **Explicit defaults and history.**
   Add in-memory `set_default` and `history` first so verifier-approved
   versions can be promoted without deleting later candidates. Keep
   filesystem/upstream persistence and review policy as a separate
   design/implementation cycle.

## Integration Tests

Reuse existing scaffolding; do not build a new integration harness.

| Existing test pattern | New coverage |
| --- | --- |
| `lisp/prelude/full_path_integration_test.exs` | composed bundle compile/attach/eval/discovery |
| `lisp/prelude/tool_requires_test.exs` | private tool refs, transitive access, fail-closed grants |
| `sub_agent/runtime_prelude_test.exs` | `prelude_store:` + `preludes:` resolution and option consumption |
| `sub_agent/prelude_feedback_capture_test.exs` | `prelude/` visible, backing tools hidden |
| `trace_log/introspection_projection_test.exs` | handle-backed baseline bytes and store lifetime |
| `mcp_server/.../sessions_lifecycle_test.exs` | MCP `list_preludes` and `start(preludes: ...)` |

Fixtures to add: valid single namespace, compile error, namespace mismatch,
reserved namespace, built-in/curated namespace collision, stale parent, two
versions of same namespace, and a tool-backed editor prelude.

Critical tests:

- `write/4` success, compile failure, structural rejection, stale base, bounds.
- Invalid id syntax, `@` id, protected namespace, built-in namespace, and
  curated namespace are rejected.
- Baseline bytes stay flat as store version history grows.
- Private `prelude_store_write` does not leak full source into session tool-call
  state, MCP projections, or turn-log argument summaries.
- Direct private tool call fails; call through `prelude/write` succeeds.
- Escaped prelude closure does not retain private-tool authority.
- Original worker session stays on frozen v1 while verifier sees v2.
- Checksum-pinned mismatch fails closed.
- Concurrent same-id writes produce contiguous versions and latest default.
- A slow/failed compile cannot commit over a newer parent and cannot leave
  partially visible default state.
- Tool-name collisions with `prelude_store_*` fail closed.
- Private store tool cache staleness is impossible or explicitly epoch-keyed.
- MCP session start accepts selected preludes once core Session support lands.

## Open Questions

- Should composition ever support precedence instead of failing closed on
  duplicate namespace ids?
- How much selected-prelude discovery info should `session_start` return?
- Should `prelude/` later expose multi-edit patches?
- What policy promotes a tested version to default in persistent/shared stores?
- Should ordinary app-tool prompt/discovery visibility be generalized later?
