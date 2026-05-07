# PtcRunner MCP Aggregator (Future Discussion Draft)

## Status

A third sibling to `ptc-lisp-tool-call-transport.md` (shipped),
`text-mode-ptc-compute-tool.md` (drafted), and `ptc-runner-mcp-server.md`
(drafted, v1).

This plan describes an opt-in mode in which the PtcRunner MCP server
becomes both an MCP **server** (to its caller, e.g. Claude Desktop) and an
MCP **client** (to upstream MCP servers like `github`, `linear`, `slack`,
filesystem, browser). PTC-Lisp programs invoked via `ptc_lisp_execute`
call upstream tools by name; results live in the sandbox; only what the
program explicitly returns crosses back to the original LLM.

Depends on:

- **Phase 0 of `ptc-runner-mcp-server.md`** — the shared
  `PtcRunner.PtcToolProtocol` module must exist.
- **Phases 1–2 of `ptc-runner-mcp-server.md`** — basic stdio JSON-RPC
  handling and `ptc_lisp_execute` wired against `Lisp.run/2`.

Independent of the text-mode plan. Could ship before, after, or in
parallel.

## Summary

Add an `:mcp_aggregator` capability profile and an MCP-client subsystem
inside the `ptc_runner_mcp` package. PtcRunner spawns/connects to
configured upstream MCP servers at startup, fetches their tool schemas,
and exposes them inside PTC-Lisp programs via the namespace
`(mcp/<server> "<tool>" {args})`.

The PtcRunner MCP server still advertises **one** tool to its caller
(`ptc_lisp_execute`). The upstream tools are not exposed natively to the
caller — they're only reachable from inside PTC-Lisp programs. This is
the structural feature: upstream results never leave the sandbox unless
the program explicitly returns them.

## Motivation

This is the highest-leverage MCP feature, not just a refinement.

Standard MCP usage today: an LLM client has many MCP servers configured.
Each tool call's result is JSON that gets pushed back into the LLM
context. Large results bloat context, force expensive multi-turn
reasoning, and make composition of tools across servers expensive in
tokens.

Concrete example (numbers illustrative, not measured):

```
Without aggregation:
  LLM → github.search_repos          → 5,000 tokens of repos in context
  LLM → linear.list_tickets          → 8,000 tokens of tickets in context
  LLM reasons over both              → multiple turns, more tokens

With aggregator:
  LLM → ptc_runner.ptc_lisp_execute(program={
          (def repos    (mcp/github "search_repos"   {:query "infra"}))
          (def tickets  (mcp/linear "list_tickets"   {:status "open"}))
          (def matches  (filter #(some #{(:repo %)} (map :name repos)) tickets))
          (return {:count (count matches) :titles (map :title matches)})
        })
  → ~100 tokens returned
```

The 13,000 tokens of intermediate data never crossed the LLM context
boundary. The LLM also never had to do the join in its head.

The pitch: **MCP servers compose without token bloat through deterministic
compute.** This is materially stronger than "PtcRunner is a Python
alternative for MCP."

## Aggregator vs MCP v1: Scope Comparison

| Concern | MCP v1 | MCP Aggregator |
|---|---|---|
| Upstream MCP servers | None | Configured at startup; tools callable from inside programs |
| Tool namespace inside programs | None | `(mcp/<server> "<tool>" {args})` |
| Capability profile | `:mcp_no_tools` | `:mcp_aggregator` |
| Default sandbox timeout | 1 s (existing) | 10 s (network round-trips) |
| Default sandbox memory | 10 MB (existing) | 100 MB (room for upstream data in flight) |
| State across calls | None | None — upstream connections pooled at process level, but each program runs in fresh sandbox |
| Tool description | `tool_description(:mcp_no_tools)`, static | `tool_description(:mcp_aggregator)`, includes runtime-generated catalog |
| Authentication | N/A | Env-var pass-through to upstream subprocesses |

The aggregator inherits everything else from MCP v1 — request/response
contracts, error reasons, JSON renderers, isolation discipline, the
`PtcToolProtocol` module, the validator-and-sandbox safety boundary.

## Non-Goals

- Do not expose upstream MCP tools natively to the LLM client. Upstreams
  are only reachable from inside PTC-Lisp programs. This is the structural
  feature; relaxing it removes the value prop.
- Do not expose upstream MCP **resources** or **prompts** in v1. Only
  tools. Resources/prompts can come later if real usage demands them.
- Do not implement reverse-MCP callbacks (where PtcRunner asks its caller
  to execute something on its behalf). One direction only: PtcRunner →
  upstream.
