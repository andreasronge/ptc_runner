# HTTP Transport & Credentials Registry — Specification

| Field | Value |
|---|---|
| Status | Build-ready (2026-05-09). Spec frozen; §12 enumerates phased subagent build with codex review gates between phases. |
| Target package | `:ptc_runner_mcp` |
| Depends on | `Plans/ptc-runner-mcp-aggregator.md` (Phase 4 shipped) |
| Sibling docs | `Plans/positioning-mcp-aggregator.md` §"Honest weaknesses #6, #7"; §"Feature signals #3, #4" |
| Last revised | 2026-05-09 (post-codex-5) |

This document specifies HTTP transport for upstream MCP servers and the
credentials registry that secures it. The two halves ship as one
feature because each is structurally weaker without the other:

- HTTP transport without a credentials model forces bearer tokens
  through the same `${VAR}` env-substitution path as stdio, where a
  misbehaving upstream that echoes its environment (or, on HTTP, its
  request headers) back through a tool result can leak the secret —
  this is exactly the structural weakness the positioning doc flags as
  weakness #7.
- A credentials registry without a non-stdio transport is plumbing for
  no consumer.

Sections using **MUST** / **SHOULD** / **MAY** carry RFC 2119 normative
weight.

## 1. Scope and Goals

The work delivers two complementary, layered pieces:

1. **HTTP transport for upstream MCP servers** — an
   `Upstream.Http` impl conforming to `PtcRunnerMcp.Upstream` (§6.3 of
   the aggregator spec) that speaks the **Streamable HTTP** transport
   targeting MCP revision **2025-06-18** (see §6.1 for
   protocol-version selection and the relationship to the newer
   2025-11-25 revision).
2. **Credentials registry** — a top-level `credentials:` config block
   parallel to `upstreams:`, plus a `PtcRunnerMcp.Credentials` registry
   process that resolves binding names to auth material on demand and
   keeps raw secrets out of upstream-config maps, error detail strings,
   `upstream_calls` audit entries, and trace JSONL.

Goals:

