# MCP REPL Discovery Commands

## Problem

MCP aggregator mode currently exposes upstream discovery through bespoke
`catalog/*` PTC-Lisp forms:

```clojure
(catalog/summary)
(catalog/list-servers)
(catalog/search-tools "calendar")
(catalog/list-tools "calendar")
(catalog/describe-tool "calendar" "create_event")
```

The behavior is useful: it supports lazy upstream startup, catalog caching,
pagination, deterministic search, result-size caps, and the same
programmer-fault / world-fault split as `tool/mcp-call`.

The surface, however, feels like a custom API rather than a Clojure-flavored
REPL. Discovery should look closer to familiar REPL commands while preserving
the current MCP-specific operational semantics.

## Goal

Introduce generic PTC-Lisp REPL discovery commands with an MCP-specific first
backend:

```clojure
(mcp/servers)
(apropos "calendar")
(apropos "calendar" {:load true})
(dir 'calendar)
(doc 'calendar/create_event)
(meta 'calendar/create_event)
```

The language surface should be generic enough for standalone `ptc_runner` later:
`apropos`, `dir`, `doc`, and `meta` are REPL discovery concepts, not MCP-only
syntax. The first production backend should target MCP upstream servers and MCP
tools because that is the immediate use case.

Standalone builtin/user-var introspection can come later, but the core
representation and eval hook should not be MCP-shaped.

## Non-goals

- Do not implement full Clojure quote semantics.
- Do not support quoted lists, quoted vectors, syntax quote, unquote, or reader
  metadata.
- Do not build a full Var model before the MCP use case needs it.
- Do not delete `catalog/*` in the first implementation step.
- Do not make core `:ptc_runner` depend on `:ptc_runner_mcp`.
- Do not make every symbolic reference mean `server/tool`; discovery backends
  interpret references.

## Symbol References

PTC-Lisp currently supports `#'x`, but that evaluates as a var reference. It is
not suitable for symbolic MCP references because discovery commands need the
name itself, not the value behind the name.

Add a narrow quoted-symbol feature:

```clojure
'github
'github/search_repos
(quote github)
(quote github/search_repos)
```

Semantics:

- Quoted symbols evaluate to a first-class symbolic reference value.
- Only symbols are accepted inside `quote` for this phase.
- Quoted lists, vectors, maps, and sets remain parse/analyze errors.
- The symbolic reference preserves the original textual name, including `/`.
- This feature is intentionally small but first-class: analyzer and eval should
  have an explicit representation, not an ad hoc special case in `doc`/`dir`.

Implementation notes:

- Update the unsupported-syntax preflight that currently rejects quote syntax.
- Add quote parsing to both parser paths. `#'x` remains the existing var reader;
  `'x` is a symbolic reference.
- Quoted `server/tool` must preserve the raw textual name before ordinary
  namespace splitting turns it into `{:ns_symbol, server, tool}`.
- Add bounded vocabulary entries, or binary-name analyzer clauses, for `quote`,
  `apropos`, `dir`, `doc`, `meta`, and `mcp/servers`.
- `apropos`, `dir`, `doc`, and `meta` are shadowable local names, like
  macro-style forms. Add them explicitly to the analyzer shadowable-form set and
  cover the existing shadow-marking paths in tests.

Also accept strings as a fallback for MCP names that are not valid PTC symbols:

```clojure
(dir "github")
(doc "github/search_repos")
(meta "github/search_repos")
```

Reference parsing rules:

- Server reference: `github` or `"github"`.
- Tool reference: `github/search_repos` or `"github/search_repos"`.
- String tool references use the first `/` as the server/tool separator.
- Invalid shape is a programmer fault.

## Public Forms

### `(mcp/servers)`

Equivalent to current `(catalog/list-servers)`.

Returns a list of maps. To match current `catalog/list-servers` during the
migration, keep the existing string-keyed shape:

```clojure
{"name" "github"
 "description" "GitHub MCP server"
 "tool_count" 42
 "catalog_loaded" true}
```

This is intentionally explicit rather than overloading `(dir 'mcp)`.

### `(apropos query)` / `(apropos query opts)`

Equivalent to current `(catalog/search-tools query opts)`.

Default behavior must remain conservative:

- `{:load false}` by default.
- Search loaded catalogs plus server-level metadata for unloaded servers.
- Do not trigger upstream startup unless `{:load true}` is explicit.

Options:

```clojure
{:limit 8        ; integer 1..50, default 8
 :load false}    ; boolean, default false
```

Return compact, ranked, human-readable lines, matching the current catalog
search style at first:

```clojure
["github.search_repos(query) - Search repositories"
 "calendar: Calendar tools. Catalog not loaded. Next: (dir 'calendar)"]
```

The output is intentionally string-based in this phase. `apropos` is the
low-token candidate-finding surface for an LLM; structured result records can
come later if a concrete caller needs them.

Later, this can broaden to builtins and user vars. For the first phase, it is
MCP-only.

