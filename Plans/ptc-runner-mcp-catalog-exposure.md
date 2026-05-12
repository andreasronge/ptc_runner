# PtcRunner MCP Aggregator - Size-Aware Catalog Exposure

| Field | Value |
|---|---|
| Status | Draft |
| Date | 2026-05-12 |
| Target package | `:ptc_runner_mcp` |
| Depends on | `Plans/ptc-runner-mcp-aggregator.md` |
| Related | `Plans/aggregator-catalog-discovery.md`, `Plans/positioning-mcp-aggregator.md`, `Plans/ptc-runner-mcp-slim-responses.md` |
| Supersedes | `Plans/ptc-runner-mcp-aggregator.md` §12.5 freeze-at-boot catalog description contract |

## 1. Summary

Add size-aware upstream catalog exposure to aggregator mode.

For small upstream fleets with fully known catalogs, `ptc_lisp_execute`
keeps the current behavior: its MCP tool description includes a
complete compact summary of the configured upstream MCP tools. This
gives the calling LLM enough context to write a correct PTC-Lisp
program in one shot.

For larger fleets, or for fleets whose catalogs are not fully known at
description-render time, `ptc_lisp_execute` switches to a compact
description that names configured upstream servers and teaches
in-sandbox discovery builtins:

```clojure
(catalog/search-tools "github pull request comments" {:limit 8})
(catalog/list-tools "github")
(catalog/describe-tool "github" "get_pull_request")
```

The discovery builtins are available to PTC-Lisp programs. They are not
advertised as additional MCP tools. The MCP server still exposes one
primary execution tool, preserving the single approval surface for MCP
clients that prompt users before tool calls.

Catalog mode is resolved by configuration:

```text
--catalog-mode auto|inline|lazy
PTC_RUNNER_MCP_CATALOG_MODE=auto|inline|lazy

--catalog-inline-max-chars 12000
PTC_RUNNER_MCP_CATALOG_INLINE_MAX_CHARS=12000

--catalog-inline-max-tools 40
PTC_RUNNER_MCP_CATALOG_INLINE_MAX_TOOLS=40

--max-catalog-ops-per-program 25
PTC_RUNNER_MCP_MAX_CATALOG_OPS_PER_PROGRAM=25

--max-catalog-result-bytes 262144
PTC_RUNNER_MCP_MAX_CATALOG_RESULT_BYTES=262144
```

Default mode is `auto`.

## 2. Motivation

The aggregator currently collapses many upstream MCP tools into one MCP
tool, which is already a large improvement over exposing every upstream
operation as a native MCP tool. The remaining problem is the
`ptc_lisp_execute` description: if every upstream tool description is
inlined, the description grows linearly with the upstream fleet.

Inlining is still the best behavior for small fleets:

- no extra discovery step for the generated program;
- lower wall-clock latency;
- fewer chances for the LLM to forget discovery;
- better first-shot success when there are only a few upstream tools.

Lazy discovery is better once the inline description becomes too large:

- lower `tools/list` token cost;
- less noisy tool descriptions;
- exact schemas can be loaded only when needed;
- the calling LLM can search and inspect the catalog from inside the
  same PTC-Lisp program.

The right default is therefore size-aware, not a permanent switch to
lazy discovery.

## 3. Goals

1. Keep current inline behavior for small aggregator configurations.
2. Switch to lazy discovery automatically when the rendered description
   exceeds configured size thresholds.
3. Generate the MCP tool description deterministically from config and
   cached upstream catalogs, without LLM summarization.
4. Expose catalog discovery as PTC-Lisp builtins, not as additional MCP
   tools.
5. Keep discovery deterministic. Initial search uses lexical scoring,
   not embeddings or semantic retrieval.
6. Bound catalog discovery work per program so generated code cannot
   spend unbounded time dumping large catalogs.
7. Preserve low-latency startup by not requiring prewarming for lazy
   mode.