- Do not introduce sessions or stateful per-call memory in PtcRunner. The
  upstream MCP servers themselves may be stateful (browser sessions,
  websockets); that's their concern. Each PTC-Lisp call is independent.
- Do not handle upstream authentication beyond env-var pass-through. No
  credential vault, no OAuth flow handling. Use the standard MCP config
  pattern.
- Do not auto-refresh upstream schemas at runtime in v1. Schemas are
  fetched at startup and cached. If an upstream changes its tools, restart
  PtcRunner.
- Do not implement cycle detection for recursive aggregation
  (PtcRunner-A wrapping PtcRunner-B wrapping PtcRunner-A). Document the
  pattern as supported but unsafeguarded; depth limits are deferred.

## Shared Protocol Module

Reuses `PtcRunner.PtcToolProtocol` from the MCP server plan's Phase 0.
Adds **one** new capability profile:

| Profile | Capability note |
|---|---|
| `:mcp_aggregator` | "Available upstream MCP tools (callable via `(mcp/<server> \"<tool>\" {args})`):\n\n<runtime-generated catalog>\n\nEach upstream call is a JSON-RPC round-trip; budget program time accordingly. Pass external data via the `context` argument; each invocation is independent — there is no memory of prior calls." |

The capability note is **dynamic** — the catalog is built at startup from
the upstream `tools/list` responses. `PtcToolProtocol.tool_description/1`
gains an optional second arg for the aggregator profile:

```elixir
PtcToolProtocol.tool_description(:mcp_aggregator, catalog: catalog_string)
```