### `(dir server)` / `(dir server opts)`

Equivalent to current `(catalog/list-tools server opts)`.

Examples:

```clojure
(dir 'github)
(dir "github" {:limit 20 :offset 40})
```

Behavior:

- Triggers lazy startup for the requested server when needed.
- Returns compact tool signature lines sorted by tool name.
- Uses current pagination limits: `:limit` 1..200, `:offset` >= 0.
- Unknown configured server shape is a programmer fault.
- Upstream startup failure is a world fault and returns `nil`.

### `(doc tool-ref)`

Equivalent to current `(catalog/describe-tool server tool)`.

Examples:

```clojure
(doc 'github/search_repos)
(doc "github/search_repos")
```

Behavior:

- Triggers lazy startup for the referenced server when needed.
- Returns the current detailed human-readable tool description.
- Returns a string, not a map. `doc` is the primary LLM-facing "before calling"
  surface; it should include the compact signature, required args, output notes,
  and a copyable `(tool/mcp-call ...)` example. Use `meta` for structured data.
- Unknown tool on a loaded server is a programmer fault.
- Upstream startup failure is a world fault and returns `nil`.

### `(meta tool-ref)`

Returns structured MCP tool metadata.

Examples:

```clojure
(meta 'github/search_repos)
(meta "github/search_repos")
```

Initial return shape:

```clojure
{:kind "mcp-tool"
 :server "github"
 :tool "search_repos"
 :description "Search repositories"
 :input_schema {...}
 :output_schema {...}
 :annotations {...}
 :call "(tool/mcp-call {:server \"github\" :tool \"search_repos\" :args {...}})"}
```

Future `meta` should dispatch by reference type:

- MCP tool reference: MCP metadata.
- Var reference: user/builtin var metadata.
- Plain data: either `nil` or data metadata if a metadata model exists.

For this phase, `meta` is MCP-only and returns a programmer fault for unsupported
reference types.

LLM exploration should be progressive:

```clojure
(mcp/servers)
(apropos "calendar")
(dir 'calendar {:limit 20})
(doc 'calendar/create_event)
(meta 'calendar/create_event)
(tool/mcp-call {:server "calendar" :tool "create_event" :args {...}})
```

Runtime repair hints should point to the smallest useful recovery action:

- Unknown server: `(mcp/servers)` or `(apropos "query")`.
- Unknown tool on a known server: `(dir 'server)` and `(apropos "query")`.
- Bad args: `(doc 'server/tool)`, then `(meta 'server/tool)` when schema detail
  is needed.

## Backend Module

Add a generic discovery executor hook in core `ptc_runner`, and add
`PtcRunnerMcp.ReplDiscovery` as the MCP-specific backend installed by aggregator
mode.

Core eval should know only "invoke REPL discovery operation", analogous to the
current closure-captured `catalog_exec` path. It must not call
`PtcRunnerMcp.ReplDiscovery` directly.

Possible core hook names:

```elixir
:repl_discovery_exec
:discovery_exec
```

The hook accepts an operation and evaluated args, then returns:

```elixir
{:ok, value}
{:world_fault, reason}
{:programmer_fault, message}
```

When no discovery backend is installed:

- In standalone mode, generic builtin/user-var introspection may be implemented
  later through a core backend.
- Until then, unsupported discovery operations should be programmer faults with
  clear messages.

Suggested operations:

```elixir
:servers
:apropos
:dir
:doc
:meta
```

The MCP backend should own MCP domain logic and reuse/extract the lower-level
catalog behavior currently in `PtcRunnerMcp.CatalogBuiltins`:

- registry lookup
- cached tools
- lazy `Registry.ensure_started/2`
- per-program ensure locks
- shared failure cache
- catalog op budget
- search scoring
- compact line rendering
- detailed tool rendering
- result-size caps
- programmer-fault / world-fault result tuples

`CatalogBuiltins` should remain temporarily and call the same backend where
possible. This keeps old `catalog/*` tests passing while prompt cards migrate to
the new forms.

## Analyzer And Eval

Add analyzer/eval support for:

```clojure
(mcp/servers)
(apropos query)
(apropos query opts)
(dir server)
(dir server opts)
(doc tool-ref)
(meta tool-ref)
```

Lower these to generic discovery ops, similar to the current catalog-specific
core tags, but route through the injected discovery executor rather than through
an MCP module.

Use one generic CoreAST shape for every discovery form, including
`(mcp/servers)`:

```elixir
{:repl_discovery, :servers, []}
{:repl_discovery, :apropos, args}
{:repl_discovery, :dir, args}
{:repl_discovery, :doc, args}
{:repl_discovery, :meta, args}
{:symbol_ref, "github/search_repos"}
```

Exact names are not important, but the representation should avoid MCP-specific
tags in core. Quoted symbol refs should remain explicit and serializable enough
for debugging and formatting.