## 4. Non-Goals

- No semantic/vector retrieval in v1.
- No server-side LLM call to summarize upstream capabilities.
- No new MCP meta-tools such as `ptc_search_tools` in v1.
- No re-exposure of upstream tools as native MCP tools.
- No replacement of the inline catalog for small fleets.
- No JSON Schema to PTC-Lisp signature generation in this spec. That is
  compatible future work.
- No guarantee that lazy mode improves latency. It is a token and
  cognitive-load optimization for larger fleets.
- No preservation of the old "catalog string rebuilt only on PtcRunner
  restart" contract. This spec replaces that contract with
  mode-specific description generation.

## 5. Mode Resolution

Catalog mode is resolved when building the `tools/list` response. The
implementation MAY cache the rendered result until upstream catalog
state changes.

This spec supersedes the previous aggregator §12.5 freeze-at-boot
description contract. The old contract rendered one catalog string at
startup, stored it in `:persistent_term`, and guaranteed that post-boot
upstream crashes or recoveries did not change the text returned by
`tools/list`. That behavior remains a valid implementation technique
only for an inline candidate snapshot. It is no longer the global
contract for aggregator descriptions.

New contract:

- inline mode may use a frozen or cached complete catalog snapshot;
- lazy mode uses a compact generated description and runtime catalog
  builtins;
- `auto` mode must not choose inline unless every configured upstream's
  catalog is known and the rendered inline candidate is under both
  thresholds;
- later `tools/list` calls may reflect newly loaded catalogs, but the
  server must remain correct for clients that cache the first
  `tools/list`.

Configuration:

| Setting | Values | Default | Meaning |
|---|---|---|---|
| `catalog_mode` | `auto`, `inline`, `lazy` | `auto` | Catalog exposure strategy. |
| `catalog_inline_max_chars` | positive integer | `12000` | Maximum rendered inline description size in `auto` mode. |
| `catalog_inline_max_tools` | positive integer | `40` | Maximum total upstream tool count in `auto` mode. |
| `max_catalog_ops_per_program` | positive integer | `25` | Maximum catalog builtin calls per `ptc_lisp_execute` invocation. |
| `max_catalog_result_bytes` | positive integer | `262144` | Maximum JSON-encoded result bytes from one catalog builtin. |

CLI flags win over environment variables. Environment variables win over
defaults.

Resolution:

1. If no upstreams are configured, catalog mode is irrelevant and the
   normal non-aggregator description is used.
2. If `catalog_mode=inline`, render the full compact upstream catalog in
   the `ptc_lisp_execute` description.
3. If `catalog_mode=lazy`, render the compact lazy description.
4. If `catalog_mode=auto`:
   - build the inline candidate description;
   - if any configured upstream catalog is unknown, use lazy;
   - count total configured upstream tools;
   - if rendered character count is greater than
     `catalog_inline_max_chars`, use lazy;
   - else if total upstream tool count is greater than
     `catalog_inline_max_tools`, use lazy;
   - otherwise use inline.

Thresholds are evaluated against the final rendered MCP tool
description, not raw upstream JSON. Character count is used instead of
token count in v1 because it is deterministic, cheap, and independent
of tokenizer choice.

An unknown catalog has unbounded possible size for `auto` mode. It must
not be treated as zero tools.

## 6. Dynamic Description Generation

The `ptc_lisp_execute` MCP tool description is not a hardcoded static
string. It is generated deterministically when `tools/list` is handled.

The generated description has three parts:

1. Static PTC-Lisp execution instructions.
2. Aggregator instructions for `(tool/mcp-call ...)`.
3. Catalog exposure section, rendered in either inline or lazy form.

No LLM is used for description generation.

### 6.1 Upstream Metadata Sources

For each configured upstream, description generation uses the following
sources in priority order:

1. Operator-provided metadata in the upstream config.
2. Cached upstream `tools/list` names, descriptions, input schemas, and
   annotations.
