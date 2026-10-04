# Gateway roles and multi-tenancy

Status: planned, not scheduled. Tracking issue: #2206. Nothing below is current
behavior unless it is cited as such. Builds on
`docs/plans/gateway-mcp-providers.md` (shared upstream MCP providers, #2203).

## Goal

One gateway serves several **tenants** with real separation, and inside each
tenant several **roles** with different tool sets.

- A **tenant** is an isolation boundary: its own credentials, upstream
  acquisitions, artifacts, audit, budgets, readiness, and failure domain. One
  tenant must not read another's data, exhaust its budgets, or take it down.
  Timing through the shared scheduler, HTTP pool, and network remains a
  residual channel inside one process; the reference documents it, and
  deployments that cannot accept it run one gateway per tenant.
- A **role** is a permission set inside one tenant: which tools a client sees
  and calls, and later whether it may receive private evidence. Roles never
  change what a tool does.
- "One gateway" means one listener and one OS process. Deployments that need
  OS-level separation run one gateway per tenant instead (design 9).

## Trigger

Start when a deployment needs either more than one class of client on one
gateway (roles), or more than one isolated customer or team on one process
(tenants). Phase 1 (roles) and phase 0 (prerequisites) are useful on their
own and may start earlier.

## Current behavior

- One gateway is one OS process with one Bandit listener on a literal loopback
  address and the fixed path `/mcp`, one bearer token, one host document, one
  startup credential capture, one artifact root, one private audit directory,
  and one warm domain (`ptc_gateway/lib/ptc_gateway/domain.ex`,
  `lib/ptc_runner/kernel/gateway_config.ex`).
- `CapturedCredentials.authenticate/2` returns a boolean; no caller identity
  exists downstream (`captured_credentials.ex:61-66`). Every request reaches it
  through a `GenServer.call` on `WarmProviderRuntime`
  (`ptc_gateway/lib/ptc_gateway/mcp.ex:134-157`).
- No trace, inspection, audit, or event record carries a caller, role, or
  tenant. MCP `clientInfo` is validated and dropped.
- `PtcGateway.Domain` already runs as a temporary child of the one-for-one
  `PtcGateway.Supervisor`, and its admissions, `CapturedCredentials`, and
  `PrivateAudit` are unnamed, so several can coexist in one VM. Only four
  places in `Domain` assume it owns the listener (`domain.ex:281-314, 326,
  352-353, 369`).
- VM-wide singletons block a second provider-backed domain: ReqLLM is started
  once with one global Finch pool and stopped by its owner
  (`warm_provider_applications.ex`), `PtcRunner.Dotenv.with_loaded_file` writes
  secrets into the process environment under a VM-wide lock
  (`dotenv.ex:137-160, 214`), `MCPOAuth.ManagerCleanup` has 128 slots for the
  whole VM, the publication sweep throttle keeps one root in one
  `persistent_term` key (`publication_handle.ex:1230-1240`), and the release
  CLI halts the VM when its single owner exits (`release_cli.ex:58`).
- ReqLLM falls back to application config and then the OS environment when a
  call carries no explicit key (`deps/req_llm/lib/req_llm/keys.ex:60-62`).
- `MCPOAuth.NetworkPolicy` resolves, checks every address against public
  ranges (including IPv4-mapped IPv6, NAT64, link-local, and cloud metadata),
  and pins the connection, but only OAuth traffic uses it
  (`mcp_source.ex:1872-1879`). Static-header HTTP MCP and the decision `http`
  backend may reach any `https` host, including private addresses; keyless
  `openai-compat` may also reach any plain `http` host. Connect errors
  distinguish refused, unresolved, and TLS failures
  (`mcp_http_adapter.ex:126-127`).
- Credential resolution and adapters still touch process-global state on the
  gateway path: dotenv writes, an `AWS_REGION` write in the ReqLLM adapter
  (`req_llm_adapter.ex:1069-1075`), and ReqLLM's application-config fallback.
- Trace and inspection artifacts have no aggregate size or retention bound in
  the gateway (`gateway_config.ex:192-199`); only the audit directory rotates.
- The private audit directory exists only when a write tool is enabled
  (`gateway_config.ex:79-80`), and a call's response is published before the
  audit hook runs (`serving_call.ex:224-229`).
- The MCP OAuth layer already models `tenant_id` and `principal_id`
  (`MCPOAuth.Context`, `GrantKey`, `Store.Memory`); the only caller hardcodes
  `"local-cli"` and `"local-user"` (`provider_execution.ex:1157-1166`).
- `data_class` is a closed sensitivity enum (`normal`, `private_inspection`),
  not ownership.

## External constraints

From MCP 2026-07-28 and the surveyed gateways (IBM ContextForge, Cloudflare MCP
portals, Microsoft MCP Gateway, Docker MCP Gateway, Kong, Envoy AI Gateway,
MetaMCP, Obot, Smithery, Composio):

- The spec has no tenant concept. A server is identified by its canonical URI,
  which may include a path "when path component is necessary to identify
  individual MCP server"; a future OAuth audience and Protected Resource
  Metadata document are per URI.
- `tools/list` "MAY vary by the authorization presented on the request" and
  "MUST NOT vary per-connection". A `private` cache scope must not be shared
  across authorization contexts and must not be relied on for access control.
- A state handle is never authentication; key state by the verified identity.
- Products converge on a curated endpoint per tenant and role, two mandatory
  layers (tenant scoping plus role permission), and two upstream credential
  modes: one operator credential, or per-user OAuth stored write-only.
  Products that accept user-defined stdio servers run them in containers.

## Model

### Identity

A bearer token maps to exactly one `(tenant, role)`.

- The tenant comes from the request path, the role from the token. A token
  that does not belong to the path's tenant gets the same 401 as an unknown
  token.
- The front builds the token table itself before any tenant boots: it reads
  each tenant's token bindings from that tenant's credential map, refuses
  duplicates across roles and tenants, and publishes one immutable table.
  Authentication is a hash lookup in that table, not a call through a domain
  process, so a slow, fenced, or failed tenant cannot delay another tenant's
  authentication. A valid token of a tenant whose domain is not ready gets
  that tenant's 503.
- Tokens remain operator-supplied credential bindings in version 1.
- Only the server-derived tenant and role are recorded. `clientInfo` is never
  identity.

### Configuration

A single-tenant gateway keeps today's document shape, with roles (phase 1). A
multi-tenant gateway adds a front document (phase 2). Both are version 2 of
the gateway schema; version 1 is removed.

Single tenant, `ptc-gateway.json`:

```json
{
  "version": 2,
  "listen": {"address": "127.0.0.1", "port": 8787, "path": "/mcp"},
  "authentication": {
    "roles": {
      "user": {"binding": "user_token"},
      "debug": {"binding": "debug_token"}
    }
  },
  "host": {"path": "./ptc-host.json"},
  "admission": {"max_inflight_requests": 8, "max_concurrent_runs": 2,
                "max_active_provider_calls": 1, "max_waiting_provider_calls": 0},
  "tools": [
    {"name": "ask_handbook", "roles": ["user", "debug"], "...": "..."},
    {"name": "debug_eval", "roles": ["debug"], "...": "..."}
  ]
}
```

Multi-tenant front document, `ptc-gateway-front.json`:

```json
{
  "version": 2,
  "listen": {"address": "127.0.0.1", "port": 8787},
  "state_root": "/srv/ptc/tenants",
  "ceilings": {"max_inflight_requests": 256, "max_sockets": 2048},
  "tenants": {
    "acme": {"config": "./tenants/acme/ptc-gateway.json",
             "env_file": "./tenants/acme/credentials.env"},
    "globex": {"config": "./tenants/globex/ptc-gateway.json",
               "env_file": "./tenants/globex/credentials.env"}
  }
}
```

- A tenant document is the single-tenant document without `listen`. It keeps
  its own host document, roles, tools, pins, and admission budgets.
- The front serves tenant `acme` at `/t/acme/mcp`.
- Tenant ids match `[a-z0-9-]{1,32}`, are assigned by the operator, and are
  never reused. Case-insensitive file systems make `Acme` and `acme` the same
  directory, so mixed case is refused.
- In multi-tenant mode, tenant documents may not name artifact, audit, or
  event paths. The front derives them under `<state_root>/<tenant>/`
  (`artifacts/`, `audit/`, `events/`). Trace-snapshot directories in a tenant
  host document must resolve inside that tenant's own artifact root.
  Deleting or backing up a tenant is a subtree operation.
- The operator writes every document. Tenants never supply paths, commands,
  private-network origins, or the loopback allowance. Self-service tenant
  configuration is a non-goal.
- In multi-tenant mode every tenant has an audit directory (derived, so a
  read-only tenant has one too), and publication staging and its locks live
  under `<state_root>/<tenant>/tmp/` instead of the per-user temporary
  directory, so tenants share neither staging files nor lock buckets. The
  publication sweep throttle, today one VM-wide `persistent_term` entry that
  alternating roots overwrite (`publication_handle.ex:1230-1240`), becomes a
  per-root throttle in an ETS table; destination-local staging
  (`private_directory.ex:76`) is unchanged.
- Any configuration change, to the front or to a tenant, restarts the whole
  gateway in phases 0–3.

### Roles

- Flat named roles: no inheritance, no token with two roles, no client choice
  of role.
- A tool without `roles` is visible to every role of its tenant, so one role
  with no tool lists reproduces today's behavior.
- `tools/list` returns only the role's tools. Calling a tool outside the role
  returns the same `-32602` as an unknown tool, and the role check runs before
  argument and header validation that depends on the tool's schema, so neither
  the reply nor its timing reveals that the tool exists.
- Audit and run provenance records carry the tenant and role. Phase 1 adds the
  fields to the existing write records; the closed audit schema
  (`private_audit.ex:320-331`) gains them. Read calls are audited only when
  they disclose private evidence (phase 3).
- Roles never change a tool's manifest, preludes, pins, or grants. A tool is
  one pinned application whoever calls it, so traces and replay stay
  meaningful.

### Tenants

Each tenant runs as one listener-less `PtcGateway.Domain` under
`PtcGateway.Supervisor`. The front owns the listener, the token table, the
global ceilings, and the VM-wide applications.

- **Credentials.** Each tenant's env file is parsed into a map. A tenant's
  `env` bindings resolve only from that map; a missing binding fails closed,
  and nothing is written to the process environment. The adapter passes
  `AWS_REGION` and every other provider setting explicitly instead of writing
  the environment. A keyless installation (for example a local
  `openai-compat` server) stays supported and is represented as "no
  credential", distinct from an unresolved one, so ReqLLM's environment and
  application-config fallback is never reached. In multi-tenant mode the
  gateway refuses to start when provider keys or `SSLKEYLOGFILE` are in its
  environment or provider keys are in ReqLLM's application config.
- **Upstream acquisitions and principals.** Every acquisition belongs to one
  tenant's tool, so tenants share no connection or upstream process. That does
  not separate data at the upstream: two tenants calling the same server with
  the same account see the same records. Tenant data separation at an
  upstream therefore comes from the upstream itself, through a distinct
  account per tenant or a dedicated server. The front refuses startup when two
  tenants bind the same credential value for the same upstream origin, unless
  the front lists that origin in `shared_upstream_origins` (for public,
  account-free data).
- **Model providers.** The same rule applies to model credentials: two tenants
  may not share a provider key value. Provider prompt caches are scoped by the
  provider's account or organization, not by PtcRunner's `cache` setting
  (`cache: false` only omits caching options, `req_llm_adapter.ex:1067`), so
  the reference tells operators to give each tenant its own provider account
  when cache timing must not cross tenants.
- **Pooled connections.** The ReqLLM HTTP pool is owned by the front and
  serves only built-in provider origins (fixed public hosts such as
  OpenRouter); requests carry their own headers, so only pool timing is
  shared. Each pooled origin is sized to the gateway-wide sum of the tenants'
  `max_active_provider_calls`, so one tenant at its limit never holds a
  connection another tenant's admitted call needs. Every operator-configured endpoint (an `openai-compat` base URL, a
  decision `http` endpoint, an HTTP MCP server) uses the non-pooling
  resolve-and-pin transport, so no connection opened under one tenant's
  egress allowance is reused by another.