1. Bring **transport-shape** parity with Cloudflare Code Mode and
   MCPProxy on the dimension that currently locks PtcRunner out of
   remote MCPs — the ability to call upstream MCPs over HTTP at all.
   This spec does **not** claim auth-flow parity with Cloudflare:
   Cloudflare Code Mode does full OAuth 2.0 with hidden binding
   objects; v1 PtcRunner ships static-secret bindings only (OAuth is
   §3 non-goal #1).
2. Unblock wrapping of remote MCPs that have no stdio surface — the
   GitHub MCP server, Cloudflare-hosted MCPs, and organization-internal
   HTTP MCPs behind SSO gateways. These are the upstreams self-host
   adopters most consistently ask for and which the v1 aggregator
   cannot reach.
3. Preserve the v1 aggregator's three-class failure model
   (`Plans/ptc-runner-mcp-aggregator.md` §7) over HTTP **without
   redefining any class.** World-fault maps to `nil` and records
   `status: "error"` in `upstream_calls`; programmer-fault raises a
   PTC-Lisp runtime error and **only** for the three classes already
   enumerated in §7.2 of the base spec (unknown server / unknown tool
   in known upstream / unencodable args). Upstream JSON-RPC errors —
   including HTTP responses that carry a JSON-RPC error body — are
   world-fault per base spec §7.1, not programmer-fault. The behaviour
   invariant (`call/4` MUST NOT raise) holds.
4. Make raw secrets unreachable from the PTC-Lisp sandbox **and from
   PtcRunner's own logging / tracing surfaces**, by **structural
   isolation** as the primary guarantee and best-effort redaction as
   defense in depth. Structural isolation: resolved auth bytes are not
   stored in upstream config maps, Connection snapshots, trace payloads,
   or `upstream_calls`; only `Upstream.Http` is a legitimate consumer;
   the sandbox has no built-in to reach the registry; the
   `upstream_calls` collector records binding *names*, never values;
   HTTP upstream config has no dynamic header field that accepts a raw
   secret (see §5.3). Defense in depth: an ETS redaction set
   (owner-write, globally-readable by BEAM processes; §7.5)
   substring-matches known-resolved values in any string the log /
   trace / `upstream_calls` writers would emit.
5. Stay opt-in: existing stdio configs **MUST** continue to load and
   run unchanged (§14 — Migration & Compatibility).

### 1.1 Target workflow

```clojure
;; Two upstreams, mixed transport. From the program's perspective
;; they are indistinguishable.
(def repos (tool/mcp-call {:server "github"          ;; HTTP upstream
                           :tool "search_repos"
                           :args {:query "infra" :limit 50}}))

(def files (tool/mcp-call {:server "fs"              ;; stdio upstream
                           :tool "read_text_file"
                           :args {:path "README.md"}}))

(return {:repo-count (count repos)
         :readme-len (count files)})
```

The corresponding `upstreams.json`:

```json
{
  "credentials": {
    "github-pat": {
      "source": "env",
      "var": "GITHUB_PAT"
    }
  },
  "upstreams": {
    "github": {
      "transport": "http",
      "url": "https://api.githubcopilot.com/mcp/",
      "auth": [{ "scheme": "bearer", "binding": "github-pat" }]
    },
    "fs": {
      "command": "npx",
      "args": ["--yes", "@modelcontextprotocol/server-filesystem@2026.1.14",
               "/Users/me/sandbox"]
    }
  }
}
```

## 2. Definitions

| Term | Meaning |
|---|---|
| Streamable HTTP transport | The MCP transport defined in spec revision 2025-03-26 and refined in 2025-06-18: one endpoint URL serving both client→server `POST`s (JSON-RPC requests/responses) and optional server→client `GET` SSE streams (notifications). Replaces the legacy "HTTP+SSE" two-endpoint transport. v1 targets the **2025-06-18** revision; see §6.1. |
| MCP session | A session established by the `initialize` handshake. The server returns a `Mcp-Session-Id` header on the initialize response; subsequent requests echo it. Session loss (server returns `404` for an in-flight `Mcp-Session-Id`) is a normal, recoverable event. |
| Binding | A named entry in the `credentials:` config block. Identifies how to obtain auth material; its **value** is never exposed. |
| Auth emitter | An entry in an HTTP upstream's `auth:` list that produces one auth-bearing HTTP header at request time. Schemes in v1: `bearer`, `basic`, `custom_header`. Multiple emitters per upstream are allowed (§5.3.1) — each upstream produces N headers, one per emitter. |
| Static header | A literal, non-secret HTTP header configured on an HTTP upstream via `static_headers:` (§5.3.2). Static headers are never `${VAR}`-expanded, never materialized through `Credentials`, and are rejected for sensitive header names. |
| Resolved auth material | The transient bytes the credentials registry produces for a binding when asked. Lifetime: held in process memory only; never written to disk; not cached on `Upstream.Http` Connection state across requests in v1 (§7.3). |
| Redaction set | An ETS table owned by the credentials registry (`:protected` mode — owner-write, globally-readable by BEAM processes) populated the first time each binding is materialized. Holds **plaintext bytes** (not hashes — see §7.5 for why hashes are insufficient). Read consumers: the redactor filter wired into `Log`, `TraceFile`, `TracePayload`, and `UpstreamCalls`. Best-effort second line of defense; the primary guarantee is structural isolation from the PTC-Lisp sandbox and normal MCP/logging surfaces, not BEAM-wide secrecy. |

## 3. Non-Goals

The following are explicitly **out of scope** for this specification:

- **OAuth 2.0 flows** (authorization_code, client_credentials, refresh
  loops, dynamic client registration RFC 7591, server-metadata discovery
  RFC 8414). v1 ships static-secret bindings only. The `Credentials`
  registry's `materialize/1` shape (§7.2) is designed to absorb
  refresh-token-with-callback in v2 without changing the call sites.
- **Persistent token storage across PtcRunner restarts.** v1 holds
  resolved auth material in process memory only.
- **Server→client SSE GET subscriptions.** v1 issues `POST` requests
  only and does not open a long-lived `GET` SSE stream. Upstream-pushed
  notifications (e.g., `notifications/tools/list_changed`) are
  therefore not delivered in v1; the cached `tools/list` is refreshed
  at Connection restart, same as stdio. (POST-response SSE — where the
  server responds to a `POST` with `text/event-stream` instead of
  `application/json` — **is** supported per §6.4; this non-goal is
  about the long-lived GET stream only.)
- **mTLS authentication.** Plain HTTPS with system trust store only.
  mTLS is a v2 feature.
- **`exec` binding source.** Deferred to v1.1 behind an explicit
  `allow_exec_bindings: true` server-level flag (resolves OQ-7 of the
  draft). Running an arbitrary command at credential-materialization
  time is a meaningful expansion of the trusted surface — operators
  who need 1Password/Vault/STS integration in v1 wire it through
  `file` source, with their own cron / launchd refreshing the file.
- **Per-tool credential scoping inside one upstream.** A single upstream
  binds to one auth emitter list. Operators who need finer-grained
  scoping configure two upstream entries that point at the same URL
  with different `auth:` lists.
- **OS keychain integration** (macOS Keychain, Linux Secret Service,
  Windows Credential Manager). v2 candidate. v1 sources are `env`,
  `file`, and `literal` (§5.4); `exec` deferred per above.
- **Plain HTTP (non-TLS) upstreams.** v1 rejects `http://` URLs at
  config-load time unless `allow_insecure_http: true` is set on the
  upstream entry. Default-deny. When `allow_insecure_http` is set,
  the loader **also** rejects any `auth:` emitter on that upstream
  unless `allow_insecure_auth: true` is set on the same entry — sending
  bearer tokens over plain HTTP is a footgun that needs two explicit
  opt-ins, not one.
- **Self-as-upstream rejection over HTTP.** The §5.3 self-as-upstream
  guard in the aggregator spec applies to stdio command resolution
  only. An HTTP URL pointing at the loopback of a sibling PtcRunner
  process is technically possible and is unsafeguarded. Programs that
  loop will eventually hit `max_upstream_calls_per_program`.

**HTTP proxy support is in scope** (was a non-goal in the codex-1
draft). Operators behind a forward proxy are part of the target
audience (org-internal HTTP MCPs behind SSO gateways). v1 ships
**explicit per-upstream `proxy:` URL configuration only** — see §5.3.
The codex-1 draft claimed Finch/Mint auto-resolve `HTTPS_PROXY` /
`NO_PROXY` env vars; that claim was wrong (verified against
`demo/deps/req/lib/req/steps.ex` and `demo/deps/mint/lib/mint/http.ex` —
both require explicit `connect_options: [proxy: ...]`). v1 does not
implement env-var-to-`proxy` translation; v1.1 may. Operators with
existing `HTTPS_PROXY` env-var workflows set the corresponding
`proxy:` URL on each HTTP upstream entry until then.

## 4. Architecture

### 4.1 Transport split

The v1 aggregator spec defines `PtcRunnerMcp.Upstream` as a behaviour
(§6.3) and `PtcRunnerMcp.Upstream.Stdio` as the only production impl.
This spec adds a sibling impl, `PtcRunnerMcp.Upstream.Http`, conforming
to the same behaviour. **No behaviour shape change.**

The behaviour invariants (`start_link/2` completes the MCP handshake
before returning `:ok`, `call/4` enforces both `:timeout` and
`:max_response_bytes`, `call/4` MUST NOT raise, `stop/1` is idempotent)
hold for the new impl.

```
mcp_server/lib/ptc_runner_mcp/
  upstream/
    fake.ex                      # in-process impl (Phase 1a — unchanged)
    stdio.ex                     # subprocess impl (Phase 1b — unchanged)
    http.ex                      # NEW — HTTP impl
    http/
      session.ex                 # session-id state, reconnect, handshake
      transport.ex               # Req-based wire layer
    connection.ex                # per-name worker — unchanged for HTTP
    registry.ex                  # routing/config — extended dispatch
    supervisor.ex                # one_for_one — unchanged
  credentials.ex                 # NEW — registry public API
  credentials/
    binding.ex                   # NEW — binding spec + resolution
    redactor.ex                  # NEW — trace/log redaction filter
  application.ex                 # extended config loader
```

Routing via `Upstream.Connection` is unchanged. The Connection holds
`impl: PtcRunnerMcp.Upstream.Http` (or `.Stdio`) plus the impl's
config; concurrent `pmap` calls into the same HTTP upstream are
serialized at the per-name Connection mailbox for `ensure_started/1`
and proceed in parallel for `call/4` (the impl owns its own
in-flight-request bookkeeping per `tools/call`, same property as
`Upstream.Stdio`).

### 4.2 Credentials registry

A new singleton GenServer, `PtcRunnerMcp.Credentials`, started by
`PtcRunnerMcp.Application` *before* the upstream supervision tree.
It holds the parsed `credentials:` config block as
`%{binding_name => Binding.t()}` and exposes (full shape spec'd in
§7.2):

```elixir
@spec materialize(binding_name :: String.t()) ::
        {:ok, %{required(:raw) => binary(),
                required(:scheme_hint) => :bearer | :basic | :raw,
                required(:expires_at) => integer() | :never}}
        | {:error, :unknown_binding | :resolution_failed, detail :: String.t()}
```

The result is opaque to callers; the `Upstream.Http` impl hands it to
`Credentials.apply/2` (§7.3) along with the auth emitter spec, and
`apply/2` returns an opaque `%Credentials.RedactedHeaders{}` wrapper for
the request layer to splice into the outbound request. Callers never
inspect `material`-shaped fields directly and never unwrap the header
wrapper except at the HTTP request boundary. This indirection makes the
v2 OAuth migration non-breaking: the materialization shape extends
(adding refresh-callback metadata) without breaking call sites.

Resolved auth bytes flow through a deliberately small set of places in
v1: (a) the Credentials GenServer state for `literal` binding specs and
transient materialization variables, (b) the redaction set ETS table,
(c) transient variables in `Upstream.Http` while constructing headers,
and (d) the in-flight `Req` / Finch request for the duration of the HTTP
call. They are not stored in upstream config maps, Connection snapshots,
trace payloads, or `upstream_calls` entries. The §7.5 redaction filter
is defense in depth for any code path that accidentally turns those
bytes into a string before logging or tracing it.

### 4.3 Connection lifecycle for HTTP upstreams

The base aggregator spec §4.3 specifies "lazy-spawned upstreams;
cold start cost surfaces as the first call's latency" but the current
implementation **eagerly starts all configured upstreams at boot** to
freeze the catalog (`mcp_server/lib/ptc_runner_mcp/upstream/supervisor.ex:60`).
HTTP upstreams **MUST** participate in this eager-start sweep on the
same terms as stdio: each HTTP upstream's `start_link/2` runs at boot,
attempts the handshake, and either populates `cached_tools` or fails
non-fatally (Connection stays `:not_started`, catalog renders that
upstream as "(unavailable at startup)").

Boot-time semantics:

- **Credential materialization runs at boot** for every HTTP upstream
  with an `auth:` block, because the handshake `POST` needs the auth
  header. A binding that fails to resolve at boot
  (`{:error, :resolution_failed, …}`) renders the upstream as
  unavailable at startup. This is an init-time failure, so it follows
  current `Connection` semantics and **does not** arm the recovery
  backoff window; backoff is reserved for `:DOWN` from a previously
  started impl.
- **Boot-time HTTP failures are non-fatal**, identical to stdio
  subprocess-spawn failures. The aggregator does not refuse to boot
  because GitHub is down.
- The `@eager_start_warn_ms` cumulative threshold
  (`supervisor.ex:51`, default 5_000 ms) applies unchanged. HTTP
  upstreams with slow handshakes count toward the same budget.

Steady-state mapping (HTTP analogs of stdio lifecycle events):

- **"Spawn"** = open the Finch pool for this upstream, materialize
  bindings via `Credentials.materialize/1`, POST `initialize`, capture
  any returned `Mcp-Session-Id`, POST `notifications/initialized`,
  POST `tools/list`.
- **"Started"** = handshake complete; session ID (if any) and tools
  cached on the impl's GenServer state.
- **"Subprocess crash mid-call"** has no direct HTTP analog. The
  closest event is **session loss**: the server returns HTTP 404 for a
  request carrying our held `Mcp-Session-Id`. Handling is described
  immediately below.

#### 4.3.1 Session loss → DOWN, not in-place recovery

The codex-1 draft proposed "in-place re-init: clear session, re-run
handshake, retry the original request once." That path is **not
implementable through the current `Connection` GenServer** — `Connection.call/4`
(`upstream/connection.ex:275`) forwards the impl's reply from the caller
process, with no side channel to invalidate cached tools or arm
backoff on a *successful* call's return. In-place reinit would also
silently desynchronize Connection's `cached_tools` from the impl's
new tools list.

**Revised semantics: session loss → impl exits abnormally → existing
`:DOWN` path runs.**

Concretely, on receiving HTTP 404 with the held `Mcp-Session-Id`:

1. The `Upstream.Http` impl GenServer **MUST** reply to the in-flight
   caller with `{:error, :upstream_unavailable, "session_lost"}`.
2. The impl GenServer **MUST** then `{:stop, :session_lost, state}`
   itself.
3. `Connection`'s existing monitor on the impl pid fires
   (`connection.ex:446`); `abnormal_exit?(:session_lost)` returns `true`
   per `connection.ex:629`, so `Connection` invalidates its
   `cached_tools`, transitions to `:not_started`, and arms
   `backoff_until_ms` per the existing recovery-backoff path.
4. The next `(tool/mcp-call …)` against this upstream cold-starts a
   fresh impl, re-materializes the binding, runs a fresh handshake
   (which gets a new session ID and a fresh `tools/list`), and
   proceeds. `cached_tools` is overwritten cleanly with the new list —
   no desynchronization window.

This reuses the existing crash-recovery semantics verbatim. **No new
invalidation path on `Connection` is needed.** The only new constraint
is on the impl: it **MUST** classify session-loss as an abnormal exit
reason so the existing `abnormal_exit?/1` clause arms backoff.

Same path applies to:

- HTTP 401/403 after a binding rotation (treat as auth failure → impl
  exits abnormally → next cold-start re-materializes).
- A run of network errors past the per-call retry budget (impl exits
  abnormally; `Connection` arms backoff).

The performance cost of "exit and respawn instead of patch in place"
is one extra GenServer init + Finch pool reopen per session-loss
event. Session-loss events are rare (upstream restart cadence); the
simplicity of reusing the existing path is worth the few-ms cost.

### 4.4 Connection.cached_tools refresh on respawn

The base spec's Connection model already overwrites `cached_tools`
on every successful `attempt_start/3` (`connection.ex:548-554`). The
HTTP impl gets this for free as long as session-loss → exit → respawn
is the recovery path. Operators **MAY** notice that an upstream that
adds or removes tools mid-life only reflects in PtcRunner's catalog
after the next session-loss-triggered respawn (or PtcRunner restart) —
this matches the stdio semantics ("cached `tools/list` is refreshed at
Connection restart") and is consistent with §3 non-goal "no SSE GET
subscription / no `tools/list_changed` handling."

### 4.5 Optional dependency

`Upstream.Http` depends on `:req` (which transitively depends on
`:finch`, `:mint`, and `:nimble_options`). These are added as
**optional** Mix deps:

```elixir
{:req, "~> 0.5", optional: true}
```

If the dependency is not loaded at boot AND any upstream entry has
`transport: "http"`, the application **MUST** fail loudly with a
descriptive error message ("Upstream 'github' uses HTTP transport
but :req is not available; add it to your deps") rather than
silently falling back.

## 5. Configuration

### 5.1 File format extension

The upstreams JSON file (`Plans/ptc-runner-mcp-aggregator.md` §5.2)
is extended with two changes:

1. A new **top-level `credentials:`** block (parallel to `upstreams:`).
   Optional. May be empty.
2. Each `upstreams.<name>` entry **MAY** include a `transport:` field.
   If absent, defaults to `"stdio"` and the entry is parsed as today
   (backward compatible). If `"http"`, the entry is parsed as an HTTP
   upstream.

```json
{
  "credentials": {
    "<binding-name>": <binding-spec>,
    ...
  },
  "upstreams": {
    "<server-name>": <stdio-spec> | <http-spec>,
    ...
  }
}
```

### 5.2 Stdio upstream spec (unchanged)

```
{
  "transport": "stdio",                 // optional, defaults to "stdio"
  "command": String,                    // required
  "args": [String],                     // default []
  "env": { String -> String },          // default {}; ${VAR} resolved
  "cd": String | null,                  // default null
  "handshake_timeout_ms": Int,          // default 10000
  "backoff_initial_ms": Int,            // default 100
  "backoff_max_ms": Int                 // default 30000
}
```

The existing `${VAR}` placeholder resolution in `env` values (§5.2 of
the aggregator spec, implemented at
`mcp_server/lib/ptc_runner_mcp/application.ex:401`) is **unchanged**.
Stdio configs **MUST NOT** be required to migrate to bindings. The
loader change for this spec MUST narrow the recursive placeholder
resolver so it only applies to stdio `env` values, not to the entire
decoded upstreams JSON tree. In particular, `credentials:` and
`static_headers:` values are parsed literally.

### 5.3 HTTP upstream spec (new)

```
{
  "transport": "http",                  // required
  "url": String,                        // required, https:// (http:// rejected
                                        //   unless allow_insecure_http: true)
  "auth": [<auth-emitter>, ...] | null, // optional; default null = no headers.
                                        //   See §5.3.1 for emitter shapes.
  "static_headers": { String -> String },
                                        // optional literal non-secret headers.
                                        //   See §5.3.2.
  "proxy": String | null,               // optional explicit proxy URL
                                        //   (overrides HTTPS_PROXY env var)
  "handshake_timeout_ms": Int,          // default 10000
  "request_timeout_ms": Int,            // default 30000 (per tools/call)
  "max_response_bytes": Int,            // default 2097152 (2 MiB)
  "connect_timeout_ms": Int,            // default 5000
  "pool_size": Int,                     // default 4 (concurrent in-flight)
  "allow_insecure_http": Bool,          // default false
  "allow_insecure_auth": Bool,          // default false; only honored when
                                        //   allow_insecure_http is also true
  "backoff_initial_ms": Int,            // default 100
  "backoff_max_ms": Int                 // default 30000
}
```

**No dynamic `headers:` field.** The codex-1 draft included a
`headers: { String -> String }` block that allowed `${VAR}` expansion.
That shape was removed: the existing config loader recursively resolves
`${VAR}` placeholders before normalization
(`mcp_server/lib/ptc_runner_mcp/application.ex:401`), so a value like
`"Authorization": "Bearer ${TOKEN}"` would land the raw token in the
upstream config map and propagate through `Connection.config` /
`snapshot/1` / any `inspect/2` of state. That is exactly the leak path
the credentials registry is supposed to close.

v1 has two header channels:

1. **Secret or auth-bearing headers** flow through `auth:` emitters and
   are produced by `Credentials.apply/2`.
2. **Literal non-secret headers** flow through `static_headers:` (§5.3.2).

The User-Agent is always set by the impl per §6.1.1 and is not
configurable in v1.

#### 5.3.1 `auth:` is an ordered list of emitters

`auth:` is a (possibly empty) list of emitters; each emitter
produces exactly one HTTP request header at request time. **Duplicate
header names are rejected at config-load** (`Authorization` shows up
twice, or two `custom_header` emitters both target `X-Trace-ID`). HTTP
allows duplicate-name headers but Streamable HTTP servers treat them
inconsistently; rejecting at config-load is loud and unambiguous,
preventable footgun. (This resolves OQ-2 — see §15.)

Three schemes in v1, all reference a binding:

```
// Bearer token → Authorization: Bearer <value>
{ "scheme": "bearer", "binding": "<binding-name>" }

// HTTP Basic → Authorization: Basic base64(user:pass)
{ "scheme": "basic", "binding": "<binding-name>" }

// Custom header (e.g., x-api-key, x-tenant) → <header>: <value>
{ "scheme": "custom_header",
  "binding": "<binding-name>",
  "header": "x-api-key" }                // header name to send the value as
```

For `bearer`, the binding **MUST** resolve to a non-empty string. For
`basic`, the binding **MUST** resolve to either a `user:pass` colon-
separated string or a `{ "user": "...", "pass": "..." }` JSON map (see
§7.2). For `custom_header`, the binding **MUST** resolve to a string
sent verbatim as the header value; the `header` field name **MUST**
match `^[A-Za-z0-9!#$%&'*+\-.^_`|~]+$` (RFC 7230 token grammar) and
**MUST NOT** be `Authorization` (use `bearer`/`basic` schemes
instead — config-load error if violated).

If `auth: []` or `auth: null`, the HTTP upstream sends no auth
headers — useful for upstreams behind a network boundary that
requires no per-request auth.

#### 5.3.2 `static_headers:` literal non-secret headers

`static_headers:` is an optional map of literal HTTP header names to
literal string values. It exists for headers such as `X-MCP-Readonly:
true`, `X-MCP-Toolsets: context`, `X-Tenant`, or `X-Trace-ID` that
are required by real remote MCP servers but are not secrets.

Rules:

- Values are **never** `${VAR}`-expanded. The HTTP config loader MUST
  parse `static_headers:` only after bypassing the legacy recursive
  placeholder resolver used for stdio `env` (§14.2).
- Header names MUST match the same RFC 7230 token grammar as
  `custom_header`.
- Header names MUST NOT be any sensitive name in this case-insensitive
  denylist: `Authorization`, `Proxy-Authorization`, `Cookie`,
  `Set-Cookie`, `X-Api-Key`, `X-API-Key`.
- Header names MUST NOT duplicate any name emitted by `auth:`.
- Header values MUST be strings and are sent verbatim.
- Static header values are **not** inserted into the redaction set.

Operators who need a secret-bearing custom header use
`auth: [{ "scheme": "custom_header", ... }]`, not `static_headers:`.

#### 5.3.3 Proxy resolution

If `proxy:` is set on the upstream entry, the HTTP impl passes it to
`Req` as `connect_options: [proxy: parse(proxy_url)]`. The URL
**MUST** be `http://host:port` or `https://host:port`; v1 does not
support proxy auth (`http://user:pass@host` syntax) — operators who
need authenticated proxies set them via OS-level mechanisms (e.g.,
local socks-proxy) and point `proxy:` at the unauthenticated
endpoint.

If `proxy:` is unset, the impl makes the request directly. **v1 does
not consult `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY` environment
variables.** This is intentional: the underlying `Req` / `Finch` /
`Mint` stack does not auto-resolve them either, so any env-var
behavior would be PtcRunner-specific re-implementation that is out of
scope for v1. Operators set `proxy:` explicitly per upstream. v1.1
may add env-var translation if the demand warrants it.

### 5.4 Binding spec (new)

v1 ships three sources. `exec` is deferred to v1.1 per §3
(`allow_exec_bindings: true` server-level flag will gate it).

```
// Source: env var
{ "source": "env", "var": "GITHUB_PAT" }

// Source: file (file contents, trimmed of trailing whitespace)
{ "source": "file", "path": "/path/to/secret" }

// Source: literal (loud warning outside :test — see §5.4.1)
{ "source": "literal", "value": "..." }
```

The materialization shape is `%{raw, scheme_hint, expires_at}`
(full spec in §7.2). `raw` is **always** the resolved bytes verbatim
— scheme-specific shaping (parsing `user:pass` for Basic,
base64-encoding, building `Authorization: Bearer …`) happens in
`Credentials.apply/2` (§7.3). For each consuming auth scheme:

- **`bearer`** and **`custom_header`** — the binding's `raw` is sent
  as the token / header value. No further parsing.
- **`basic`** — the binding's `raw` is parsed by `apply/2` per §7.3:
  it accepts either a colon-separated `user:pass` string (split on
  the first `:`) or a JSON-shaped binary that decodes to
  `{"user": "...", "pass": "..."}` (auto-detected by leading `{`).
  Either source shape is acceptable; the binding spec stays simple.

#### 5.4.1 Resolution semantics

- **`env`** — `System.get_env(var)` at materialization time. Missing
  env var → `{:error, :resolution_failed, detail}`. **Re-resolved on
  every `materialize/1` call** (no in-process cache); the env var is
  the authoritative source. Empty string is treated as missing and
  fails resolution.
- **`file`** — `File.read/1` + `String.trim_trailing/1` at
  materialization time. v1 does **not** cache file bindings; the file
  is the authoritative source and rotation is picked up on the next
  request / cold start. File mode **MUST** be readable by the PtcRunner
  process; v1 does not enforce permission checks (e.g., 0600) but logs
  at info level if `mode & 0o077 != 0` so operators notice
  world-readable secrets.
- **`literal`** — value used verbatim. **Loud `Logger.warning` at
  config-load time** if `MIX_ENV != :test`, because shipping a
  literal secret in a config file is a known footgun. The warning
  includes the binding name (never the value).

#### 5.4.2 Common fields

All binding shapes accept:

```
{ ...,
  "scheme_hint": "bearer" | "basic" | "raw" }   // optional sanity check
```

`scheme_hint`, when set, **MUST** match the auth scheme the binding is
referenced from; mismatch is a config-load error. Lets operators catch
"used the wrong binding for an upstream" mistakes statically. `raw`
matches `custom_header` (the binding's value is sent verbatim as the
header value).

### 5.5 Validation at config load

`PtcRunnerMcp.Application` extends its config loader with these checks
**before** the supervision tree starts. Failure raises with a
descriptive message:

1. Every binding referenced from any `auth:` emitter **MUST** exist
   in `credentials:`. Unknown binding → loud failure.
2. `transport: "http"` **MUST** be paired with a non-empty `url`
   starting with `https://` (or `http://` if `allow_insecure_http`
   AND, if any `auth:` emitters are configured, `allow_insecure_auth`).
3. `:req` **MUST** be loaded if any HTTP upstream is configured (§4.5).
4. `literal` bindings outside `MIX_ENV: :test` emit a `Logger.warning`
   each (not a failure — useful for local development).
5. Self-as-upstream rejection (§5.3 of the aggregator spec) continues
   to apply to stdio entries only.
6. The legacy `${VAR}` placeholder resolver **MUST** run only for
   stdio `env` values. HTTP `url`, `auth`, `static_headers`, `proxy`,
   and `credentials` fields are not placeholder-expanded.
7. Every `auth:` emitter's `binding` is checked at three distinct
   moments. Each moment has different failure semantics:
   - **Config-load type-shape check (loud failure).** The binding's
     declared `scheme_hint` (or, if unset, `:raw`) **MUST** be
     compatible with the consuming emitter's `scheme`: `:bearer`
     bindings only feed bearer emitters; `:basic` only feeds basic;
     `:raw` feeds any. Mismatch raises at config load.
   - **Boot-time materialization (soft failure).** `materialize/1`
     is invoked at boot per §4.3. Source failure (env var missing,
     file unreadable) → upstream renders as "(unavailable at
     startup)", backoff arms, boot proceeds. `materialize/1` does
     **not** inspect `raw` for any scheme-specific shape.
   - **Request-time `apply/2` shaping (per-request world-fault).**
     `apply/2` may return `{:error, :unencodable, …}` if `raw` has
     a malformed shape for the consuming scheme — the only case in
     v1 is a `basic` emitter whose `raw` lacks both `:` and a JSON
     `{user, pass}` shape. The HTTP impl treats this exactly like a
     401/403: returns `nil` to the program, records
     `status: "error"`, `reason: "upstream_unavailable"`, `error: "auth_failed"`
     in `upstream_calls`, and exits the impl with `:auth_failed`
     reason so the existing recovery-backoff path runs (§6.3 / §4.3.1).
     Note that the impl's `:auth_failed` exit reason is the same for
     "HTTP server returned 401" and "local apply/2 returned
     :unencodable" — both are credential problems from the program's
     perspective, both surface identically. The detail string in
     logs distinguishes the two cases for operators.
8. `auth:` emitter `header:` field on `custom_header` scheme **MUST**
   match the RFC 7230 token grammar and **MUST NOT** be `Authorization`
   (case-insensitive). Use `bearer`/`basic` schemes for the
   Authorization header.
9. `static_headers:` names **MUST** pass §5.3.2 validation, including
   the sensitive-name denylist and duplicate-header rejection against
   `auth:` emitters.
10. `proxy:` URL **MUST** parse as a valid HTTP/HTTPS URL if set.
11. `exec` source in any binding **MUST** raise a config-load error in
   v1 (the source name is reserved; v1.1 will gate behind
   `allow_exec_bindings: true`).

## 6. Streamable HTTP Transport

### 6.1 Wire shape and protocol version

v1 targets **MCP spec revision 2025-06-18**, the first revision to
define the `MCP-Protocol-Version` request header (added in 2025-06-18;
not present in 2025-03-26 — the codex-1 draft incorrectly attributed
this header to 2025-03-26). MCP has since shipped revision 2025-11-25
which **changes auth flows** (OAuth metadata discovery / dynamic
registration deltas — relevant for v2's auth work but not v1) **and
adds Streamable HTTP clarifications** (including SSE
polling/resumption semantics that this v1 plan would currently treat
as `stream_closed_before_response`). v1 does not target 2025-11-25
because we have not audited the deltas in detail; bumping target is
**not** as simple as changing the version-header string. Operators
who need 2025-11-25 wait for v1.x or supply a patch.

The wire *shape* this v1 plan describes (one endpoint serving POST,
optional `Mcp-Session-Id`, POST responses as `application/json` or
`text/event-stream`, `MCP-Protocol-Version` header on post-handshake
requests) holds across 2025-06-18 and 2025-11-25 at the framing level;
the operative deltas are at the auth-flow and SSE-resumption layers,
neither of which v1 implements anyway.

The Streamable HTTP transport defines one HTTP endpoint serving:

- `POST <url>` — client sends a JSON-RPC request, response, or
  notification. The server responds with:
  - `200 OK` + `application/json` for a request response (one-shot);
  - `200 OK` + `text/event-stream` for a streamed response, where the
    stream contains one or more SSE events whose `data:` lines are
    JSON-RPC messages and whose terminating event carries the request
    response. 2025-06-18 emits one message per event; v1 also accepts
    legacy array-form payloads from servers that negotiate/accept
    2025-06-18 but still emit pre-2025-06-18 framing (see §6.4.1);
  - `202 Accepted` with no body when the POST carried only
    notifications and/or responses (no requests requiring a reply).
  - `4xx`/`5xx` per §6.4.
- `GET <url>` — long-lived SSE stream for server-initiated
  notifications. v1 **does not subscribe** (§3 non-goal).
- `DELETE <url>` — explicit session termination. v1 issues this on
  `Upstream.Http.stop/1`, best-effort (a 404 / connection-refused is
  ignored — we are tearing down anyway).

#### 6.1.1 Required headers (client → server)

Every `POST` MUST include:

- `Content-Type: application/json`
- `Accept: application/json, text/event-stream`
- `MCP-Protocol-Version: <negotiated-version>` — included on every
  request AFTER the `initialize` exchange completes. **MUST be omitted
  on the `initialize` request itself** per the 2025-06-18 spec (the
  version is negotiated by the initialize request body). v1 supports
  only `"2025-06-18"`; if the server negotiates a different version,
  the handshake fails unless that version has been explicitly added to
  the supported-version list in code and tests. The impl tracks whether
  handshake has completed and conditionally adds the header.
- `Mcp-Session-Id: <id>` — required after `initialize` returns one;
  absent on the `initialize` request itself.
- `User-Agent: ptc-runner-mcp/<version>` — set by the impl, not
  configurable in v1.
- Auth headers as produced by `Credentials.apply/2` from the upstream's
  `auth:` emitter list (§5.3.1). May produce zero headers (`auth: []`),
  one (single emitter), or many (list of emitters).
- Static headers from `static_headers:` (§5.3.2), after duplicate-name
  validation against auth headers.

The `initialize` request body **MUST** carry
`"protocolVersion": "2025-06-18"`. If the server replies with a
different `protocolVersion`, v1 treats that as an unsupported
negotiated version and the handshake fails. This is intentionally
stricter than "log and proceed": sending a post-handshake
`MCP-Protocol-Version` header that differs from the negotiated version
is a protocol bug.

#### 6.1.2 Headers (server → client)

The handshake response MAY include:

- `Mcp-Session-Id: <id>` — when present, the impl **MUST** echo it on
  every subsequent request. Absence is allowed (stateless server) and
  the impl proceeds without one. Session ID is opaque; v1 stores it
  verbatim.
- `MCP-Protocol-Version: <version>` — confirms the negotiated version.
  v1 logs and proceeds (see above).

### 6.2 Handshake

The handshake order is the same as stdio (§6.3 invariant of the
aggregator spec): `initialize` → `notifications/initialized` →
`tools/list`. Over Streamable HTTP this is three POSTs.

```
1. POST <url> { "method": "initialize", ... } → 200 OK,
                    response { result: {...} }
   - `MCP-Protocol-Version` header is OMITTED on this request
     (§6.1.1). Capture `Mcp-Session-Id` from response headers (if
     present).
2. POST <url> { "method": "notifications/initialized" }
   - JSON-RPC notifications carry no id. Per the 2025-06-18 spec, a
     POST whose body contains only notifications and/or responses
     (no requests requiring a reply) MUST return **`202 Accepted`
     with no body**. The impl rejects any other status as a handshake
     failure.
3. POST <url> { "method": "tools/list", ... } → 200 OK,
                    response { result: {tools: [...]} }
```

`start_link/2` **MUST** complete all three before returning `:ok`,
or return `{:error, :upstream_unavailable, detail}` per the behaviour
contract.

### 6.3 Session loss → impl exits abnormally

When the server returns HTTP 404 to a request carrying our held
`Mcp-Session-Id`, the impl **MUST**:

1. Reply to the in-flight caller with
   `{:error, :upstream_unavailable, "session_lost"}`.
2. `{:stop, :session_lost, state}` itself.

The owning `Connection`'s monitor fires, `abnormal_exit?(:session_lost)`
returns `true`, and the existing §4.3 recovery path runs: invalidate
`cached_tools`, transition to `:not_started`, arm backoff. The next
`(tool/mcp-call …)` cold-starts a fresh impl with a fresh handshake
and a fresh `tools/list` cache.

The codex-1 draft proposed in-place re-init; that path was rejected
because (a) it cannot invalidate `Connection.cached_tools` on a
*successful* call without a new side channel through the Connection
GenServer, and (b) it silently desynchronizes the impl's tools list
from `Connection.cached_tools`. See §4.3.1 for the full reasoning.

The three-class failure model holds: the LLM sees `nil` (world-fault),
`upstream_calls` records `status: "error"`, `reason: "upstream_unavailable"`,
`error: "session_lost"` per §9.2.

### 6.4 Response handling

For each POST, the impl maps the HTTP status + body shape to the
behaviour contract's `{:ok, json}` / `{:error, reason, detail}` per
the table below. **All upstream-side rejections are world-fault per
base spec §7.1** (return `nil`, record `status: "error"` in
`upstream_calls`); programmer-fault is reserved for the three classes
already enumerated in base spec §7.2 (unknown server / unknown tool /
unencodable args), which the executor classifies *before* the HTTP
request is issued.

| HTTP status | Body shape | Behaviour return | `upstream_calls.reason` |
|---|---|---|---|
| 200 | `application/json` JSON-RPC response with `result` | `{:ok, result}` | (success) |
| 200 | `application/json` JSON-RPC response with `error` | `{:error, :upstream_error, formatted}` | `upstream_error` (world-fault per base §7.1) |
| 200 | `text/event-stream` (see below) | as decoded from SSE | as decoded |
| 202 | empty (notification-only POST) | `:ok` (handshake step 2 only) | n/a |
| 401 / 403 | any | `{:error, :upstream_unavailable, "auth_failed"}` then exit `:auth_failed` | `upstream_unavailable` |
| 404 | with stale `Mcp-Session-Id` (§6.3) | `{:error, :upstream_unavailable, "session_lost"}` then exit `:session_lost` | `upstream_unavailable` |
| 4xx other | `application/json` JSON-RPC error | `{:error, :upstream_error, formatted}` | `upstream_error` (world-fault) |
| 4xx other | not JSON-RPC | `{:error, :upstream_unavailable, "http <status>"}` | `upstream_unavailable` |
| 429 | any | `{:error, :upstream_unavailable, "rate_limited"}` | `upstream_unavailable` |
| 5xx | any | `{:error, :upstream_unavailable, "http <status>"}` | `upstream_unavailable` |
| TLS error | n/a | `{:error, :upstream_unavailable, "tls: <detail>"}` | `upstream_unavailable` |
| Network error / connect timeout | n/a | `{:error, :upstream_unavailable, "<detail>"}` | `upstream_unavailable` |
| Read timeout | n/a | `{:error, :timeout, "http read timeout"}` | `timeout` |
| Response body > cap | n/a | `{:error, :response_too_large, "<detail>"}` | `response_too_large` |

**Crucially**: HTTP 4xx with a JSON-RPC error body maps to
`:upstream_error` (world-fault), not to a programmer-fault raise.
This is the same rule as §7.1 row 2 of the base spec ("upstream
returned a JSON-RPC error to a `tools/call`"), unchanged. The
codex-1 draft incorrectly classified this as programmer-fault — the
base spec was always world-fault. The PTC-Lisp program sees `nil`
and the LLM's `(when result …)` / `(remove nil? results)` idiom
covers transient remote failure.

#### 6.4.1 SSE response decoding

A `200 OK` + `text/event-stream` response carries one or more SSE
events, each with `data: <json-rpc>` lines. **2025-06-18 removed
JSON-RPC batching**, so a 2025-06-18-conformant server emits one
JSON-RPC message per SSE event's `data:` payload. v1 also accepts
**array-form payloads as a compatibility path** for legacy or
nonconforming servers that negotiate/accept 2025-06-18 but still emit
pre-2025-06-18 framing — see OQ-9. The decode procedure:

1. Parse each event's `data:` payload as JSON.
2. **2025-06-18 path (default).** If the parsed value is an object,
   treat it as one JSON-RPC message.
3. **Backward-compat path.** If the parsed value is an array, iterate
   and treat each element as one JSON-RPC message. Telemetry SHOULD
   record this (counter `sse_array_compat_count`) so operators
   notice when an upstream is using legacy SSE framing.
4. For each message: if it is the response to the in-flight request id,
   complete the call. If it is a notification or a different request,
   **drop** it (v1 does not consume server-pushed notifications).
5. If the stream terminates (server closes) **before** a response with
   the in-flight id arrives, return
   `{:error, :upstream_unavailable, "stream_closed_before_response"}`.
   (2025-11-25 adds SSE polling/resumption that would change this; v1
   does not implement resumption — see §6.1.)

`:max_response_bytes` enforcement applies to the **cumulative** bytes
read from the SSE stream, not per-event. Once the cap is hit the impl
cancels the stream and returns `:response_too_large`. This matches the
NDJSON pre-decode cap behavior in `Upstream.Stdio`.

`:max_response_bytes` enforcement is pre-decode: the HTTP layer
streams response bytes into a counted buffer; once the cap is hit the
impl cancels the response and returns `{:error, :response_too_large,
detail}`. This is the HTTP analog of the NDJSON pre-decode cap in
`Upstream.Stdio`.

### 6.5 Connection pooling

Each `Upstream.Http` impl starts and owns a dedicated named Finch
process, for example `PtcRunnerMcp.Upstream.Http.Finch.<safe_name>`,
with pool options derived from that upstream's `pool_size`. Requests
MUST pass `finch: <that-name>` to Req. This avoids Req's auto-started
global Finch pool, which the Req docs note is not automatically
terminated, and guarantees two upstream entries pointing at the same
host do not accidentally share pool configuration.

Pool exhaustion → callers queue with deadline
`min(request_timeout_ms, call_opts[:timeout])`; queue timeout returns
`{:error, :timeout, ...}`. On `Upstream.Http.stop/1` and impl
termination, the owned Finch process is stopped best-effort before the
impl exits. If implementation chooses a shared supervised Finch
instead, it MUST document that choice and prove per-upstream
`pool_size`, proxy, and transport options do not bleed across upstream
names.

## 7. Credentials Registry

### 7.1 Process tree

```
PtcRunnerMcp.Application (Supervisor, :rest_for_one)
├── PtcRunnerMcp.Credentials       (1) singleton GenServer
├── PtcRunnerMcp.ConcurrencyGate   (2) ...
├── PtcRunnerMcp.Upstream.Supervisor (3) ...
├── ...
```

`Credentials` boots **before** the upstream supervisor (`:rest_for_one`
ordering). An HTTP upstream's `start_link/2` calls
`Credentials.materialize/1` synchronously during its handshake; that
call cannot succeed before `Credentials` is registered.

This is an intentional change from the current top-level
`PtcRunnerMcp.Application` strategy (`:one_for_one` at
`mcp_server/lib/ptc_runner_mcp/application.ex:54`). A Credentials
crash deletes the named ETS redaction table because the table is owned
by that process. Restarting later children forces HTTP upstreams to
re-handshake and re-materialize bindings, rebuilding redaction coverage
before new authenticated requests are sent. If implementation chooses
not to change the top-level strategy, it MUST instead add an explicit
credential-generation / redaction-table recovery mechanism and prove
running HTTP impls cannot continue emitting values whose redaction set
was lost.

Application config loading changes shape from "return upstream list" to
"return parsed aggregator config": `%{upstreams: entries, credentials:
bindings}`. `Credentials` is started whenever the parsed config includes
a `credentials:` block or any HTTP upstream, including the stdio-only
Phase 1 case used to test non-disruptive boot. The upstream supervisor
still starts only when `upstreams` is non-empty, preserving
`:mcp_no_tools` mode.

### 7.2 Binding resolution

```elixir
defmodule PtcRunnerMcp.Credentials.Binding do
  @type source :: :env | :file | :literal | :exec
  @type t :: %{
          name: String.t(),
          source: source(),
          scheme_hint: :bearer | :basic | :raw | nil,
          spec: map()           # source-specific fields (var, path, command, ...)
        }
end
```

`Credentials.materialize(name)` resolves the source per §5.4.1 and
returns:

```elixir
{:ok, %{
   raw: binary(),                     # the resolved bytes, verbatim
   scheme_hint: :bearer | :basic | :raw,
                                      # echoes scheme_hint from binding spec
                                      # (§5.4.2), or :raw if unset
   expires_at: integer() | :never     # monotonic ms, or :never
 }}
```

`materialize/1` is **scheme-agnostic at the source layer**. It always
returns the resolved bytes verbatim. Scheme-specific shaping
(parsing `user:pass` for Basic, base64-encoding, building the
`Authorization: Bearer` header) happens in `apply/2`, which has
visibility into the auth emitter's scheme. This decoupling means
the same `file` source can back a Basic binding (file contents
shaped `user:pass`) or a bearer binding (file contents are the bare
token), without `materialize/1` having to know which.

The codex-1 draft conflated source-layer resolution with scheme-
specific shaping (proposed `material: %{user, pass}` for Basic), which
forced `materialize/1` to know the consuming auth scheme — knowledge
it doesn't have. This revision splits the responsibilities cleanly.

### 7.3 `Credentials.apply/2`

```elixir
defmodule PtcRunnerMcp.Credentials.RedactedHeaders do
  @type t :: %__MODULE__{headers: [{String.t(), String.t()}]}
  defstruct [:headers]
end

@spec apply(materialization :: %{raw: binary(), scheme_hint: atom(),
                                  expires_at: integer() | :never},
            emitter :: %{scheme: :bearer | :basic | :custom_header,
                          binding: String.t(),
                          header: String.t() | nil}) ::
        {:ok, PtcRunnerMcp.Credentials.RedactedHeaders.t()}
        | {:error, :scheme_mismatch | :unencodable, String.t()}
```

`apply/2` is the only call site that converts the resolved bytes into
HTTP header bytes. It takes:

1. The full materialization result from `materialize/1`.
2. The auth emitter spec (which carries the consuming `scheme`).

Per-scheme behavior:

- **`bearer`** — produces `[{"authorization", "Bearer " <> raw}]`.
- **`custom_header`** — produces `[{emitter.header, raw}]`.
- **`basic`** — accepts `raw` as either:
  - a `user:pass` colon-separated string (split on first `:`); or
  - a JSON-shaped binary that decodes to `{"user": "...", "pass": "..."}`
    (auto-detected by leading `{`).
  Produces `[{"authorization", "Basic " <> Base.encode64(user <> ":" <> pass)}]`.
  A `raw` that doesn't conform to either shape returns
  `{:error, :unencodable, "basic_shape_invalid"}` (the canonical
  detail string used across §5.5 #7 third bullet, §6.4, and the
  `upstream_calls` `error` field).

`scheme_hint` enforcement: if the materialization's `scheme_hint` is
set (from the binding spec) and does **not** match `emitter.scheme`,
`apply/2` returns `{:error, :scheme_mismatch, detail}`. `:raw` matches
any scheme. This is the runtime check; the config-load validator
performs the same check statically per §5.5 #7.

The result is wrapped in a small struct (for example
`%Credentials.RedactedHeaders{headers: [...]}`) whose `Inspect`
implementation renders only `#Credentials.RedactedHeaders<[REDACTED]>`.
`Upstream.Http`'s request layer is the only consumer that unwraps it to
splice headers into the outbound `Req` request. A plain tagged tuple is
not sufficient here: `inspect({:redacted_headers, headers})` would still
print the inner list.

The header bytes are **not** held on `Upstream.Http` Connection
GenServer state across requests in v1. Each request:

1. Calls `Credentials.materialize(binding)` for each emitter
   (registry lookup plus source read).
2. Calls `Credentials.apply/2` for each emitter to produce a
   `%Credentials.RedactedHeaders{}` wrapper.
3. Splices each emitter's headers into the `Req` request struct,
   in emitter order.
4. Drops its local reference to all materializations and header lists
   once the request returns.

For a 2-emitter upstream (e.g., bearer + custom_header), this is
2 `materialize/1` calls + 2 `apply/2` calls + 2 header lists spliced
into the request, in order.

(v2 may add per-Connection caching with TTL `auth_cache_ttl_ms`. v1
re-derives on every request to keep the structural-isolation
guarantee tight.)

### 7.4 Refresh and cache invalidation

v1 has no credential value cache. `env` and `file` sources are
re-resolved on every `materialize/1` call; `literal` is read from the
parsed binding spec. This keeps rotation semantics simple: changing an
environment variable inside the BEAM process or replacing a file is
picked up by the next request / cold start without a `refresh/1` API or
TTL boundary.

The redaction set still accumulates every materialized value for the
server lifetime (§7.5), so old rotated secrets remain redacted if they
appear in later logs or traces.

### 7.5 Redaction set and redactor filter

The redaction set is an ETS table **owned by the `Credentials`
GenServer**, with **owner-only writes and global-process reads** (ETS
`:protected` access). It is populated the **first time** each binding
is materialized in this server's lifetime. Schema:

```
:ets.new(:credentials_redaction_set,
         [:set, :protected, :named_table, read_concurrency: true])
```

ETS access semantics (Erlang docs): `:protected` = the owning process
can read and write; **all other BEAM processes can read but not
write**. This is exactly what we need: the redactor filter
(`Log` / `TraceFile` / `UpstreamCalls` writers in arbitrary worker
processes) must read the set to substring-match; only the
`Credentials` GenServer is allowed to insert resolved bytes. `:public`
would let any process insert (and a buggy or malicious process could
register false positives, causing `[REDACTED]` to replace innocent
substrings). `:private` would prevent the cross-process readers from
working at all. The codex-1 draft called this "process-private" —
that wording suggested `:private` and was wrong; this revision uses
"owner-write, globally-readable by BEAM processes" which is what
`:protected` actually means.
- The table holds **plaintext bytes** (not SHA-256 hashes). The
  codex-1 draft proposed hashing — that idea was wrong: substring-
  matching a log line against `SHA-256("secret123")` does not detect
  the substring `"secret123"` in the log line. To actually redact you
  must either (a) substring-match plaintext, or (b) hash every
  candidate substring of every log line, which is O(n²) and absurd.
  v1 picks (a).

#### 7.5.1 `Credentials.Redactor.scrub/1`

```elixir
@spec scrub(String.t()) :: String.t()
```

Walks the table once per call, substring-replacing every plaintext
secret with `[REDACTED]`. Linear in `secrets × len(input)`; secrets
table is small (one entry per binding × rotations). The filter is
hooked into:

- `PtcRunnerMcp.Log` — every `Log.log/3` call routes formatted
  message through `scrub/1` before emitting.
- `PtcRunnerMcp.TraceFile` / `TracePayload` — every JSONL record's
  encoded JSON is `scrub/1`-ed before write.
- `PtcRunnerMcp.UpstreamCalls` — `error` and `args_truncated` fields
  are `scrub/1`-ed at record-construction time (not at envelope-emit
  time, so the truncated args themselves are scrubbed before they
  ever reach the structured response payload).
- The MCP request handler's `validation_error` detail string —
  `scrub/1`-ed before the JSON-RPC response is serialized.

#### 7.5.2 First-emission race

A small race exists: between handshake-time `materialize/1` and the
first registration into the redaction set, the scrub filter does not
know about the new value yet. The `Credentials` GenServer **MUST**
register the value into ETS *before* returning from `materialize/1`,
so any caller that has the value also has guaranteed-already-
registered redaction coverage. This closes the race for the
in-process flow. Across-process secrecy (no other BEAM node holds
the value) is out of scope — v1 does not run multi-node.

#### 7.5.3 Limits of the redactor

The redactor is **defense in depth**. The primary guarantee is
structural:

(a) Resolved values are not stored in upstream config maps, Connection
    snapshots, trace payloads, or `upstream_calls` entries. They exist
    only in Credentials state/materialization paths, the redaction-set
    ETS table, transient HTTP header construction variables, and the
    in-flight `Req` / Finch request.
(b) Only `Upstream.Http`'s request layer destructures
    `%Credentials.RedactedHeaders{...}`.
(c) HTTP upstream config has no field that accepts a raw secret —
    `auth:` references bindings; `static_headers:` is literal-only and
    rejects sensitive header names; the removed dynamic `headers:` field
    closed the path that would have allowed
    `Authorization: Bearer ${TOKEN}` in config (§5.3 explanation).

The redactor catches code paths that violate (b) by accidentally
inspecting state, plus partial-token leak shapes ("Bearer " prefix +
half the token in a truncated string). The redactor does **not**
catch:

- Secret values short enough that they collide with normal text
  ("token123" might appear in unrelated content and over-redact, or
  a two-character secret would corrupt logs). v1 does **not**
  enforce a minimum binding length. The codex-2 draft proposed an
  8-byte minimum but it composed badly with `env` / `file` sources
  whose value is unknown until materialization. Non-secret short
  header values should use `static_headers:` so they never enter the
  redaction set. Operators who care about substring-match safety pick
  longer secrets — entropic credentials are virtually always > 16
  bytes.
- Secrets logged before `Credentials` boots (impossible in practice;
  Credentials is in the supervision tree before Upstream.Supervisor).
- Disk reads that bypass `Log` / `TraceFile`. Operators who write
  custom telemetry handlers MUST run their formatted strings
  through `Credentials.Redactor.scrub/1`.

#### 7.5.4 `upstream_calls` records bindings, not values

The `upstream_calls` entry shape (§9.2) carries `auth: { scheme, binding }`
for HTTP upstreams. The binding is a *name* string (e.g.,
`"github-pat"`); the value is **never** included. This is independent
of the redactor — the collector simply does not build a record that
contains the value.

## 8. Error Model (delta from §7 of aggregator spec)

The three-class failure model from base spec §7 is preserved
**unchanged**: world-fault → `nil` + `status: "error"`; programmer-
fault → raise; the `:json-null` sentinel handles JSON null payloads.
This section enumerates the new HTTP-specific triggers and maps them
to existing reasons. **No new classes are introduced.** Programmer-
fault classes remain exactly the three from base spec §7.2 (unknown
server / unknown tool in known upstream / unencodable args), all
classified by the executor *before* the HTTP request is issued.

### 8.1 World-fault triggers added by HTTP transport

All map to existing reasons from base spec §7.1.

| Trigger | Reason | `error` example |
|---|---|---|
| Upstream returns JSON-RPC error body (any HTTP status that carries one) | `upstream_error` | `"<upstream error.message>"` |
| HTTP 5xx (no JSON-RPC body) | `upstream_unavailable` | `"http 503"` |
| HTTP 401/403 (after exit `:auth_failed`) | `upstream_unavailable` | `"auth_failed"` |
| HTTP 429 | `upstream_unavailable` | `"rate_limited"` |
| HTTP 4xx other (no JSON-RPC body) | `upstream_unavailable` | `"http 404"` |
| Session 404 with stale `Mcp-Session-Id` (after exit `:session_lost`) | `upstream_unavailable` | `"session_lost"` |
| Network error (econnrefused, nxdomain, etc.) | `upstream_unavailable` | `"econnrefused"` |
| Connect timeout | `upstream_unavailable` | `"connect_timeout"` |
| Read timeout | `timeout` | `"http read timeout"` |
| Response body > cap | `response_too_large` | `"http response 3145728 bytes exceeds max_response_bytes (2097152)"` |
| TLS cert / hostname / chain error | `upstream_unavailable` | `"tls: hostname mismatch"` |
| Streamable HTTP stream closed before response arrived | `upstream_unavailable` | `"stream_closed_before_response"` |

**HTTP 4xx with a JSON-RPC error body is `upstream_error`, not
programmer-fault.** This matches base spec §7.1 row 2 verbatim. Many
upstreams encode "wrong arg shape" as a JSON-RPC error in a 400 body;
treating that as world-fault keeps the existing LLM self-correction
loop working (LLM sees the JSON-RPC error message in
`upstream_calls[].error`, adjusts the program, retries on the next
turn). The codex-1 draft incorrectly classified this as programmer-
fault — that was a regression from the base spec.

### 8.2 Programmer-fault: unchanged

The programmer-fault classes from base spec §7.2 are unchanged. The
HTTP impl never raises. Config-time errors (unknown binding,
unloadable `:req`, malformed url, `auth:` referencing missing binding,
`exec` source in v1) are caught at boot per §5.5 and prevent the
upstream from starting; the run-time path never sees them.

### 8.3 Boot-time `:resolution_failed` rendering

When an HTTP upstream's eager-start handshake fails because
`Credentials.materialize/1` returned `{:error, :resolution_failed, …}`,
the upstream renders as "(unavailable at startup)" in the catalog
(§4.3). The next user-driven call may retry immediately, subject to
the existing per-program failure cache after one failed
`ensure_started/1` attempt in that program. The `upstream_unavailable`
reason is recorded with
detail `"resolution_failed: <binding-name>"` (the binding name is not
secret; the value would be, but resolution failed so there is no
value to leak).

## 9. Wire Format (delta from §8 of aggregator spec)

### 9.1 Tool advertisement (`tools/list` description)

The catalog rendering (§8.1 of the aggregator spec, implemented in
`mcp_server/lib/ptc_runner_mcp/upstream/catalog.ex`) gains one
optional per-server annotation: a `[transport: http|stdio]` tag in
the per-server header line. Useful for the LLM to know whether a
particular server is local-only or has network dependency, without
inflating the catalog meaningfully.

```
## github [transport: http]
search_repos(query: string, limit?: int) - Search repositories.
get_pr(owner: string, repo: string, number: int) - Fetch a pull request.
...
```

The rest of the description is unchanged.

### 9.2 `upstream_calls` entry shape — additive only

The base spec §8.5 entry shape uses `status` ("ok" | "error") +
`duration_ms` (required), plus `reason` and `error` (required iff
`status: "error"`). The current implementation
(`mcp_server/lib/ptc_runner_mcp/upstream_calls.ex:272`) emits exactly
that shape. **The codex-1 draft used `outcome`/`detail` which would
have broken every consumer of the existing shape — that was a real
backward-incompat regression.** This revision is **additive-only**:
all existing required and optional fields keep their names; HTTP-
specific fields are added as **optional** alongside.

New optional fields, present only when applicable:

| Field | Type | Present when |
|---|---|---|
| `auth` | object | upstream is HTTP and has at least one `auth:` emitter |
| `http_status` | integer | failure came from an HTTP response (status 4xx / 5xx / 429) |

The `auth` object shape:

```json
"auth": { "scheme": "bearer", "binding": "github-pat" }
```

For an upstream with multiple `auth:` emitters (e.g., bearer +
custom_header), `auth` is the first emitter. v1 keeps this simple;
v2 may switch to a list if multi-emitter audit becomes important.

Full HTTP-failure entry, conformant to base §8.5 with new fields
spliced in:

```json
{
  "server": "github",
  "tool": "search_repos",
  "status": "error",
  "duration_ms": 1843,
  "reason": "upstream_unavailable",
  "error": "http 503",
  "http_status": 503,
  "auth": { "scheme": "bearer", "binding": "github-pat" }
}
```

Full HTTP-success entry:

```json
{
  "server": "github",
  "tool": "search_repos",
  "status": "ok",
  "duration_ms": 420,
  "auth": { "scheme": "bearer", "binding": "github-pat" }
}
```

Stdio entries are byte-for-byte unchanged: no `auth`, no `http_status`.

### 9.3 `outputSchema` extension

Base spec §8.4 specifies that aggregator-mode `outputSchema` extends
the v1 schema with an optional `upstream_calls` array of objects
matching §8.5. The new optional fields (`auth`, `http_status`) are
added to that object schema, both as optional. Strict
`structuredContent` validators on the consumer side will accept the
HTTP-augmented entries as valid §8.5 records (the new fields are
unknown but optional).

## 10. Resource Limits (delta from §9 of aggregator spec)

The existing per-program limits (`max_upstream_calls_per_program`,
`upstream_call_timeout_ms`, `max_response_bytes`) apply unchanged to
HTTP upstreams. New HTTP-specific limits, configured per upstream:

- **`pool_size`** (default 4) — Finch pool size for this upstream.
- **`connect_timeout_ms`** (default 5000) — TCP+TLS connect deadline.
- **`request_timeout_ms`** (default 30000) — HTTP request-envelope
  deadline. Effective per-call deadline is
  `min(request_timeout_ms, call_opts[:timeout])`, so the program-level
  `upstream_call_timeout_ms` is never exceeded.

The credentials registry has no per-call cost worth limiting in v1
(env/file materialization is small, redaction is O(n) over a small set).

## 11. Telemetry (delta from §10 of aggregator spec)

New events, alongside the existing `[:ptc_runner_mcp, :upstream, :*]`
family:

- `[:ptc_runner_mcp, :upstream, :http, :request, :start | :stop]` —
  per-HTTP-request, with `%{name, jsonrpc_method, http_status, duration_ms}`
  (`http_status` set on `:stop` only; absent on transport-error stops).
  `jsonrpc_method` is the JSON-RPC method (e.g., `"tools/call"`); the
  HTTP method is always `POST`.
- `[:ptc_runner_mcp, :upstream, :http, :session_lost]` — fired when
  HTTP 404 with a stale `Mcp-Session-Id` triggers the impl's abnormal
  exit (§6.3 / §4.3.1). Metadata: `%{name, prior_session_id_hash}` —
  the prior session ID is hashed to avoid leaking it in telemetry.
- `[:ptc_runner_mcp, :credentials, :resolve, :start | :stop]` — per
  binding materialization, with `%{binding, source, duration_ms}`.
  **MUST NOT** include the resolved value.
- `[:ptc_runner_mcp, :credentials, :resolve, :error]` — fired on
  resolution failure, with `%{binding, source, reason}` (`reason` is a
  short atom like `:env_missing` / `:file_not_found`, not a detail
  string that might echo a path containing secrets).
- `[:ptc_runner_mcp, :credentials, :redactor, :scrubbed]` — sampled
  (1 in 1000) when `Credentials.Redactor.scrub/1` actually replaces a
  match. Useful in dev to confirm redaction is active without
  flooding telemetry. Production deployments may disable via the
  existing telemetry profile flag.

All event names follow the existing `[:ptc_runner_mcp, :upstream, …]`
prefix convention. The `:credentials` subtree is new but parallel to
the existing top-level subtrees (`:upstream`, `:program`, `:tools`).

## 12. Implementation Phases

### 12.0 Build orchestration

Phases run **sequentially** (each phase depends on artifacts from the
previous one). **Within a phase**, work is decomposed into independent
subagent streams that run in **parallel** where the spec permits.

**Subagent assignment.** All implementation work runs through the
`Engineer` subagent (TDD discipline, constitutional principles). Spec
clarifications during a phase route to the `Architect` subagent.
Codex reviews are invoked via `/codex` (skill: `codex` from
`memory/feedback_codex_review_gate.md`) — they are **hard gates** and
do not run via subagents.

**Parallelism rule.** Two streams may run in parallel only if neither
writes to a file the other reads. Each per-phase plan below tags
streams as `[P]` (parallel-safe) or `[S]` (sequential, blocks the
phase).

**Phase exit gates.** A phase is "done" only when **all four** clear:

1. **Spec conformance** — every §-numbered MUST in the relevant
   section is exercised by a test (annotated with the §-ref in a
   test-name comment).
2. **`mix precommit` clean** — format + compile (warnings-as-errors)
   + credo --strict + dialyzer + test, all green.
3. **Codex review pass** — `/codex review` against the phase diff
   returns no [P0]/[P1] findings. [P2] findings that the implementer
   judges out-of-scope are recorded in the phase's exit note with
   rationale; [P0]/[P1] block the phase.
4. **Human sign-off** — short summary written for the user
   (deliverables + diff size + codex outcome + open follow-ups).

**Codex review cadence.** One codex review at end of each phase
against the phase's diff. Mid-phase consult (`/codex consult`) is
allowed when an architectural fork emerges — record the consult
outcome in the phase's exit note.

**No-cross-phase-leak rule.** A phase MUST NOT introduce code that
only makes sense once a later phase ships. Phase 1's `Credentials`
registry is bootable on a stdio-only config and has zero callers
outside its own tests; Phase 2's `Upstream.Http` works against an
unauthenticated fixture; Phase 3 is the first phase where the two
halves wire together. This is a forcing function: each phase must
stand on its own under `mix test` against the codebase as it exists
at that phase's HEAD.

**Branching.** Per `memory/feedback_commit_directly.md`, phases land
on `main` directly (no feature branch). Each phase exit creates one
commit (or a tight series — credentials parser, registry GenServer,
redactor wiring as three commits inside Phase 1 is fine).

### Phase 1 — Credentials registry

**Scope.** Ship `PtcRunnerMcp.Credentials` + `Credentials.Binding` +
`Credentials.Redactor` against the existing stdio-only world.

**Subagent streams.**

- **1A [S]** — `Binding.parse/1` + binding type module
  (`mcp_server/lib/ptc_runner_mcp/credentials/binding.ex`). Pure
  functions; no GenServer. Blocks 1B and 1C.
- **1B [P]** — `Credentials` GenServer + ETS redaction set
  (`credentials.ex`). Depends on 1A's binding type. **Parallel with
  1C** once 1A lands.
- **1C [P]** — `Credentials.Redactor.scrub/1` + wire-up into `Log`,
  `TraceFile`, `TracePayload`, `UpstreamCalls`. Depends on 1A's type
  for table format; reads ETS table by name. **Parallel with 1B.**
- **1D [S]** — `Application` config-loader extension (parse
  `credentials:` block, validate `auth:` cross-references, narrow the
  legacy `${VAR}` resolver per §5.2 / §5.5 #6) **and** supervisor
  ordering (`Credentials` before `Upstream.Supervisor` via
  `:rest_for_one`). Blocks until 1A/1B/1C land; this is the
  integration step.
- **1E [P]** — Tests (one Engineer subagent per test file in the
  §13.1 list — `BindingTest`, `CredentialsTest`, `RedactorTest`,
  `LiteralWarningTest`, plus the boot-integration test). May start as
  soon as the file each test targets is at least skeleton-merged;
  each test author owns the failing-test → green-test cycle for
  their file.

**Codex gate.** End of phase: `/codex review` against the Phase 1
diff. **Focus prompt** to pass to codex:

> Review the credentials registry diff. Adversarial focus: (1) Is
> there any code path where a resolved binding value reaches a log,
> trace, or upstream_calls record without `Redactor.scrub/1` running
> first? Walk every `Log.log` / `TraceFile.write` / `UpstreamCalls`
> caller. (2) Is the ETS table mode actually `:protected`, and does
> the redaction set hold plaintext (not hashes — see §7.5)? (3) Does
> the supervisor ordering guarantee `Credentials` is registered
> before any consumer calls `materialize/1` (relevant when Phase 2
> lands; today no consumer exists, but the boot test must pass).
> (4) Does the `exec`-source rejection at config-load emit a
> "deferred to v1.1" message (not a generic "unknown source")?

**Note on standalone shippability.** Phase 1 ships infrastructure
(`Credentials` registry, `Binding` parser, `Redactor.scrub/1` filter
hooks). The redactor is wired into `Log` / `TraceFile` /
`UpstreamCalls` write paths; the registry is bootable; the
configuration loader recognizes the `credentials:` block. **But Phase
1 does not, by itself, redact any secrets in production**, because
the redaction set is populated only when bindings are *materialized*,
and the only consumer that materializes bindings is `Upstream.Http`
(Phase 2/3). v1's existing stdio `${VAR}` env-var resolution is
**not** auto-registered into the redaction set per §14.2 — operators
who want stdio env values redacted in v1.x add an explicit binding
that mirrors the env var (which the test suite can exercise but
production paths cannot until Phase 3 wires HTTP through).

The honest framing: **Phase 1 is build-order plumbing.** It lands
the contract and the wire-up so Phase 3 has a clean integration
target. The codex-1 draft overclaimed "Phase 1 redacts secrets in
flight" — that's only true once HTTP upstreams are materialized.
Shipping Phase 1 alone has zero user-visible effect.

**Deliverables.**

- `PtcRunnerMcp.Credentials` GenServer + ETS-backed redaction set
  (`:protected` mode — owner-write, globally-readable by BEAM
  processes; §7.5) holding
  plaintext bytes.
- `Binding.parse/1` for the v1 sources: `env`, `file`, `literal`.
  **`exec` source explicitly rejected at config-load** with a "v1.1
  deferral" error message; the source name is reserved.
- `Credentials.materialize/1` returning the §7.2 shape
  `{:ok, %{raw, scheme_hint, expires_at}} | {:error, …}`. **No `:scheme`
  / `:material` keys** — the source layer is scheme-agnostic.
- `Credentials.apply/2` returning `{:ok, %Credentials.RedactedHeaders{}}`,
  taking the full materialization plus the auth emitter spec
  (§7.3); does the Basic `user:pass` shaping internally so the source
  layer doesn't need to know.
- Application config-loader extension: parse `credentials:` block,
  validate `auth:` binding references against it (no stdio
  upstream has an `auth:` block in v1, but the cross-reference
  validator is implemented).
- Application supervisor ordering: `Credentials` GenServer starts
  before `Upstream.Supervisor` (`:rest_for_one`), so HTTP upstream
  boot in Phase 2/3 can call `materialize/1` synchronously during
  handshake without race.
- `Redactor.scrub/1` integration into `Log`, `TraceFile`,
  `TracePayload`, `UpstreamCalls`. Wire-up only in Phase 1 — no HTTP
  producers exist yet, but the filter is on the path so Phase 3 plug-in
  is a no-op.
- Tests:
  - Each v1 source's success and failure modes.
  - `literal` warning fires outside `:test`; warning includes binding
    name but never the value.
  - `exec` source rejected with the v1.1-deferral error message.
  - Application boot integration: a config with a `credentials:` block
    and stdio-only upstreams loads cleanly, supervisor ordering is
    correct (`Credentials` before `Upstream.Supervisor`), `Credentials`
    is callable from a synthetic test client during boot.
  - End-to-end redaction: a test that **really materializes** a
    binding via `materialize/1`, then writes a `Log.log/3` /
    `TraceFile` line / `UpstreamCalls` entry containing the resolved
    value, asserts the value is replaced with `[REDACTED]` in the
    output. (Not synthetic insertion into the ETS table — full
    materialize-to-scrub round trip.)
  - First-emission race: registration completes *before*
    `materialize/1` returns, asserted by checking ETS contents in
    the same call's continuation (a process that calls `materialize/1`
    then immediately reads the redaction-set ETS sees the value).
  - Stdio config unchanged: the existing real-filesystem-MCP
    integration test (`@tag :real_upstream`) continues to pass with
    `Credentials` boot-stage running. This proves the Phase 1 changes
    are non-disruptive to existing functionality.
  - Unknown binding reference at config load → loud error with
    binding name in the message.

**Codex review focus.** Redactor reach (every formatted-string
emission path goes through `scrub/1`), the SHA-256-vs-plaintext
discipline (no hashing crept back in), `exec`-deferral error message
(operators get a clear "v1.1 deferred" message, not a confusing
"unknown source" one).

### Phase 2 — HTTP transport, no auth

**Scope.** `Upstream.Http` against an unauthenticated MCP-over-HTTP
upstream. Validates the wire format and Connection-lifecycle
integration before adding auth.

**Subagent streams.**

- **2A [S]** — `:req` + `:bandit` Mix dep wiring + dep-presence
  failure-mode (§4.5). Blocks all other 2-phase work.
- **2B [P]** — `Upstream.Http.Transport` (Req-based POST wrapper +
  status-code → behaviour-return mapper per §6.4) and
  `Upstream.Http.Session` (handshake state, session-id capture,
  `MCP-Protocol-Version` header conditional, abnormal-exit-on-
  session-loss per §6.3 / §4.3.1). Two streams may run in parallel
  if each owns its own file; they meet at `Upstream.Http`.
- **2C [P]** — SSE response decoder (single-message form +
  array-form compat path per §6.4.1 / OQ-9, with cumulative
  `:max_response_bytes` enforcement). Independent of 2B if both
  publish a small interface module; otherwise 2C blocks on 2B's
  response-shape contract.
- **2D [S]** — `Upstream.Http` GenServer that owns its named Finch
  process and ties 2B + 2C + Connection-lifecycle integration
  together. Depends on 2B/2C.
- **2E [S]** — `Application` config-loader extension for
  `transport: "http"` parsing, `url` / `proxy` / `allow_insecure_*`
  validation (§5.5 ##2, 3, 6, 8, 9, 10, 11). Independent file but
  needs 2D's config-shape stabilized.
- **2F [P]** — `test/support/fake_mcp_http_server.ex` Plug fixture
  (configurable handshake / session-id / response-shape /
  inflate-for-too-large / header-introspection). Independent of 2D's
  internals. Can be developed against the spec's wire format alone.
- **2G [P]** — Tests per §13.2 (handshake matrix, session-loss DOWN
  path, pool exhaustion, `:response_too_large` cumulative cap,
  SSE single + array, 4xx-with-JSON-RPC-body world-fault,
  eager-start-503 catalog rendering). One Engineer per test file;
  each requires the fixture (2F) and the impl module they exercise.

**Codex gate.** End of phase: `/codex review` against Phase 2 diff.
**Focus prompt:**

> Review the HTTP transport diff. Adversarial focus: (1) Connection
> lifecycle — does session-loss-404 cleanly produce
> `{:stop, :session_lost}` and does `Connection.abnormal_exit?/1`
> fire backoff? Same for `:auth_failed` (used by Phase 3 — verify
> the wiring exists even if no caller produces it yet). (2) SSE
> decoding — is the cumulative `:max_response_bytes` enforced
> *pre-decode* per §6.4.1, and does the array-form compat path
> correctly select the in-flight request id while dropping
> notifications? (3) Status-code mapping — every row of the §6.4
> table has a test? In particular, 4xx with JSON-RPC body must map
> to `:upstream_error` (world-fault), not programmer-fault. (4) Are
> the named Finch process's lifetime bounds actually tied to the
> impl GenServer (no zombie pool on impl crash)? (5) Does the
> `MCP-Protocol-Version` header omission/inclusion match §6.1.1
> (omitted on initialize; required on every post-handshake POST)?

**Deliverables.**

- `:req` added as optional dep; `:bandit` added as test/dev dep for
  the local HTTP fixture.
- `PtcRunnerMcp.Upstream.Http` + `Upstream.Http.Session` +
  `Upstream.Http.Transport` modules.
- Config-loader: `transport: "http"` parsing, URL validation,
  `allow_insecure_http` / `allow_insecure_auth` gates,
  proxy URL validation.
- 2025-06-18 Streamable HTTP handshake (initialize without
  `MCP-Protocol-Version`; notifications/initialized expecting 202; then
  tools/list with `MCP-Protocol-Version: 2025-06-18`) over `Req`.
- Dedicated named Finch process per HTTP upstream, sized by
  `pool_size`, stopped with the impl.
- Session-id capture and echo (§6.1.2).
- Session-loss → `:stop, :session_lost` → existing Connection
  `:DOWN` path (§4.3.1).
- All §6.4 status-code mappings, including 4xx-with-JSON-RPC-body →
  `upstream_error` world-fault.
- SSE response decoding: single-message form (2025-06-18 default)
  plus array-form **compatibility path** for legacy/nonconforming
  servers per §6.4.1 / OQ-9.
- `max_response_bytes` cumulative cap on streamed responses.
- Tests:
  - `Upstream.Http` against a local Plug fixture server served by
    Bandit (`:bandit` test/dev dependency) that speaks the 2025-06-18
    wire format.
  - Handshake success / handshake-malformed-response / handshake-401.
  - 202 Accepted response to `notifications/initialized` (the codex-1
    draft accepted 200; revised spec rejects 200 here).
  - Session 404 mid-call → impl `:stop, :session_lost` → Connection
    invalidates `cached_tools`, transitions to `:not_started`, arms
    backoff. Next call cold-starts cleanly.
  - Pool exhaustion → queue + timeout.
  - Cumulative `:response_too_large` against an SSE stream that
    repeatedly pushes data without termination.
  - SSE single-message form: one event with `data:` carrying one
    JSON-RPC object → impl correlates to the request id and completes.
  - SSE array-form (compatibility path): one event
    with `data:` carrying a JSON array of multiple messages → impl
    extracts the one matching the in-flight request id, drops the rest,
    increments `sse_array_compat_count` telemetry counter.
  - 4xx with JSON-RPC error body → `upstream_error` world-fault →
    program sees `nil`, `upstream_calls` records the error.
  - Eager-start integration: HTTP upstream that 503s at boot
    renders as "(unavailable at startup)" in catalog; aggregator
    boots successfully.

**Codex review focus.** Connection lifecycle (DOWN handling,
backoff arming on `:session_lost` and `:auth_failed`), SSE
single-message + backward-compat array-form decoding, the precise
mapping of HTTP statuses to `upstream_calls.reason`.

### Phase 3 — Auth integration

**Scope.** Wire `Upstream.Http` to `Credentials`. Add `auth:` list
parsing, multi-emitter header construction, redaction of materialized
values, `:auth_failed` exit semantics.

**Subagent streams.**

- **3A [S]** — `Credentials.apply/2` (§7.3) + the
  `%Credentials.RedactedHeaders{}` struct with custom `Inspect` impl.
  Pure functions; blocks 3B and 3D.
- **3B [P]** — `Upstream.Http` per-request integration: call
  `Credentials.materialize/1` then `Credentials.apply/2` for each
  emitter, splice headers into `Req` request, drop references after.
  Depends on 3A.
- **3C [P]** — `Application` config-loader extension for `auth:`
  list parsing (§5.3.1), `static_headers:` (§5.3.2), `proxy:`
  (§5.3.3), and the §5.5 ##7, 8, 9, 10 validations including
  duplicate-header rejection and `scheme_hint` static cross-check.
  Parallel with 3A/3B once the §5.3 config shape is final.
- **3D [P]** — Boot-time materialization integration: HTTP
  upstream's eager-start handshake calls `materialize/1`;
  `:resolution_failed` renders as "(unavailable at startup)". Touches
  `Upstream.Http.start_link/2` only. Depends on 3A's apply contract.
- **3E [S]** — 401/403 → `:auth_failed` exit reason wiring; verify
  the §4.3.1 abnormal-exit handling Phase 2 stubbed actually fires.
- **3F [P]** — Tests per §13.3:
  - **3F.1** Per-scheme header shape (bearer, basic with both string
    and map binding shapes, custom_header) — Engineer subagent.
  - **3F.2** Multi-emitter ordering and duplicate-name rejection —
    Engineer subagent.
  - **3F.3** 401 → world-fault → cold-start re-materialize —
    Engineer subagent (parameterizes the fixture from Phase 2F).
  - **3F.4** **`RedactionEndToEndTest` property test** — randomized
    32-byte secrets; assert byte sequence absent from JSONL trace,
    `upstream_calls`, log capture buffer over a full
    handshake-and-call cycle. This is the load-bearing test for the
    structural-isolation guarantee (§4.2 / §7.5.3). Engineer
    subagent — must be written by someone who hasn't been deep in
    the implementation, so they spot leak paths the implementer
    missed.
  - **3F.5** `static_headers:` sent verbatim, not redacted, and
    sensitive-name denylist enforced — Engineer subagent.
  - **3F.6** `allow_insecure_http: true` without
    `allow_insecure_auth: true` rejected when `auth:` non-empty —
    Engineer subagent.

**Codex gate.** End of phase: `/codex review` against Phase 3 diff,
plus a `/codex challenge` mid-phase before tests are finalized
(adversarial pass to find leak paths the implementer missed).

**Review focus** (for `/codex review`):

> Review the auth integration diff. Adversarial focus: (1) "Where
> else can the resolved bytes leak?" — walk every place
> `materialize/1`'s `:raw` field flows: GenServer state, Connection
> snapshots, Logger metadata, supervisor restart messages, stack
> traces, `:sys.get_state` calls, `inspect/2` of any struct that
> transitively contains the bytes. The `RedactedHeaders` `Inspect`
> impl must render `[REDACTED]` even on partial-token slices. (2)
> Is `apply/2`'s `:scheme_mismatch` enforcement actually firing at
> request time, in addition to the static check at config-load?
> (3) Does the §7.5.2 first-emission-race property hold under the
> new wiring — registration into ETS happens *before*
> `materialize/1` returns, and the request layer never sees a value
> that isn't already redaction-registered? (4) For multi-emitter
> upstreams, is duplicate-name rejection happening at config-load
> AND at request-time (defense in depth), and are headers spliced
> in declared order?

**Challenge focus** (for `/codex challenge` mid-phase):

> Try to construct a config + program execution path that causes a
> resolved auth value to appear in any of: a JSONL trace file, an
> `upstream_calls` envelope, a Logger output, a telemetry event
> payload, a GenServer crash report, or an `Inspect` rendering of
> any struct held by Connection or Upstream.Http. The redactor is
> defense-in-depth, not the primary guarantee — focus on
> structural paths that *bypass* the redactor (e.g., `:DOWN`
> messages, `:sys.get_state`, custom telemetry handlers, stack
> traces from a deliberately raised exception in the request path).

**Deliverables.**

- `auth:` **list** parsing for `bearer`, `basic`, `custom_header`
  schemes (§5.3.1). Multi-emitter support; ordered application;
  config-load rejection of duplicate header names per §5.3.1
  (resolved: reject at config-load; see OQ-2-resolved in §15).
- `static_headers:` parsing for literal non-secret headers (§5.3.2),
  including sensitive-name denylist, no `${VAR}` expansion, and
  duplicate-name rejection against `auth:` emitters.
- `proxy:` field plumbing: explicit URL only, parsed and passed to
  `Req` as `connect_options: [proxy: …]` per §5.3.3. **No env-var
  resolution** (the codex-1 draft asked for `HTTPS_PROXY` / `NO_PROXY`
  env-var behavior; that was based on a false claim about Finch / Mint
  auto-resolution and was withdrawn — see §3 and §5.3.3).
- `Upstream.Http` resolves bindings on each request via
  `Credentials.materialize/1` + `Credentials.apply/2`. Opaque
  `%Credentials.RedactedHeaders{}` flow per §7.3.
- 401 / 403 handling: world-fault, then impl exits abnormally with
  `:auth_failed` reason; next Connection cold-start re-materializes
  bindings (§4.3.1, §6.3).
- Redaction integration: every materialized value enters the
  redaction set before any HTTP request goes out, asserted by
  Phase 1's first-emission-race property test.
- Boot-time materialization: HTTP upstream's eager-start handshake
  calls `materialize/1`; `:resolution_failed` renders as "(unavailable
  at startup)".
- Tests:
  - Each scheme produces the expected header shape (bearer, basic
    with both string and map binding, custom_header).
  - Multi-emitter upstream produces all configured headers; ordered.
  - 401 → `nil`; impl exits with `:auth_failed`; Connection
    invalidates and arms backoff; next cold-start succeeds against a
    rotated env/file binding without any explicit refresh call.
  - Token bytes never appear in `upstream_calls`, log lines, trace
    JSONL when an HTTP request is exercised end-to-end. **Property
    test** asserting this across randomized 32-byte secrets.
  - `Authorization` rejected as a `custom_header` field name at
    config load.
  - Mismatched `scheme_hint` rejected at config load.
  - `static_headers:` values are sent verbatim, are not redacted, and
    reject sensitive names such as `Authorization` / `Cookie`.
  - Explicit `proxy:` URL is parsed and applied; absence of `proxy:`
    means direct connection (no env-var fallback).
  - `allow_insecure_http: true` without `allow_insecure_auth: true`
    is rejected when `auth:` is non-empty.

**Codex review focus.** "Where else can the bytes leak" — adversarial
review of the redaction surface, including stack traces, GenServer
state inspections, supervisor restart messages, and Logger metadata.

### Phase 4 — Real upstream integration

**Scope.** Validate against a real remote MCP. The GitHub MCP server
(<https://api.githubcopilot.com/mcp/>) is the obvious target — public,
documented, requires bearer auth, has a non-trivial tool surface.

**Target upstream.** The GitHub remote MCP server at
`https://api.githubcopilot.com/mcp/` (Streamable HTTP, bearer auth via
GitHub PAT). Documented at <https://github.com/github/github-mcp-server>.

**Subagent streams.** Most of Phase 4 is sequential investigation
work (live endpoint behavior is not parallelizable until known).

- **4A [S]** — Document current GitHub MCP header expectations
  (`X-MCP-Readonly`, `X-MCP-Toolsets`, PAT scope set) — fetch live
  docs once, pin the values into the test config, record fetch date
  in a comment so future drift is visible. Single Engineer subagent
  with WebFetch.
- **4B [S]** — Opt-in integration test
  (`@tag :real_remote_upstream`, gated on `MCP_REAL_REMOTE=1` +
  `GITHUB_PAT`). Depends on 4A.
- **4C [S]** — End-to-end probe via `claude -p` against the live
  aggregator with `--allowedTools mcp__ptc-runner__lisp_eval`
  asking the LLM to call `get_me`. Per
  `memory/reference_aggregator_sandbox.md`, run from
  `~/ptc-mcp-sandbox/` with the upstreams config copy-pasted in.
  Capture output + rendered catalog snippet, save to
  `Plans/aggregator-state-2026-05-09.md` snapshot.
- **4D [P]** — Failure-mode probe (intentionally invalid PAT →
  401 → world-fault → next call) and best-effort session-loss probe.
  Independent of 4C once the test infrastructure exists.
- **4E [P]** — README + `docs/aggregator-mode.md` HTTP example
  block. Doc-only stream, runs in parallel with 4C/4D.

**Codex gate.** End of phase: `/codex review` is **not** the
primary gate here (live-endpoint validation is the gate). Instead:

- `/codex consult` if any wire-format surprise emerges from the live
  endpoint that the spec didn't predict (record consult outcome in
  the phase exit note; spec edits route through Architect).
- `/codex review` only if the integration required spec-shape
  changes (e.g., a header name turned out wrong).

**Phase 4 exit gate departs from the standard four:** the recorded
probe transcript + a clean failure-mode probe + the catalog snippet
in `Plans/aggregator-state-2026-05-09.md` substitute for codex
review. `mix precommit` and human sign-off still apply.

**Deliverables.**

- Opt-in integration test (`@tag :real_remote_upstream`, gated on
  `MCP_REAL_REMOTE=1` + `GITHUB_PAT`).
- End-to-end probe upstream config that pins **read-only mode and a
  minimal toolset** to keep the test deterministic and unable to
  mutate state. Bearer auth flows through `auth:`; non-secret GitHub
  scoping headers flow through `static_headers:`:

  ```json
  {
    "credentials": {
      "github-pat": { "source": "env", "var": "GITHUB_PAT" }
    },
    "upstreams": {
      "github": {
        "transport": "http",
        "url": "https://api.githubcopilot.com/mcp/",
        "auth": [
          { "scheme": "bearer", "binding": "github-pat" }
        ],
        "static_headers": {
          "X-MCP-Readonly": "true",
          "X-MCP-Toolsets": "context"
        }
      }
    }
  }
  ```

  (Note: GitHub's MCP server reads `X-MCP-Readonly: true` and
  `X-MCP-Toolsets: <comma-list>` to scope tools. These values are not
  credentials, so they deliberately bypass the redaction set via
  `static_headers:`. Confirm header names against current GitHub MCP
  docs at probe time; the GitHub server has rev'd these.)

- **PAT scope expectation.** The test PAT **MUST** carry only
  read scopes: `read:user` for `get_me`, `read:org` /
  `read:project` only if the chosen probe needs them. Document in
  the test setup that the test is read-only by design.
- **End-to-end probe.** A `claude -p` invocation against the live
  aggregator with `--allowedTools mcp__ptc-runner__lisp_eval`,
  asking the LLM to call `get_me` (returns the authenticated user's
  profile — small, stable, read-only). Record output + the rendered
  catalog snippet in `Plans/aggregator-state-*.md` per the
  json-support precedent.
- **Failure-mode probe.** A second probe with an intentionally
  invalid PAT to assert the 401 → world-fault → next-call path.
- **Session-loss probe (best-effort).** Wait long enough that GitHub
  invalidates the session (varies; typically minutes), retry, observe
  the impl-exit + cold-start path. Skip if cadence exceeds the test
  budget.
- README and `docs/aggregator-mode.md` updated with HTTP example.

**What could go wrong against the live endpoint.** GitHub's MCP server
has historically rev'd headers, scope expectations, and toolset names.
The probe's pinned headers may need refresh before each test run.
This is acceptable for an opt-in test gated on a real PAT — drift is
the price of validating against a live remote.

**Why real-upstream is in-scope here.** The base spec §13.4 set the
precedent: stdio integration was validated against the real
`@modelcontextprotocol/server-filesystem` package. HTTP transport's
wire-format edge cases (SSE batched responses, 404 session loss, real
429s, 2025-06-18 protocol-version negotiation) only surface against a
real server.

### Phase 5 — Documentation, telemetry, hardening

**Scope.** Final polish: telemetry, catalog annotation, doc
updates, positioning-doc retirement of resolved weaknesses.

**Subagent streams.** All five streams are independent.

- **5A [P]** — Telemetry events from §11 (`[:upstream, :http,
  :request, …]`, `[:credentials, :resolve, …]`, `[:credentials,
  :redactor, :scrubbed]` sampled). Engineer subagent.
- **5B [P]** — Aggregator authoring card (§9.1 / §8.1 of base spec)
  renders `[transport: http]` annotation in catalog. Touches
  `mcp_server/lib/ptc_runner_mcp/upstream/catalog.ex`.
- **5C [P]** — `docs/aggregator-mode.md` HTTP section — example
  config, security guidance, link to `Plans/`.
- **5D [P]** — README reorientation: "stdio + HTTP" framing in the
  intro paragraph and aggregator-mode link block.
- **5E [P]** — `Plans/positioning-mcp-aggregator.md` updates per
  §14.3: weakness #6 retired; weakness #7 retired-with-caveats;
  feature signals #3 and #4 marked delivered.

**Codex gate.** End of phase: `/codex review` against Phase 5 diff,
plus a final `/codex review` against the **cumulative**
Phase-1-through-5 diff (or the merge commit range) to confirm the
shipped feature is internally consistent.

**Cumulative review focus:**

> Final review of the HTTP transport + credentials registry feature
> (Phases 1-5). (1) Re-run the Phase 3 leak audit against the
> shipped code — does the `RedactionEndToEndTest` actually exercise
> every emission path Phase 5 just added telemetry to? Telemetry
> handlers are a new leak surface. (2) Catalog annotation does not
> break the existing `outputSchema` (§9.3). (3) `docs/` and README
> claims match the shipped behavior — no overclaim about OAuth,
> mTLS, persistent token storage, or SSE GET subscriptions (all §3
> non-goals). (4) Positioning doc weakness retirement is honest —
> binding indirection gives functional parity for the leak vector,
> not for the threat model.

## 13. Testing Requirements

### 13.1 Phase 1 (Credentials registry)

- `BindingTest` — each v1 source's success/failure paths;
  `exec`-rejected-with-deferral-message; type-shape validation at
  config-load (§5.5 #7 first bullet) — `:basic` consuming a binding
  with a `scheme_hint: "bearer"` is rejected loudly.
- `CredentialsTest` — `materialize` source-resolution semantics;
  env/file re-read on each call; first-emission race (registration
  occurs before `materialize/1` returns).
- `RedactorTest` — known plaintext substituted across `Log` /
  `TraceFile` / `UpstreamCalls` paths. **Property test** asserting
  that no SHA-256 hash of any registered value appears in any output
  (catches a regression where the hash idea sneaks back in).
- `LiteralWarningTest` — `MIX_ENV: :dev` emits `Logger.warning` for
  literal bindings; `MIX_ENV: :test` does not (because tests use
  literals heavily); warning content includes binding *name* but
  never the *value*.

### 13.2 Phase 2 (HTTP transport, no auth)

- `Upstream.HttpTest` against a Plug/Bandit-based fixture server in
  `test/support/fake_mcp_http_server.ex`. Fixture supports:
  - configurable handshake response (success / malformed / 401 /
    timeout);
  - `application/json` and `text/event-stream` response shapes;
  - configurable session-id behavior (none / static / 404-on-stale);
  - artificial response inflation for `:response_too_large` tests;
  - introspection of received headers for assertion.
- Connection-lifecycle integration tests via the existing
  `RegistryTest` shape, parameterized over impl.
- `:real_remote_upstream` tag is reserved for Phase 4 (GitHub MCP).
  Phase 2 stays entirely against the local Plug/Bandit fixture; no
  public-endpoint tests at this phase.

### 13.3 Phase 3 (Auth integration)

- `Upstream.HttpAuthTest` — each scheme; 401 handling; re-materialize
  on cold start.
- `RedactionEndToEndTest` — token byte sequence absent from JSONL
  trace files, `upstream_calls` envelope, log capture buffer for a
  full handshake-and-call cycle.

### 13.4 Phase 4 (real GitHub MCP)

- `@tag :real_remote_upstream` gated on `GITHUB_PAT` env var.
- One read-only end-to-end probe; recorded in
  `Plans/aggregator-state-*.md` snapshot.

### 13.5 Performance budget

The HTTP impl **MUST NOT** regress stdio-upstream latency. The
existing `Plans/phase2-decision-point-results.md` benchmark
(11.6× token saving + 2.84× pmap speedup measured against stdio)
is the floor. If HTTP impl inadvertently shares hot code paths
that slow stdio measurably, that's a regression.

## 14. Migration & Compatibility

### 14.1 Existing stdio configs

A v1.x stdio-only config:

```json
{
  "upstreams": {
    "fs": { "command": "npx", "args": [...] },
    "mem": { "command": "npx", "args": [...] }
  }
}
```

continues to load and run identically. No `transport:` field, no
`credentials:` block, no migration needed. The validation pass in
§5.5 does nothing on a stdio-only file.

### 14.2 `${VAR}` placeholder behavior in stdio `env`

The existing inline `${VAR}` resolution in stdio `env` values
(`mcp_server/lib/ptc_runner_mcp/application.ex:401`) is **preserved
unchanged** (§5.2 of this spec, §5.2 of base aggregator spec).
Stdio upstreams have no `auth:` block in v1. The credentials registry
is **not wired into stdio `env` values in v1.**

The codex-1 draft proposed a new `env_bindings:` field for stdio
upstreams; that proposal was withdrawn because it would have shipped
half-implemented (Phase 1 didn't deliver it, §14.2 invented the shape
without §5.2 specifying it). v2 may revisit `env_bindings:` as a
unified-credentials story across stdio + HTTP — out of scope here.

Operators with structurally-sensitive stdio env values today
(e.g., `LINEAR_API_KEY`) keep using `${VAR}` resolution; the
redactor introduced in Phase 1 covers any leak that goes through
PtcRunner's `Log` / `TraceFile` / `UpstreamCalls` paths regardless of
whether the value originated from a binding or from inline `${VAR}`,
**provided** the value is registered in the redaction set. v1 does
**not** auto-register `${VAR}`-resolved env values: the redaction
discipline is opt-in via bindings. Stdio operators who want
end-to-end redaction for a specific env var define a `literal` or
`env` binding and reference it in a future v2 `env_bindings:` block;
in v1 they accept that the inline path is best-effort.

### 14.3 Position-doc updates

After Phase 5 ships, `Plans/positioning-mcp-aggregator.md` should be
revised:

- §"Honest weaknesses #6" (stdio-only upstreams) → retired.
- §"Honest weaknesses #7" (credential-binding weaker than
  Cloudflare's) → retired-with-caveat. Bindings + structural
  redaction = functional parity for the leak vector ("a misbehaving
  upstream that echoes its env"). Cloudflare's V8-isolated bindings
  are still a different threat model (the sandbox literally cannot
  hold the secret). Keep that part; drop the "subprocess env leak"
  phrasing.
- §"Feature signals #3" (HTTP/SSE/Streamable HTTP transport) →
  delivered.
- §"Feature signals #4" (Credential-binding model) → delivered.

### 14.4 Aggregator spec back-references

`Plans/ptc-runner-mcp-aggregator.md` §16 (Open Questions) gains a
"Resolved by `http-transport-credentials.md`" entry covering the
relevant items. The §17 history gets a "Phase 6: HTTP transport +
credentials" entry on Phase 5 ship of this spec.

## 15. Open Questions

These are decisions the implementation **MUST** answer before phase
exit, not decisions made here.

### Resolved (carried forward for traceability)

**OQ-2-resolved — `auth:` emitter ordering and duplicate-header
collapse.** **Resolved: reject duplicate header names at config-load.**
§5.3.1 now codifies this directly. Last-wins-collapse was a footgun
for operators who don't notice the override; loud rejection is
unambiguous. This question is closed; the OQ number is preserved for
traceability with the codex-3 review log.

**OQ-7-deferred — Should `exec` source be in v1 at all?** **Resolved:
deferred to v1.1** behind explicit `allow_exec_bindings: true`
server-level flag. §3 lists `exec` as a non-goal for v1; §5.5 #11
rejects it at config load. Operators who need 1Password / Vault /
STS wire it through `file` source with their own refresh cron. This
question is closed; the OQ number is preserved for traceability with
the codex-1 review log.

**OQ-1-resolved — `request_timeout_ms` interaction with per-call
timeout.** **Resolved: clamp.** `request_timeout_ms` is the HTTP
envelope, but the effective deadline for pool checkout, send, and read
is `min(request_timeout_ms, call_opts[:timeout])` (§6.5 / §10). This
preserves the `Upstream.call/4` invariant that the program-level
timeout is authoritative.

**OQ-3-resolved — Binding cache invalidation across Connection
restarts.** **Resolved: no credential value cache in v1.** `env` and
`file` sources are re-resolved on every `materialize/1` call (§7.4).
This makes rotation behavior immediate on the next request / cold start
and removes the need for `Credentials.refresh/1` in v1. A future v2 may
add caching after adding explicit invalidation and admin reload
semantics.

### Open

**OQ-4 — Redaction set growth over server lifetime.** The set
accumulates one entry per binding × rotation. v1 never evicts.
Memory cost: a 200-byte token × 100 rotations × 10 bindings = 200 KB,
small. Should v1 cap the set anyway (e.g., 1000 entries, evict
oldest)? Proposal: no. Eviction risks losing redaction coverage for
an old token still echoed somewhere. Confirm in Phase 1.

**OQ-5 — Self-as-upstream over HTTP.** Should the §5.3 rejection
extend to "URL points at this PtcRunner's own loopback"? Detection
is fragile (the PtcRunner MCP server doesn't bind a known port —
it's stdio-driven, not HTTP-served). Proposal: out of scope.
Documented in §3. The program-level
`max_upstream_calls_per_program` cap is the backstop.

**OQ-6 — Cumulative-stream cap interaction with batched SSE.**
§6.4.1 enforces `:max_response_bytes` cumulatively across an SSE
stream. For a batched-array event whose JSON parses successfully but
contains 500 messages totaling > cap bytes, do we fail the in-flight
call after parsing the array, or refuse to parse anything past the
cap? Proposal: refuse pre-parse (close the stream once the
cumulative byte count exceeds cap, regardless of whether mid-event).
The cap is about wire bytes, not decoded message count. Confirm in
Phase 2.

**OQ-7 — `--upstreams-config` reload.** Currently the file is read
once at boot. If a binding rotates (new `GITHUB_PAT`) the only path
is process restart. Proposal: out of scope for v1. v2 candidate is
a `SIGHUP`-equivalent admin command that re-parses the file and
rotates bindings without restarting Connections. The redaction set
already accumulates rotated values, so old tokens stay redacted
across rotations within one process lifetime.

**OQ-8 — SSE intermediate progress events.** Streamable HTTP allows
the server to push intermediate progress notifications during a
streamed response. v1 drops them. Should there be any LLM-visible
hint that progress events arrived? Proposal: no, but record a
counter in telemetry (`sse_intermediate_dropped_count`) so operators
can see whether real upstreams use this surface. v2 may expose
`(tool/mcp-call ... :on-progress f)`. Confirm in Phase 2.

**OQ-9 — Backward-compat batched SSE.** The 2025-06-18 revision
**removed** JSON-RPC batching from the wire protocol; an event's
`data:` payload is a single JSON-RPC message, not an array. v1
targets 2025-06-18 and fails the handshake on a different negotiated
version (§6.1.1), so this does not mean full 2025-03-26 protocol
support. But a legacy or nonconforming server may accept 2025-06-18
and still emit batched arrays. Proposal: v1 implementations parse
single-message form by default and **also** accept array-form as a
compatibility path (the cost is one branch in the SSE decoder). Mark
this as "compat path" rather than a 2025-06-18 conformance
requirement. Confirm in Phase 2.

## 16. Citations

**MCP transport spec:**

- MCP Streamable HTTP transport (revision **2025-06-18**, target for v1):
  <https://modelcontextprotocol.io/specification/2025-06-18/basic/transports>
- 2025-06-18 changelog (`MCP-Protocol-Version` header introduced here):
  <https://modelcontextprotocol.io/specification/2025-06-18/changelog>
- 2025-06-18 lifecycle (handshake, version negotiation):
  <https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle>
- 2025-03-26 Streamable HTTP (predecessor; introduced single-endpoint
  shape and SSE batched-response semantics):
  <https://modelcontextprotocol.io/specification/2025-03-26/basic/transports>
- 2024-11-05 "HTTP+SSE" transport (legacy, deprecated):
  <https://modelcontextprotocol.io/specification/2024-11-05/basic/transports>

**Real remote-MCP upstreams:**

- GitHub remote MCP server (`https://api.githubcopilot.com/mcp/`):
  <https://github.com/github/github-mcp-server>
- GitHub Docs — set up the GitHub MCP server in your IDE (covers
  PAT scope, `X-MCP-Readonly`, toolset headers):
  <https://docs.github.com/en/copilot/how-tos/provide-context/use-mcp-in-your-ide/set-up-the-github-mcp-server>
- Cloudflare MCP servers (Streamable HTTP):
  <https://developers.cloudflare.com/agents/model-context-protocol/>

**Peer comparison (HTTP transport in Code Mode peers):**

- Cloudflare Code Mode SDK rewrite (Streamable HTTP support):
  <https://developers.cloudflare.com/changelog/post/2026-02-20-codemode-sdk-rewrite/>
- MCPProxy (stdio + HTTP/SSE):
  <https://github.com/orgs/modelcontextprotocol/discussions/627>

**Internal references:**

- `Plans/ptc-runner-mcp-aggregator.md` — base aggregator spec.
- `Plans/positioning-mcp-aggregator.md` §"Honest weaknesses #6, #7";
  §"Feature signals #3, #4".
- `Plans/aggregator-catalog-discovery.md` — companion roadmap doc;
  HTTP transport is orthogonal to catalog discovery but the typical
  remote-MCP user (50+ tools) hits the inline-catalog wall on first
  contact, so size-aware catalog default should ship in parallel.
- `Plans/json-support.md` — precedent for "spec, then phased
  implementation, then live validation against a real upstream"
  rhythm.
- `Plans/aggregator-state-2026-05-09.md` — current aggregator state
  snapshot.

If the cited MCP spec revisions or peer-project transport choices
drift, update this document — do not let drift accumulate silently
into the implementation plan.