3. Deterministic heuristics from the upstream name and tool names.

Recommended optional upstream config fields:

```json
{
  "name": "linear",
  "description": "Linear issue tracker for product and engineering work",
  "capabilities": ["issues", "projects", "teams", "comments"]
}
```

Server name alone is not sufficient as the primary description source.
Names such as `linear`, `github`, and `filesystem` are recognizable to
many LLMs, but names such as `corp`, `internal`, `prod`, or `fs1` are
ambiguous.

### 6.1.1 Config Parsing Contract

The upstream config parser must preserve metadata fields separately from
transport implementation config.

Supported metadata fields:

| Field | Type | Meaning |
|---|---|---|
| `description` | string | Human-readable upstream summary. |
| `capabilities` | array of strings | Compact capability labels used in generated descriptions and search. |

These fields are valid for stdio and HTTP upstreams. They must not be
passed through to transport implementations as command/HTTP settings,
and they must not be logged as unknown config keys.

Internal normalized upstream entries should keep metadata near the
routing entry, for example:

```elixir
%{
  name: "linear",
  impl: PtcRunnerMcp.Upstream.Stdio,
  config: %{command: "...", args: [...]},
  metadata: %{
    description: "Linear issue tracker for product and engineering work",
    capabilities: ["issues", "projects", "teams", "comments"]
  }
}
```

### 6.2 Inline Description

Inline mode includes a complete compact upstream summary.

Shape:

```text
Configured upstream MCP servers:
- github: GitHub MCP server, 37 tools. Search/read issues, pull
  requests, repositories, files.
  Tools:
  - search_issues: Search issues and pull requests.
  - get_pull_request: Fetch one pull request by number.
  - list_pull_request_comments: List review discussion comments.
- filesystem: Filesystem MCP server, 11 tools. List/read/write files
  under configured roots.
  Tools:
  - list_directory: List files under an allowed directory.
  - read_file: Read a file under an allowed directory.
```

Tool entries SHOULD be one line each. The renderer SHOULD trim or
normalize whitespace from upstream descriptions. If an upstream tool has
no description, use only its name and argument key hints where available.

Inline mode MAY still mention catalog builtins briefly, but it MUST NOT
require them for normal use.

Inline mode requires complete known catalogs. If any upstream catalog is
unknown, `auto` must choose lazy. If an operator explicitly forces
`catalog_mode=inline` while one or more catalogs are unknown, the
description must include a visible warning for each unknown catalog and
must include the lazy discovery examples. Forced inline is an operator
override, not a guarantee that the description is complete.

### 6.3 Lazy Description

Lazy mode does not list every upstream tool. It lists configured
upstreams and instructs the model to inspect the catalog from inside the
PTC-Lisp program.

Shape:

```text
Configured upstream MCP servers:
- github: GitHub MCP server, 37 tools. Search/read issues, pull
  requests, repositories, files.
- linear: Linear issue tracker, 18 tools. Issues, projects, teams,
  comments.
- filesystem: Filesystem MCP server, 11 tools. Files under configured
  roots.

Use catalog/search-tools inside the PTC-Lisp program to find relevant
upstream tools. If search reports an unloaded server-level match, call
catalog/list-tools or catalog/describe-tool for that server to load its
catalog. Use catalog/describe-tool before calling unfamiliar tools. Then
call upstream tools with tool/mcp-call.
```

Lazy mode MUST include enough syntax for the model to write discovery
calls correctly:

```clojure
(catalog/search-tools "github pull request comments" {:limit 8})
(catalog/list-tools "github" {:limit 20})
(catalog/describe-tool "github" "get_pull_request")
(tool/mcp-call {:server "github" :tool "get_pull_request" :args {...}})
```

### 6.4 Catalog Unknown at `tools/list`

Upstreams may be lazy-started, so their exact tool catalogs may be
unknown when the first `tools/list` response is generated.