- **Budgets.** Each tenant keeps its own request, run, provider-call, and
  outbound-request admission (`max_outbound_requests`, counting MCP, model,
  and decision requests), acquired after routing. The front refuses startup
  when the sum of tenant budgets exceeds its ceilings.
- **Inbound connections.** In multi-tenant mode the front closes the
  connection after every response, so an authenticated tenant cannot hold
  idle keep-alive sockets that count against the shared listener limit.
  Connections before authentication remain a shared resource bounded only by
  the listener's global limits; a deployment exposed to untrusted networks
  puts a proxy with per-client limits in front.
- **File descriptors.** The resolve-and-pin transport makes at most two
  connection attempts at a time (today up to 16 candidates race,
  `mcp_http_adapter.ex:134, 462-468`). Startup refuses a configuration whose
  worst case exceeds the process descriptor limit: inbound listener
  connections, twice the summed outbound budgets, the front's pooled
  connections (Finch keeps one pool per origin, so pool size times the number
  of built-in provider origins, idle connections included),
  three descriptors per stdio upstream, open artifact and audit files, and a
  fixed reserve.
- **Memory.** Every request and run process carries a heap cap, including the
  HTTP request process that decodes the body. Per-tenant admission bounds how
  many exist. ETS tables, off-heap message queues, port buffers, and retained
  acquisitions are not covered by heap caps; the reference documents this
  envelope, and phase 2 load tests measure it rather than assert a product.