The symbolic reference value is generic. The MCP backend interprets
`"github/search_repos"` as a tool reference; a future standalone backend may
interpret `"map"` as a builtin var reference or `"clojure.string"` as a
namespace-like reference.

Phase 1 discovery forms are call-position-only. Do not add value-position
`RuntimeCallable` support for `apropos`, `dir`, `doc`, or `meta` in the first
implementation. This keeps higher-order discovery calls out of scope while the
executor boundary and symbol-ref representation settle. If value-position
support is added later, it should mirror the existing `catalog/*`
`RuntimeCallable` path and include pmap/HOF side-effect merge coverage.

## Error Model

Preserve the current catalog split:

- Programmer faults raise execution errors:
  - invalid arity
  - bad options
  - malformed reference
  - unknown configured server name
  - unknown tool on a loaded server
- World faults return recoverable signal values:
  - upstream unavailable
  - catalog result too large
  - catalog op cap exhausted

Default return values for world faults:

- `mcp/servers`: `nil` only if registry itself is unavailable.
- `apropos`: `[]` for no matches, `nil` for operational failure.
- `dir`: `nil` for upstream startup/catalog failure.
- `doc`: `nil` for upstream startup/catalog failure.
- `meta`: `nil` for upstream startup/catalog failure.

## Prompt Migration

Update MCP aggregator prompt cards to teach the REPL-style commands:

```clojure
(mcp/servers)
(apropos "query" {:limit 8})
(apropos "query" {:load true})
(dir 'server {:limit 20})
(doc 'server/tool)
(meta 'server/tool)
(tool/mcp-call {:server "server" :tool "tool" :args {...}})
```

Keep `catalog/*` unadvertised once the new forms are implemented and tested.
Also update runtime repair hints emitted by `tool/mcp-call` validation errors so
unknown server/tool and bad-args messages point to `mcp/servers`, `apropos`,
`dir`, and `doc` instead of `catalog/*`.

## Implementation Order

1. Add a generic core discovery executor hook and tracing records, initially
   paralleling the current `catalog_exec` path. Thread the hook through
   `Lisp.run` opts, `Eval.Context`, MCP sandbox eval paths, session eval paths,
   and step/trace payload fields that currently carry catalog operation records.
   If later adding value-position runtime-callable discovery, also update the
   pmap/HOF side-effect merge paths.
2. Add quoted-symbol parsing/analyze/eval for symbol references only.
3. Add `apropos`, `dir`, `doc`, and `meta` to the analyzer shadowable-form set
   and test that local bindings shadow those REPL forms.
4. Add `PtcRunnerMcp.ReplDiscovery` with `servers`, `apropos`, `dir`, `doc`,
   and `meta`.
5. Refactor `CatalogBuiltins` to call shared discovery backend behavior where
   practical.
6. Add analyzer/eval forms that lower to generic discovery ops.
7. Add focused unit tests for symbol refs, string fallback refs, lazy startup,
   option validation, and error classification.
8. Update MCP prompt cards, runtime hints, and prompt tests.
9. Stop advertising `catalog/*`.
10. Delete public `catalog/*` forms in a later cleanup once downstream tests and
   docs no longer rely on them.

## Test Coverage

Add tests for:

- `'server` parses and evaluates to a symbolic reference.
- `'server/tool` parses and evaluates to a symbolic reference.
- `(quote server/tool)` works.
- `(quote (a b))` is rejected.
- `(dir 'server)` and `(dir "server")` produce the same result.
- `(doc 'server/tool)` and `(doc "server/tool")` produce the same result.
- `(meta 'server/tool)` returns structured schema/description/call metadata.
- `(apropos "x")` does not start unloaded upstreams.
- `(apropos "x" {:load true})` may start unloaded upstreams.
- `dir`/`doc`/`meta` trigger lazy startup for their referenced server.
- Existing `catalog/*` behavior remains unchanged during the migration phase.
- Core `ptc_runner` eval has no compile-time dependency on `ptc_runner_mcp`.
- Discovery forms fail clearly when no discovery backend is installed.
- Local bindings shadow `apropos`, `dir`, `doc`, and `meta`.
- `(map doc refs)` and other value-position uses are not supported in phase 1
  and fail clearly.

## Decisions

- `doc` returns strings only in phase 1. It is the human/LLM explanation surface;
  structured fields belong in `meta`.
- `apropos` returns compact strings in phase 1. It is optimized for low-token
  search and repair loops, not bulk structured export.
- Symbol references print as quoted syntax, e.g. `'github/search_repos`. Do not
  introduce a new `#sym/...` reader form in this phase.
- `mcp/servers` always returns maps with the string-keyed
  `catalog/list-servers`-compatible shape. Slim MCP response mode should not
  change the program value.
- Standalone `ptc_runner` builtin/user-var discovery waits until after the MCP
  migration. Keep the core hook generic, but do not widen the first
  implementation beyond MCP discovery.

For the first implementation, keep return values compatible with current
catalog behavior where possible and defer broader Clojure REPL compatibility.