If an upstream catalog is not loaded:

- include the upstream as configured;
- show operator-provided metadata if present;
- show `catalog not loaded yet` or equivalent short wording;
- omit tool count unless known;
- keep lazy discovery instructions in the description.

Example:

```text
- github: GitHub MCP server. Catalog loads on first use.
```

Once a catalog is loaded, later `tools/list` responses MAY include the
richer generated summary. The implementation MUST NOT rely on every MCP
client re-fetching `tools/list`; lazy mode descriptions must remain
usable even when cached by the client.

## 7. PTC-Lisp Catalog Builtins

Catalog builtins are available only in aggregator mode. Calling them
without configured upstreams is a programmer fault.

Builtins are read-only and deterministic over the server's current
catalog cache and configuration.

The namespace decision is closed by this spec: catalog builtins live in
the `catalog/` namespace. They are not regular `tool/*` calls.
Implementation must add explicit analyzer/runtime support for
`catalog/*`. Unknown catalog members should produce an error shaped like
the existing `budget/*`, `json/*`, and `mcp/*` namespace errors.

### 7.1 `catalog/summary`

```clojure
(catalog/summary)
```

Returns a compact map:

```clojure
{:mode "inline"
 :servers [{:name "github"
            :description "GitHub MCP server"
            :tool_count 37
            :capabilities ["issues" "pull_requests" "repositories"]}
           {:name "filesystem"
            :description "Filesystem MCP server"
            :tool_count 11
            :capabilities ["files"]}]
 :catalogs_loaded true}
```

Fields:

| Field | Meaning |
|---|---|
| `:mode` | Resolved catalog exposure mode for the current tool description. |
| `:servers` | Configured upstream summaries. |
| `:catalogs_loaded` | `true` only when all configured upstream catalogs are loaded. |

### 7.2 `catalog/list-servers`

```clojure
(catalog/list-servers)
```

Returns a list of server summaries:

```clojure
[{:name "github"
  :description "GitHub MCP server"
  :tool_count 37
  :catalog_loaded true}
 {:name "linear"
  :description "Linear issue tracker"
  :tool_count nil
  :catalog_loaded false}]
```

### 7.3 `catalog/list-tools`

```clojure
(catalog/list-tools "github")
(catalog/list-tools "github" {:limit 50})
```

Returns compact tool summaries for one server:

```clojure
[{:server "github"
  :tool "search_issues"
  :summary "Search issues and pull requests."
  :arg_keys ["query" "owner" "repo" "per_page"]
  :read_only true}
 {:server "github"
  :tool "get_pull_request"
  :summary "Fetch one pull request by number."
  :arg_keys ["owner" "repo" "pull_number"]
  :read_only true}]
```

If the server is configured but its catalog is not loaded,
`catalog/list-tools` attempts to load the catalog using the same
`ensure_started` path as `tool/mcp-call`. Failure returns `nil` and
records a catalog operation entry internally for debug/trace output.

An unknown server is a programmer fault.

Ordering is deterministic: tool name ascending after upstream-provided
tool schemas are normalized.

Options:

| Option | Default | Maximum | Invalid value |
|---|---:|---:|---|
| `:limit` | `50` | `200` | programmer fault |
| `:offset` | `0` | n/a | programmer fault |

`catalog/list-tools` returns at most `:limit` entries after skipping
`:offset` entries. This gives a minimal paging contract without adding a
separate cursor type in v1.

### 7.4 `catalog/search-tools`

```clojure
(catalog/search-tools "pull request comments")
(catalog/search-tools "pull request comments" {:limit 8})
```

Returns compact tool summaries across configured upstreams, ordered by
deterministic lexical score. It may also return server-level matches for
configured upstreams whose catalogs are not loaded.

Search indexes:

- server name;
- operator-provided upstream description and capabilities;
- tool name;
- tool description;
- input schema property names;
- MCP annotations when present.