- **Storage.** Each tenant has `max_artifact_bytes`, a retention bound:
  completed artifacts beyond it are pruned oldest first, reusing the logic of
  `ptc prune`, which counts logical bytes and keeps recent and protected
  runs. It is not a disk reservation. Separation of disk capacity comes from
  the deployment: each `<state_root>/<tenant>/` on its own volume or under a
  filesystem quota. Without that, a full shared filesystem is a failure every
  tenant shares, and the reference says so.
- **Fencing.** A fenced tenant answers 503 on its own calls while others serve.
  There is no automatic restart in phases 0–3: replacing a domain safely
  requires proven settlement of its runs, borrows, sockets, and pool
  checkouts (`provider_call_admission.ex:16-18`,
  `warm_provider_runtime.ex:47-53`), and uncertain cleanup must keep the
  tenant fenced with its capacity still reserved. Recovery is a gateway
  restart; automatic per-tenant replacement is a later phase.
- **Health.** Unauthenticated `/health/live` and `/health/ready` report only
  the front: listener, token table, and VM-wide applications. A tenant's
  readiness is served at `/t/<tenant>/health/ready` and requires a token of
  that tenant.
- **Startup.** Front preflight stops the gateway when it fails. It covers the
  front document, every tenant document and host document as far as needed
  to resolve that tenant's role tokens, the token table and its duplicate
  check, the credential-sharing checks, the ceilings, and the descriptor
  budget. Preflight resolves one immutable credential snapshot per tenant,
  and the tenant's domain boots from that same snapshot. A failure after
  preflight inside one tenant (an unresolved provider credential, unwritable
  tenant state, template construction, provider acquisition, pins) fences
  that tenant and starts the others. Failures before a tenant's own event log
  exists are recorded in a bounded front diagnostic log under
  `<state_root>/_front/`, owner-only and naming the tenant id and reason class
  only. Tenants boot with bounded concurrency.