Where `catalog_string` is built by the aggregator subsystem (see "Tool
Discovery and Catalog" below). Tests assert the rendered description
contains a stable substring identifying it as aggregator-mode plus
substring matches against known upstream tools in the test config.

## Proposed Shape

The MCP server reads an aggregator config file at startup (path via
`--upstreams-config <path>` flag or `PTC_RUNNER_MCP_UPSTREAMS` env var).
Format mirrors Claude Desktop's `claude_desktop_config.json`:

```json
{
  "upstreams": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_TOKEN": "${GITHUB_TOKEN}"
      }
    },
    "linear": {
      "command": "linear-mcp",
      "args": []
    },
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/work"]
    }
  }
}
```

`${VAR}` placeholders in `env` are interpolated from PtcRunner's parent
shell environment at startup.

If no config file is provided, the server runs in MCP v1 mode
(`:mcp_no_tools` profile) — aggregator mode is opt-in via configuration.

## Tool Namespace

PTC-Lisp programs call upstream tools as:

```clojure
(mcp/<server> "<tool>" {args-map})
```

- `<server>` — namespace name from the config (e.g. `github`, `linear`).
  Used as a Lisp namespace, so it must be a valid identifier.
- `"<tool>"` — string, exactly the tool name the upstream advertises.
  Quoted as a string (not a Lisp identifier) because upstream tool names
  often contain underscores or other characters and we don't want to
  force PTC-Lisp identifier rules onto JSON Schema names.
- `{args-map}` — string-keyed map. Coerced to JSON for the upstream
  `tools/call` request.

Examples:

```clojure
(def repos (mcp/github "search_repos" {:query "infra" :limit 50}))
(def pr    (mcp/github "get_pr"       {:owner "anthropic" :repo "...", :number 42}))
(def files (mcp/filesystem "list"     {:path "/Users/me/work"}))

;; Parallel via pmap
(def all-prs
  (pmap #(mcp/github "get_pr" {:owner "anthropic" :repo "..." :number %})
        pr-numbers))
```

The Lisp interpreter's tool dispatch routes `mcp/<server>` calls to the
MCP client subsystem (see "Connection Management" below) rather than to
the agent's app-tool registry.

Server-name collisions are impossible because each upstream is a separate
namespace. Tool-name collisions across upstreams don't matter — the
namespace prefix disambiguates.

## Tool Discovery and Catalog

At startup:

1. PtcRunner reads the upstreams config.
2. For each upstream, PtcRunner spawns the subprocess with the configured
   command, args, env.
3. Sends standard MCP `initialize` and `tools/list` over stdio JSON-RPC.
4. Caches the returned tool schemas keyed by `{server, tool_name}`.
5. Builds the catalog string for the `:mcp_aggregator` capability note.

Catalog format (token-budget-conscious):

```
github:
  search_repos(query: string, limit: int?) - Search GitHub repositories
  get_pr(owner: string, repo: string, number: int) - Get a pull request

linear:
  list_tickets(status: string?, project: string?) - List Linear tickets
  create_ticket(title: string, description: string?) - Create a ticket
```

Each tool entry is one line: `name(args) - description`. Args are
rendered from the upstream JSON Schema, abbreviated. Descriptions
truncated at e.g. 80 characters to keep token cost bounded.

**Token cost concern**: a setup with 30 upstream tools at ~50 tokens each
adds ~1500 tokens to the `ptc_lisp_execute` tool description. Acceptable
for v1 — better than the LLM not knowing what to call. Future: consider
exposing the catalog as an MCP **resource** so clients can fetch it on
demand instead of paying the description-token cost on every request.

If an upstream fails `initialize` or `tools/list` at startup, log the
error and continue with the surviving upstreams. The failed upstream's
namespace is unavailable; calls to it raise a runtime error.

## Connection Management

Upstream subprocesses are spawned **once at startup** and held for the
lifetime of the PtcRunner MCP server. PTC-Lisp programs do not spawn or
close upstreams — they share the connection pool.

Architecture sketch:

- `PtcRunner.MCPClient.Pool` — GenServer holding state for all upstreams:
  subprocess refs, JSON-RPC request id counters, schema cache.
- `PtcRunner.MCPClient.Connection` — one process per upstream, owns the
  port to the upstream subprocess, manages JSON-RPC framing and
  request/response correlation.
- The Lisp interpreter's `mcp/<server>` dispatch calls
  `MCPClient.Pool.upstream_call(server, tool, args, timeout)`, which
  routes to the right `Connection` and blocks until the response or
  timeout.

Sandbox processes call into the pool via standard GenServer.call. The
sandbox's existing safety guarantees (no I/O via `Process.spawn` etc.)
are preserved because the upstream call is mediated by the runtime, not
performed inside the sandbox process.

**Subprocess lifecycle**:

- An upstream that crashes is restarted with exponential backoff (cap at
  e.g. 30 s).
- While an upstream is down, `(mcp/<server> ...)` calls raise
  PTC-Lisp runtime errors.
- On graceful PtcRunner shutdown, all upstream subprocesses are
  terminated cleanly via stdin EOF.

## Resource Limits

| Limit | Default | Configurable | On exceed |
|---|---|---|---|
| `program_timeout` | **10 s** (bumped from 1s) | flag / env | `timeout` |
| `program_memory_limit` | **100 MB** (bumped from 10MB) | flag / env | `memory_limit` |
| `max_upstream_response_bytes` | 16 MB per call | flag / env | runtime error in program |
| `max_upstream_calls_per_program` | 50 | flag / env | runtime error in program |
| `upstream_call_timeout` | 5 s per call | flag / env | runtime error in program |
| Existing `max_program_bytes` / `max_context_bytes` / `max_concurrent_calls` | inherited from MCP v1 | flag / env | inherited from MCP v1 |

**Why bump program timeout and memory**: aggregator programs do
network-bound work and hold upstream data in memory for the duration of
the program. Keeping the v1 1s/10MB caps would make the aggregator
unusable for any real workload. The bumps are profile-specific —
non-aggregator programs still run under v1 caps.

**Per-upstream rate limiting** is not in v1. If an upstream rate-limits
PtcRunner, the program sees the upstream's error response. Documented as
the user's concern to manage at the upstream config level (e.g., narrow
queries, smaller batches).

## Wire Format

Reuses the **shared response contract** from `ptc-runner-mcp-server.md`
verbatim. No changes.

The `ptc_lisp_execute` tool's response shape is identical to MCP v1:
success JSON (R22) with optional `validated` field, error JSON (R23) with
the shared reason enum.

Upstream call errors surface as PTC-Lisp **runtime errors** (`reason:
"runtime_error"` in the wrapper response). The runtime error message
includes the upstream server name, tool name, and the upstream's error
text:

```
runtime_error: upstream call (mcp/github "get_pr") failed: 404 Not Found
```

A new dedicated reason like `upstream_error` is **not** added to the
shared enum in v1. Reason: keeps the enum surface-stable and forces the
program author to handle upstream failures the same way they handle
in-program runtime errors. If real usage shows upstream errors are
materially different to handle, add the reason later.

## Error Model

Upstream call failures map to PTC-Lisp runtime errors:

| Failure | PTC-Lisp behavior |
|---|---|
| Upstream subprocess died (waiting reconnect) | Runtime error: "upstream X is unavailable; will retry on next program execution" |
| Upstream returned JSON-RPC error | Runtime error with the upstream's error message embedded |
| Upstream timeout (> `upstream_call_timeout`) | Runtime error: "upstream X timed out after 5s" |
| Upstream response > `max_upstream_response_bytes` | Runtime error: "upstream X returned response too large (Y bytes); refine the query or paginate" |
| Upstream tool not in catalog | Runtime error: "no tool 'foo' in upstream X" |
| Unknown upstream namespace | Runtime error: "no upstream 'X' configured" |
| `max_upstream_calls_per_program` exceeded | Runtime error: "upstream call budget exhausted (50)" |