Search is deterministic. V1 MUST NOT use embeddings or an LLM. A simple
scoring algorithm is sufficient:

1. tokenize the query, server names, tool names, descriptions, and arg
   keys;
2. score exact token matches highest;
3. score prefix and substring matches lower;
4. add small boosts for matches in server/tool names;
5. break ties by `{server, tool}` ascending.

Default `limit` is `8`. Maximum `limit` is `50`.

Options:

| Option | Default | Maximum | Invalid value |
|---|---:|---:|---|
| `:limit` | `8` | `50` | programmer fault |
| `:load` | `false` | n/a | programmer fault unless boolean |

Empty or whitespace-only query is a programmer fault.

Loading policy:

- default `:load false` searches loaded catalogs plus configured
  upstream metadata;
- when an unloaded upstream metadata match scores above zero, return a
  server-level entry instead of silently dropping it;
- `:load true` may load candidate upstream catalogs through
  `ensure_started` before scoring tools.

Server-level result shape:

```clojure
{:server "github"
 :tool nil
 :summary "GitHub MCP server. Catalog not loaded."
 :catalog_loaded false
 :next "(catalog/list-tools \"github\" {:limit 20})"}
```

Tool-level result shape remains:

```clojure
{:server "github"
 :tool "search_issues"
 :summary "Search issues and pull requests."
 :arg_keys ["query" "owner" "repo" "per_page"]
 :read_only true
 :catalog_loaded true}
```

### 7.5 `catalog/describe-tool`

```clojure
(catalog/describe-tool "github" "search_issues")
```

Returns the detailed catalog entry needed to write a correct
`tool/mcp-call`.

Shape:

```clojure
{:server "github"
 :tool "search_issues"
 :summary "Search issues and pull requests."
 :description "Search issues and pull requests in a repository."
 :input_schema {...}
 :arg_keys ["query" "owner" "repo" "per_page"]
 :annotations {:read_only true}
 :call_example "(tool/mcp-call {:server \"github\" :tool \"search_issues\" :args {:query \"is:open label:bug\"}})"
 :response_notes "Returns an MCP content envelope. Use mcp/text or mcp/json helpers according to the upstream result shape."}
```

`input_schema` is the raw JSON-compatible schema from upstream
`tools/list` when available. It is not translated to a PTC-Lisp
signature in this spec.

Unknown server or unknown tool is a programmer fault when the catalog is
loaded. If the server is configured but unavailable and no cached catalog
exists, return `nil` and record a world-fault catalog operation.

If the server is configured but its catalog is not loaded,
`catalog/describe-tool` attempts to load the catalog using the same
`ensure_started` path as `tool/mcp-call`.

## 8. Catalog Operation Budget

Catalog builtins share a per-program operation budget:

```text
max_catalog_ops_per_program = 25
```

Every call to a `catalog/*` builtin consumes one catalog operation.
Nested or repeated calls consume one operation each.

When the budget is exhausted:

- catalog builtins return `nil`;
- the reason is `catalog_cap_exhausted`;
- debug/trace profiles record the exhausted operation;
- the PTC-Lisp program may continue if it handles `nil`.

The catalog budget is distinct from the upstream call budget. Discovery
should not consume upstream call budget unless it has to start an
upstream to load its `tools/list`; even then, it consumes a catalog op,
not a `tool/mcp-call` slot.

Catalog builtins that call `ensure_started` share the same per-program
failure cache and leader/follower ensure lock as `tool/mcp-call`.
Consequences:

- concurrent `catalog/list-tools`, `catalog/describe-tool`, and
  `tool/mcp-call` operations for the same not-yet-started upstream must
  produce one `ensure_started` attempt per program;
- once an upstream startup fails in a program, later catalog and
  upstream-call operations for that upstream replay the cached failure;