- **Diagnostics.** A tenant's diagnostics and event log never name another
  tenant's installations, tools, or paths.
- **Pins.** Pin discovery reads the front document with a `--tenant` selector,
  uses the same credential overlay and validation as serving, and prints pins
  keyed by tenant and then tool. It keeps the providers plan's rules: no
  bearer, listener, or state directory is touched.

### Egress

Applies to single- and multi-tenant gateways alike, since a gateway is a
network position worth protecting either way.

- Every outbound connection a configuration can trigger (HTTP MCP, OAuth,
  `openai-compat`, decision `http`) goes through one resolve-and-pin policy,
  extended from `MCPOAuth.NetworkPolicy`. The deprecated 6to4 relay range
  `192.88.99.0/24` is added to its denied set.
- Private, loopback, and link-local destinations need an explicit
  `private_network_origins` entry on the installation. The existing
  `allow_insecure_loopback` keeps its current meaning for single-tenant
  gateways and is refused in tenant documents.
- Denied, refused, and unresolved connections return one error class to the
  workflow, so egress cannot be used as a port scanner. The tenant's event log
  keeps the precise class.

### Upstream servers by kind

- **HTTP upstreams** may be any public server the operator configures for a
  tenant, including one the tenant runs. Separation comes from per-tenant
  acquisitions, the egress policy, per-tenant fencing, and per-tenant caps.