PTC-Lisp doesn't have try/catch (per `<restrictions>` in the system
prompt), so upstream failures terminate the program. Programs that want
graceful degradation can structure with `pmap` followed by filtering nils
if the upstream supports nil-on-error responses, or pre-validate inputs
before calling.

## Authentication

Pass-through via env-var interpolation in the config:

```json
"env": {
  "GITHUB_TOKEN": "${GITHUB_TOKEN}",
  "LINEAR_API_KEY": "${LINEAR_API_KEY}"
}
```

PtcRunner reads from its parent shell environment at startup. Upstream
subprocesses see the resolved values.

PtcRunner does **not**:
- Manage credentials directly (no vault, no OAuth flows).
- Read `.env` files.
- Persist credentials to disk.
- Validate credentials before use (the upstream MCP server is responsible
  for that; if a credential is wrong, the upstream returns errors that
  surface as runtime errors).

If a credential leaks via an upstream's response (e.g., an upstream
echoes the token back), it stays in the sandbox unless the program
explicitly returns it. This is incidentally a useful safety property of
the aggregator pattern: returning data is opt-in.

## Phases

### Phase 1 — MCP client subsystem

- New module `PtcRunner.MCPClient` with `Connection` (one per upstream)
  and basic `initialize` / `tools/list` / `tools/call` JSON-RPC handling.
- Tested against a mock upstream (a small fixture process that speaks
  MCP).
- No PtcRunner integration yet; standalone library.

**DoD**: a unit test spawns a mock upstream, connects, calls a fixture
tool, gets back a response. Subprocess lifecycle (crash, restart, EOF
shutdown) covered.

### Phase 2 — Connection pool + upstream config

- New `PtcRunner.MCPClient.Pool` GenServer.
- Reads config file, spawns upstreams at startup, builds schema cache.
- Exposes `Pool.upstream_call(server, tool, args, timeout)` API.
- Catalog string builder for the `:mcp_aggregator` capability note.

**DoD**: PtcRunner MCP server with a config containing two real upstream
servers (e.g., `@modelcontextprotocol/server-filesystem` and another)
starts cleanly, builds a catalog, and can route calls to either upstream.

### Phase 3 — `:mcp_aggregator` capability profile + Lisp dispatch

- Add the profile to `PtcToolProtocol.tool_description/2`.
- Wire `(mcp/<server> "<tool>" {args})` dispatch in the Lisp interpreter's
  tool namespace.
- Surface upstream errors as runtime errors with the formatted messages
  from the Error Model table.
- Bump default `program_timeout` and `program_memory_limit` for
  aggregator profile only.
- Enforce `max_upstream_calls_per_program`,
  `max_upstream_response_bytes`, `upstream_call_timeout`.

**DoD**: a PTC-Lisp program calling
`(mcp/filesystem "list" {:path "/tmp"})` runs end-to-end through the MCP
server, returns a real result. `pmap` over upstream calls runs in
parallel (verifiable via timing).

### Phase 4 — Configuration ergonomics + lifecycle

- `--upstreams-config <path>` flag and `PTC_RUNNER_MCP_UPSTREAMS` env
  var.
- Document config file format with examples.
- Graceful shutdown propagates to upstream subprocesses.
- Upstream crash + reconnect with exponential backoff.

**DoD**: a non-Elixir user can write a config file, point the binary at
it, and have the upstream catalog show up in their MCP client's tool
description.

### Phase 5 — Integration tests + docs + benchmarks

- Live integration tests against at least 2 real upstream MCP servers
  (filesystem + one other; choose by stability).
- Tutorial docs covering the cross-server-compose pattern.
- Example configs for popular setups (github + linear, filesystem + git,
  etc.).
- Benchmark: token cost comparison on a representative cross-server
  workload — native MCP calls vs aggregator with a single
  `ptc_lisp_execute` call. The "what's the actual savings" story.

## Tests Required

- `tools/list` on the PtcRunner MCP server still advertises exactly one
  tool (`ptc_lisp_execute`) — upstream tools are NOT exposed natively.
- Description in aggregator mode equals
  `PtcToolProtocol.tool_description(:mcp_aggregator, catalog: <catalog>)`.