- cancellation and worker exit clean up the shared per-program cache;
- the catalog op budget and upstream call budget remain separate.

The shared coordination state should be modeled as one per-program
context with separate counters:

```elixir
%{
  upstream_call_counter: ...,
  catalog_op_counter: ...,
  failure_cache: ...,
  ensure_locks: ...
}
```

The implementation may keep the current `call_counter` name internally
for compatibility, but the spec-level distinction is upstream calls vs.
catalog ops.

## 8.1 Catalog Result Size

Catalog builtins must avoid returning unbounded payloads.

Configuration:

```text
--max-catalog-result-bytes 262144
PTC_RUNNER_MCP_MAX_CATALOG_RESULT_BYTES=262144
```

This cap applies to the JSON-encoded value returned by a single catalog
builtin before it enters the PTC-Lisp program.

If a catalog result would exceed the cap:

- `catalog/list-tools` and `catalog/search-tools` should reduce the
  returned entries to the largest prefix that fits and include
  `:truncated true` only when the return shape is a map;
- if the function's return shape is a list and no prefix can fit,
  return `nil` with reason `catalog_result_too_large`;
- `catalog/describe-tool` returns `nil` with reason
  `catalog_result_too_large`.

To keep list return shapes simple in v1, `catalog/list-tools` and
`catalog/search-tools` may return a list when not truncated, and a map
when truncated:

```clojure
{:items [...]
 :truncated true
 :next_offset 50}
```

The lazy description should show only non-truncated examples.

## 9. Catalog Loading and Refresh

The implementation should treat upstream catalogs as cacheable but not
permanently static.

V1 requirements:

- At boot, configured upstream metadata is available immediately.
- Tool catalogs MAY be lazy-loaded on first `tool/mcp-call` or first
  relevant catalog builtin call.
- A successfully loaded upstream catalog is cached in the registry.
- `tools/list` description generation uses the best currently cached
  information.
- `auto` mode uses lazy until every configured catalog is known.

V1 does not require automatic refresh on upstream `tools/list_changed`,
but the cache model MUST leave room for it.

Future-compatible options:

- per-upstream TTL;
- explicit `(catalog/refresh "github")`;
- refresh on upstream MCP `notifications/tools/list_changed`;
- operator flag to prewarm all catalogs before serving `tools/list`.

This spec does not require prewarming. Prewarming can improve
description quality but makes `tools/list` latency depend on upstream
process startup and network behavior.

## 10. Error Model

Catalog builtins follow the aggregator's existing split between
programmer faults and world faults.

Programmer faults raise a PTC-Lisp runtime error:

- unknown server name when not configured;
- unknown tool name when the server catalog is loaded and proves absence;
- invalid builtin argument shape, such as non-string server name;
- catalog builtins used outside aggregator mode.

World faults return `nil`:

- configured upstream unavailable while trying to load its catalog;
- catalog operation budget exhausted;
- catalog result too large to return within `max_catalog_result_bytes`.

Debug/trace profiles SHOULD record catalog operation diagnostics in a
structured form. Slim responses do not include catalog diagnostics on
successful calls.

## 11. Telemetry and Debugging

Add debug/trace records for catalog operations:

```elixir
%{
  operation: :search_tools,
  query: "pull request comments",
  limit: 8,
  result_count: 3,
  duration_ms: 2,
  outcome: :ok
}
```

For describe/list operations:

```elixir
%{
  operation: :describe_tool,
  server: "github",
  tool: "search_issues",
  duration_ms: 1,
  outcome: :ok
}
```

Diagnostics must avoid dumping large schemas unless full payload tracing
is explicitly enabled.

## 12. Tests

Required unit tests:

- `auto` mode keeps inline when rendered description is under both
  thresholds.
- `auto` mode switches to lazy when rendered description exceeds
  `catalog_inline_max_chars`.
- `auto` mode switches to lazy when tool count exceeds
  `catalog_inline_max_tools`.