- **Stdio upstreams** run as OS processes with the gateway's user. In
  multi-tenant mode they are allowed only from a front-level allowlist of
  operator-approved commands; a tenant-specific stdio server needs OS
  separation (design 9).

### Private evidence (later phase)

Serving private traces or inspection records requires a role flag (who may
receive it) and a tool flag (which surface exposes it). The tool flag is
validated against the tool's effective role set, where a tool without `roles`
means every role of its tenant, so every such role must carry the flag.

- The run stays classified `private_inspection` end to end. Its arguments and
  results never reach normal traces, logs, or errors.
- It reads only its own tenant's state: trace and inspection directories must
  resolve inside the tenant's artifact root, and run and artifact identifiers
  of another tenant resolve as unknown.
- The cold-tool contract of the providers plan (per-call capture, snapshot
  sites omitted from snapshot pins, preflight before the listener binds)
  extends to `ptc_private_trace_snapshot` and `ptc_inspection_snapshot`.
- Every disclosure writes a durable audit record carrying tenant and role
  before any response byte is sent, and a completion record after delivery
  that notes a client disconnect. An audit failure refuses the disclosure.
- Once returned, the data reaches the client and its model vendor; the
  reference says so.
- The serving refusals that exist today (`serving_template.ex:364`,
  `run_coordinator.ex:147`, `serving_call.ex:171`) are replaced by this
  contract, never simply removed.

### Strong separation: one gateway per tenant

For untrusted tenants with their own stdio servers, strict resource
guarantees, or a separate outbound IP, run one gateway process per tenant
behind a reverse proxy, or one container per tenant with a sidecar proxy. No
code change is needed; the proxy must rewrite `Host` to the gateway's literal
authority, strip the path prefix, and disable response buffering for event
streams. The reference documents this with a Caddy and systemd example. A
gateway that fences stays alive today, which a supervisor will not restart;
phase 0 adds an opt-in exit on fencing for this deployment.

## Phases