- Description contains a stable "Available upstream MCP tools" substring.
- Description includes substrings for each configured upstream's
  namespace.
- `(mcp/<server> "<tool>" {args})` dispatch reaches the right upstream
  and returns its result as a PTC-Lisp value.
- Upstream subprocess crash → next call raises runtime error; subprocess
  reconnects; subsequent call succeeds.
- Upstream JSON-RPC error → runtime error with the upstream's error text
  in the message.
- Upstream timeout → runtime error citing the timeout limit.
- Upstream response > `max_upstream_response_bytes` → runtime error with
  size and "refine query" hint.
- `max_upstream_calls_per_program` enforced; the (N+1)th call raises a
  runtime error with the budget value in the message.
- Unknown upstream namespace → runtime error.
- Unknown tool in known upstream → runtime error.
- `pmap` over upstream calls executes in parallel (verifiable via timing
  on a mock that simulates 100ms latency: 10 sequential calls = 1s, 10
  parallel calls = ~150ms).
- Env-var interpolation in upstream config (`${VAR}`) works for known
  vars; unset vars produce a clear startup error.
- No upstream config → server runs in MCP v1 mode
  (`:mcp_no_tools` profile), no upstream namespace available, `(mcp/...)`
  calls raise runtime errors.
- Bumped sandbox memory and timeout caps apply only when in aggregator
  profile; non-aggregator runs unaffected.
- Recursive aggregation works mechanically (PtcRunner-A wrapping
  PtcRunner-B wrapping a real upstream returns the right value through
  both layers; depth limit not enforced in v1).

## Deferred From v1

- **MCP resources / prompts from upstreams.** Aggregator v1 exposes only
  upstream **tools**. If real workflows need to surface upstream
  documentation or prompt scaffolds, add later.
- **Schema refresh on upstream `tools/list_changed` notifications.** v1
  fetches schemas at startup only. Refresh requires re-broadcasting the
  catalog change to the LLM client, which the standard MCP protocol
  supports — wire when needed.
- **Per-upstream rate limiting.** v1 lets the upstream's own rate limiter
  take effect. If users hit it often enough that "rate limit exceeded"
  errors propagate as bad UX, add server-side throttling.
- **Per-program upstream call quotas beyond the global cap.** v1 has one
  cap (`max_upstream_calls_per_program`) shared across all upstreams.
  Per-upstream quotas could come later.
- **Cycle detection for recursive aggregation.** Documented as supported
  but unsafeguarded. A program that runs PtcRunner → PtcRunner → ... in a
  loop will eventually hit `max_upstream_calls_per_program` or a timeout,
  but explicit cycle detection is cleaner. Defer.
- **Server-side caching of upstream responses.** Tempting (especially for
  read-only tools) but adds correctness pitfalls (when to invalidate?
  what about authenticated tools?). Defer until real usage shows it's
  worth the design.
- **Upstream credential management beyond env-var pass-through.** No
  vault, no OAuth flow, no encrypted storage in v1.
- **Streaming upstream responses.** If an upstream tool streams (e.g., a
  log tail), v1 collects the full response before returning to the
  program. Streaming through to PTC-Lisp would require new language
  primitives. Defer.

## Open Questions

- **Catalog format trade-off**: embed in tool description (token cost on
  every request) vs expose as MCP resource (cleaner but requires client
  resource support). v1 picks description; revisit if token cost becomes
  an issue in real configs.
- **Upstream tool description filtering**: should PtcRunner edit upstream
  descriptions before embedding (truncate, strip examples, etc.)? v1:
  truncate at 80 chars, otherwise pass through.
- **Should `tools/list` cache be invalidated on upstream restart?** When
  an upstream subprocess crashes and restarts, it might come back with a
  different schema (e.g., upgraded server). v1: log a warning if `tools/list`
  on reconnect differs from cache, but keep the original cache to avoid
  mid-flight schema drift. Document that schema changes require PtcRunner
  restart.
- **Concurrency vs upstream limits**: a `pmap` over 50 upstream calls
  could overwhelm a single upstream. Should there be a per-upstream
  inflight cap? Defer; document as user's concern via narrower queries
  or sequential `map`.
- **Schema-to-PTC-Lisp signature mapping**: should upstream JSON Schemas
  generate PTC-Lisp signatures so the LLM gets structured type info? v1:
  no — pass schemas as opaque description text. Adding signature
  generation is a separate effort that affects all signature consumers.
- **Multi-upstream credential propagation in recursive aggregation**: if
  PtcRunner-A wraps PtcRunner-B, do credentials flow? v1: each PtcRunner
  reads its own config; no automatic propagation.