- `inline` and `lazy` operator overrides ignore thresholds.
- generated descriptions use operator metadata before heuristics.
- stdio and HTTP config parsing preserves `description` and
  `capabilities` metadata without passing them to transport config.
- generated lazy description includes valid `catalog/search-tools` and
  `catalog/describe-tool` examples.
- `catalog/*` namespace resolves in aggregator mode and unknown
  catalog members return a useful namespace error.
- `catalog/*` in non-aggregator mode is a programmer fault.
- unknown server in `catalog/list-tools` is a programmer fault.
- configured but unavailable server returns `nil` for list/describe when
  no cached catalog exists.
- `auto` mode chooses lazy when any configured upstream catalog is
  unknown.
- forced inline with unknown catalogs renders warnings and discovery
  examples.
- `catalog/search-tools` returns server-level matches for unloaded
  matching upstreams.
- `catalog/search-tools` with `:load true` loads candidate catalogs.
- `catalog/search-tools` ordering is deterministic.
- catalog op budget is enforced separately from upstream call budget.
- catalog builtins and `tool/mcp-call` share per-program ensure
  coordination and failure cache.
- invalid `:limit`, `:offset`, `:load`, and empty search query are
  programmer faults.
- catalog result byte cap truncates list/search where possible and
  returns `nil` for oversize describe results.
- debug/trace catalog operation records omit large schemas unless full
  payload tracing is enabled.

Required integration tests:

- small fake upstream fleet renders inline catalog in `tools/list`.
- large fake upstream fleet renders lazy instructions in `tools/list`.
- initially unloaded upstream fleet renders lazy instructions in
  `tools/list`.
- a PTC-Lisp program can search, describe, call an upstream tool, and
  return a compact result.
- a PTC-Lisp program can discover an initially unloaded upstream by
  search server-level match, list tools, describe a tool, then call it.
- a PTC-Lisp program can still call upstream tools directly in inline
  mode without using catalog builtins.

## 13. Benchmarking

Before choosing final defaults, measure:

- rendered description characters at 10, 30, 50, 100, and 200 tools;
- approximate token cost for the same descriptions using the tokenizer
  used by the target benchmark model, if available;
- first-shot program correctness under inline vs lazy on the same task
  suite;
- end-to-end latency under inline vs lazy;
- failure modes in lazy mode, especially forgetting discovery or using
  only search results without `describe-tool`.

Initial defaults in this spec are deliberately conservative:

```text
catalog_inline_max_chars = 12000
catalog_inline_max_tools = 40
max_catalog_ops_per_program = 25
max_catalog_result_bytes = 262144
```

The defaults SHOULD be revised if benchmarks show a better inflection
point.

## 14. Implementation Notes

Likely implementation areas:

- `PtcRunnerMcp.Tools` or equivalent description builder:
  add catalog mode resolution and dynamic description rendering.
- `PtcRunnerMcp.Upstream.Registry`:
  expose cached configured upstream summaries and loaded tool catalogs.
- `PtcRunnerMcp.AggregatorTools`:
  add catalog builtin closures to the PTC-Lisp tool registry or a
  dedicated catalog namespace, sharing the per-call context and budget.
- `PtcRunnerMcp.UpstreamCalls` or a sibling diagnostics module:
  record catalog operation diagnostics for debug/trace profiles.
- CLI/config parsing:
  add catalog mode, threshold, metadata, and result-cap settings.

The implementation should keep catalog data in ordinary immutable maps
passed into closures where possible. Do not use the process dictionary.

## 15. Open Questions

1. Should there be an explicit `catalog/refresh` in v1, or only cache
   refresh through future upstream notifications?
2. Should `catalog/search-tools :load true` load every matching server
   above zero score, or only the top N server-level candidates before
   tool-level rescoring?
3. How should response unwrap hints be represented without hardcoding
   server-specific knowledge into the core aggregator?