| Phase | Content | Acceptance |
| --- | --- | --- |
| 0 | Prerequisites, each useful alone: credential overlay instead of process-environment writes; explicit provider settings (no `AWS_REGION` write); "no credential" distinct from unresolved; ReqLLM owned once per VM; heap caps on every request process; egress policy on every outbound path with uniform workflow errors, at most two concurrent connection attempts, and operator-configured endpoints on the non-pooling transport; a per-root publication sweep throttle; opt-in exit on fencing; reverse-proxy reference. | No process-environment write on the gateway path; alternating publications to two roots within one throttle interval sweep each root once; two same-named bindings with different values resolve independently; a keyless `openai-compat` call still works and an unresolved credential fails instead of reading the environment or application config; a static-header MCP or decision endpoint resolving to a private address is refused unless listed; denied, refused, and unresolved look the same to the workflow; a gateway behind a `Host`-rewriting, prefix-stripping proxy passes the conformance subset. |
| 1 | Roles in the single-tenant gateway. | Each role sees only its tools; a hidden and an unknown tool give identical replies and the role check precedes schema-dependent validation; duplicate tokens refuse startup; write audit records carry the role; authentication does not call a domain process. |
| 2 | Tenants: front document and preflight, token table, listener-less domains, path routing, derived state and staging directories, credential-sharing refusal, per-tenant budgets, descriptor budget, storage quota, per-tenant health, front diagnostic log, tenant pin discovery. | A token of tenant A on `/t/b/mcp` gets the unknown-token 401; a failure resolving A's role tokens stops the whole gateway in preflight; A's fencing, crash, or failure after preflight (unresolved provider credential, unwritable state, acquisition failure) leaves B serving and is recorded in the front log; saturating A's outbound budget or run slots leaves B able to connect, call, publish, and audit; A's completed artifacts beyond its quota are pruned; identical upstream credential values across tenants refuse startup unless the origin is listed as shared; identical model credential values refuse startup in every case; with A holding its maximum outbound connection attempts and B opening a fresh inbound connection, B connects and completes a call; a connection opened for A's private-origin endpoint is never used for B; a fixture upstream that scopes data by account keeps A's record handle inaccessible through B; budgets above ceilings or a descriptor worst case above the limit refuse startup, with every built-in provider origin warmed and its idle connections counted; with A holding its maximum model-call checkouts at one origin, B completes a model call to that origin before A releases them; a snapshot directory outside the tenant's root and tenant ids differing only in case are refused; no tenant document can name a state path. |
| 3 | Private evidence (role and tool flags, private classification, cold private snapshots, disclosure audit barrier). | A private-evidence tool is refused unless every role in its effective set carries the flag; a private debugger sees evidence from runs after startup and cannot resolve another tenant's run or artifact identifiers; its results never appear in normal traces or logs; an audit failure refuses disclosure; a client disconnect during delivery is recorded. |
| Later | Automatic per-tenant replacement after proven settlement; per-tenant configuration reload; per-tenant OAuth (Protected Resource Metadata and audience per `/t/<tenant>/mcp`, per-principal upstream grants through `MCPOAuth`'s tenant and principal keys); gateway-generated tokens; a `propose_change` workflow for a maintainer role; live prelude replacement (separate plan). | — |

Phase 0 and phase 1 are independent. Phase 2 depends on both.

## Non-goals

- Self-service tenant or token management, and an admin role on the tenant
  listener. Administration stays local.
- Roles that alter preludes, grants, or pins of a tool.
- Tenant-supplied stdio servers in a shared process.
- Per-tenant CPU quotas, a per-tenant outbound IP, and isolation from
  VM-wide failures (out-of-memory, native-code crashes, binary upgrades) inside
  one process. Those need one gateway per tenant.
- Live configuration reload and automatic tenant restart in phases 0–3;
  configuration changes and recovery restart the whole gateway.
- Tenant data separation at an upstream that one account serves for several
  tenants. The upstream must separate them.
- Freedom from timing channels through the shared scheduler, pool, and
  network inside one process.
- Built-in disk reservation per tenant; disk separation is per-tenant volumes
  or filesystem quotas.
- Per-tenant isolation of connections before authentication.

## Open questions

1. Whether the token table moves from operator-supplied bindings to
   gateway-generated tokens stored only as hashes, which makes rotation and
   revocation per identity possible without a restart.
2. Whether phase 2 needs a runtime upgrade path (pins discovered per tenant
   against the new binary before cutover), or whether a whole-gateway restart
   with new pins is acceptable.
