# MCP OAuth authorization

**Status:** active; dependency and architecture feasibility checked
2026-07-29. Implement against the final MCP `2026-07-28` authorization
profile.

PtcRunner currently supports fixed bearer, basic, and API-key headers for
Streamable HTTP MCP installations. Many remote MCP servers instead require an
OAuth authorization-code flow tied to a user. This plan adds that support
without moving credentials into manifests, allowing a model to choose scopes,
or replaying a tool call after an authorization failure.

The first product boundary remains host-controlled execution. OAuth is an
outbound credential for one installed MCP server; it is not inbound user
authentication for a future hosted PtcRunner service.

## Goals

- Connect to OAuth-protected Streamable HTTP MCP servers using the MCP
  `2026-07-28` authorization and client-registration profiles.
- Support public authorization-code clients with S256 PKCE and confidential
  clients with a host-owned client secret.
- Discover and validate Protected Resource Metadata and OAuth or OpenID
  authorization-server metadata with strict bounds.
- Send the exact MCP resource indicator during authorization, code exchange,
  and refresh;
- refresh expiring access tokens atomically before an MCP request;
- keep authorization interactive and explicit before Kernel execution;
- preserve PtcRunner's no-transparent-replay rule for every `tools/call`;
- keep access tokens, refresh tokens, authorization codes, client secrets,
  PKCE verifiers, and exact account identity out of manifests, PTC-Lisp,
  snapshots, canonical events, inspection artifacts, logs, exceptions, and
  process status; and
- make authorization state explicitly principal-scoped so a future
  multi-user host cannot accidentally share one user's grant with another.

## Non-goals

- Inbound login, sessions, tenant provisioning, roles, billing, or IAM for a
  future PtcRunner cloud service.
- OAuth for stdio servers. The MCP profile leaves stdio credentials to the
  process environment, which the existing host credential bindings cover.
- Letting a manifest, model, or remote MCP server widen installed scopes,
  choose an authorization server, supply a redirect URI, or select a token
  store.
- Token passthrough from a PtcRunner caller to an MCP server.
- Device authorization, password grants, implicit grants, DPoP, token
  exchange, the MCP OAuth client-credentials extension, or inbound MCP
  authorization. Client credentials represent an application rather than a
  delegated user and can be planned separately if static bearer credentials
  prove insufficient.
- Automatically opening a browser or requesting broader scopes after Kernel
  execution has started.
- Treating an OAuth grant as permission to call a tool. Installed mappings,
  manifest narrowing, and read/write effects remain the capability boundary.

## Feasibility and dependency decision

The existing architecture already has the required integration points:

- `PtcRunner.Kernel.HostConfig` owns Streamable HTTP endpoints, static
  authentication, and credential references.
- `PtcRunner.Kernel.HostInstallation` has a staged prepare, preflight,
  credential-resolution, and acquisition barrier.
- `PtcRunner.Kernel.MCPRequestContext` owns each acquired HTTP endpoint and
  serializes request admission and shutdown.
- `PtcRunner.Kernel.MCPSource` already enforces fixed endpoints, HTTPS outside
  loopback tests, no redirects, bounded headers and bodies, deadlines, closed
  errors, and effect-aware dispatch provenance.
- `PtcRunner.Kernel.RunBuilder` completes provider acquisition before workflow
  or mission evaluation starts.

An isolated dependency probe using the root project's direct dependency
constraints established:

- `oidcc 3.7.2` resolves and compiles with the project's declared Elixir
  `~> 1.15` baseline, while `oidcc 3.8.0` requires Elixir `~> 1.17`;
- `oidcc` can load GitHub's MCP-specific OpenID-shaped metadata and can build
  an S256 authorization URL with the MCP `resource` parameter. The
  2026-07-29 probe also found that GitHub omitted
  `code_challenge_methods_supported`, so the final MCP profile requires
  PtcRunner to reject that provider until its metadata advertises `S256`;
- `oidcc 3.7.2` nevertheless requires OpenID-only metadata fields such as
  `jwks_uri`, `subject_types_supported`, and
  `id_token_signing_alg_values_supported`, so it cannot be the generic decoder
  for a conforming RFC 8414 OAuth-only authorization server without synthetic
  OIDC data;
- `assent 0.3.1` resolves and compiles beside the current `req 0.6.3`, and its
  generic OAuth 2 strategy produces cryptographically random state, a
  128-byte verifier, S256 PKCE, and an authorization URL carrying the exact
  resource indicator;
- the pinned Req/Finch/Mint stack exposes Mint's separation between a
  connection address and explicit `hostname` used for the Host header, SNI,
  and certificate verification. This makes the required resolve, classify,
  pin-approved-address, and preserve-original-hostname SSRF defense
  implementable without replacing the HTTP stack.

Use `assent ~> 0.3.1` narrowly for authorization-code/PKCE parameter
construction, token response normalization, and refresh grant construction.
Do not use its provider strategies, client-authentication construction,
user-info fetching, automatic browser behavior, or default HTTP adapter.
PtcRunner's bounded adapter owns token-endpoint authentication. In particular,
it form-encodes the client ID and secret independently before constructing
RFC 6749 `client_secret_basic`; Assent 0.3.1's raw `client_id:client_secret`
concatenation is not suitable for credentials containing reserved or non-ASCII
characters.

Route every Streamable HTTP network operation through a PtcRunner-owned Req
adapter implemented directly on the already-pinned Mint client, including
credential-free, static-authentication, and OAuth installations. It must not
delegate MCP, OAuth discovery, registration, or token requests to `Req.Finch`:
Finch publishes the complete request, including static/OAuth headers and tool
payload bodies, to global Telemetry events. This also closes the existing gap
between `MCPSource`'s documented telemetry-redaction contract and its current
Req.Finch implementation. The adapter must retain PtcRunner's no-redirect
policy, TLS verification, timeouts, response ceilings, content-type checks,
closed errors, address pinning, and connected-peer validation while emitting
only redacted PtcRunner-owned telemetry. PtcRunner remains responsible for MCP
challenge parsing, RFC 9728 Protected Resource Metadata, RFC 8414/OIDC
discovery fallbacks, RFC 8707 resource binding, RFC 9207 issuer checks, client
registration, scope policy, token storage, refresh serialization, and
transport integration.

`ExMCP.Authorization` is a useful interoperability oracle, not a dependency.
Its full MCP/ACP stack and automatic `401/403 -> authorize -> retry` transport
policy conflict with PtcRunner's smaller protocol surface and write-failure
safety.

Before the first implementation commit adopts Assent, repeat the dependency
probe in the repository and add a focused adapter test against a local token
endpoint. If Assent's public API cannot perform code exchange and refresh
through the bounded adapter without user-info calls or secret-bearing errors,
keep its PKCE/state construction as the reference and implement the small
form-encoded token requests through the same PtcRunner-owned Req/Mint adapter.
Do not add a second OAuth client library to compensate.

## Planned host authority

OAuth configuration belongs only to a Streamable HTTP installation. Normalize
an omitted `auth` field and an explicit `"auth": []` to the same empty value,
then preserve three explicit modes: `none` when normalized `auth` is empty and
`oauth` is absent, `static` when `auth` is non-empty, and `oauth` when the new
block is present and normalized `auth` is empty. Non-empty static `auth` and
`oauth` are mutually exclusive; both omitted and explicit-empty
authentication remain valid credential-free installations.

The planned shape is:

```json
{
  "credentials": {
    "mcp_oauth_secret": {"env": "MCP_OAUTH_CLIENT_SECRET"}
  },
  "install": {
    "github": {
      "source": "mcp",
      "transport": {
        "type": "streamable_http",
        "endpoint": "https://example.invalid/mcp",
        "oauth": {
          "issuer": "https://authorization.example.invalid",
          "resource": "https://example.invalid/mcp",
          "scope_ceiling": ["repository:read", "offline_access"],
          "refresh_access": "when_supported",
          "authorization_timeout_ms": 300000,
          "unknown_expiry_ttl_ms": 300000,
          "network": {
            "additional_origins": [],
            "private_network_origins": []
          },
          "client": {
            "registration": "pre_registered",
            "client_id": "ptc-runner-local",
            "token_endpoint_auth_method": "client_secret_basic",
            "client_secret_binding": "mcp_oauth_secret",
            "redirect_uris": ["http://127.0.0.1:8765/callback"]
          }
        }
      },
      "tools": {
        "get_file": {"as": "github.get-file", "effect": "read"}
      }
    }
  }
}
```

Exact key names may change during schema implementation, but the authority
contract may not:

- `issuer` is one strictly validated but unmodified HTTPS issuer identifier
  pinned by the operator. It has a host, may have a path, and has no userinfo,
  query, or fragment. Protected Resource Metadata must advertise that exact
  retained string. Comparisons do not case-fold, remove ports or trailing
  slashes, decode percent escapes, or otherwise normalize it. Multiple
  advertised authorization servers do not create ambient choice.
- `resource` is the exact normalized HTTPS MCP endpoint used for the initial
  unauthenticated request and every authenticated MCP request. The operator
  pins it through the endpoint; if the host schema also exposes a `resource`
  field, that field must normalize to the same identifier or decoding fails.
  Discovered metadata and every RFC 8707 resource parameter must match it, so a
  token obtained for one audience is never sent to a different endpoint.
- `scope_ceiling` is a duplicate-free, bounded host list and may be empty.
  It is the maximum set PtcRunner may request, not the set it requests
  unconditionally. A manifest cannot add or replace it. If both the initial
  challenge and Protected Resource Metadata omit scopes, PtcRunner omits the
  authorization `scope` parameter and the empty ceiling remains valid, except
  for the separately authorized refresh-access policy below;
- `refresh_access` is the closed host-owned policy `none` or
  `when_supported`, defaulting to `none`. `when_supported` may add
  `offline_access` to an authorization request only when validated
  authorization-server metadata advertises that scope and `scope_ceiling`
  contains it. Resource challenges and Protected Resource Metadata need not
  advertise `offline_access`. A manifest or remote server cannot enable the
  policy, and absence of either metadata support or ceiling authority leaves
  it omitted;
- `authorization_timeout_ms` is a bounded host-only ceiling for the explicit
  interactive operation and is separate from the MCP installation request
  timeout;
- `unknown_expiry_ttl_ms` is a bounded, conservative local usability window
  for an access token whose response omits `expires_in`. It does not assert
  that the server-side token expires at that time;
- a public client has no secret; a confidential client's secret is a normal
  host credential binding resolved through the bounded just-in-time resolver
  only immediately before code exchange or refresh. Its binding identifier is
  deliberately excluded from `HostInstallation`'s prepared
  `credential_names`, so `RunBuilder`'s global credential barrier never
  resolves or retains the secret. Loading or using an unexpired stored grant
  must not call the resolver or require that secret to be currently available;
- every pre-registered client declares its exact
  `token_endpoint_auth_method`. The first implementation supports `none` for a
  public client and `client_secret_basic` for a confidential client;
  `client_secret_post` and key-based methods are deliberately unsupported.
  Validated authorization-server metadata must advertise the selected method,
  applying RFC 8414's default of `client_secret_basic` when the metadata field
  is absent;
- redirect URIs are an exact host allowlist, validated without userinfo, query,
  or fragment. Production callbacks use HTTPS. A local interaction may use
  only loopback HTTP with an exact port and path;
- client IDs and redirect URIs are configuration, not secrets, but remain out
  of the safe connector snapshot because they do not describe tool behavior;
- authorization-server endpoints obtained from validated metadata for the
  exact pinned issuer must be HTTPS. Same-origin endpoints are accepted by
  default; every additional metadata or endpoint origin must appear in an
  exact host allowlist; and
- all discovery and OAuth egress uses the network policy described below.
  Private, loopback, link-local, multicast, and reserved addresses are denied
  by default. An operator may install exact origins as private-network
  exceptions for an enterprise deployment or deterministic local test.

Add the following registration modes in order:

1. **Pre-registered client:** explicit client ID, exact supported token
   endpoint authentication method, corresponding optional secret binding, and
   exact redirect allowlist. This is the first interoperable slice.
2. **Client ID Metadata Document:** the HTTPS metadata URL is the client ID.
   Use it only when authorization-server metadata advertises
   `client_id_metadata_document_supported: true`. Require an HTTPS URL with a
   non-root path and no userinfo, fragment, query, or dot-segment path
   components before normalization. Fetch it with the same network and
   document bounds, require exact document `client_id` equality, and require at
   least `client_id`, `client_name`, and `redirect_uris` with the installed
   redirect URI present. The first implementation supports CIMD public clients
   only: `token_endpoint_auth_method` must be explicitly `none` because RFC
   7591 defaults an omitted value to `client_secret_basic`. Secret fields,
   symmetric client authentication, `jwks`, `jwks_uri`, and other unsupported
   key-based authentication metadata fail closed. If `grant_types` or
   `response_types` is present, require `authorization_code` and `code`
   respectively; accept omission only under the applicable RFC 7591 defaults.
   A CIMD client is refresh-eligible only when its explicit `grant_types`
   contains `refresh_token`; the omitted default is authorization-code-only.
   Therefore `refresh_access: when_supported` adds `offline_access` for CIMD
   only when both the client document and authorization-server metadata
   explicitly support refresh.
3. **Dynamic Client Registration fallback:** use only when advertised and
   explicitly enabled by the host. The first implementation registers public
   clients with `token_endpoint_auth_method: "none"` only; confidential DCR is
   deferred rather than introducing a second generated-secret lifecycle. Bind
   the returned client identity to the exact issuer and persist it through an
   authorization store that advertises encrypted durable-registration
   capability. The shipped transient in-memory store does not advertise that
   capability, so local CLI DCR fails before sending a registration request;
   embeddings must supply a suitable store. DCR is a compatibility fallback,
   not the default. A DCR client entry must contain only native loopback
   redirects or only remote HTTPS redirects; reject mixed-class allowlists and
   require distinct client entries when an embedding needs both. Send
   `application_type: "native"` for the former and `"web"` for the latter,
   along with `authorization_code`, `code`, the exact redirect URI set, and
   `token_endpoint_auth_method: "none"`. Always request
   `grant_types: ["authorization_code"]`; add `"refresh_token"` only when
   validated authorization-server metadata explicitly lists refresh-token
   support. Omitted `grant_types_supported` uses RFC 8414's default and
   therefore does not authorize registering refresh. Request
   `response_types: ["code"]`; validate returned client identity,
   authentication method, issued-at metadata, absence of a client secret, and
   every bounded response field. Discard any registration-management token
   because update/delete management is not supported. Treat an incompatible
   response or rejection as closed rather than silently changing redirect URIs
   or application type. Never retry a possibly dispatched registration POST;
   record it as `registration_indeterminate` for explicit operator resolution
   because the server may already have created a client. Creation holds a
   store-backed exclusive lease for the exact registration key. It reloads
   after acquiring the lease, persists `not_dispatched` then `dispatched`
   provenance before handing the request to the adapter, and conditionally
   commits the returned client identity against the lease and starting
   version. A proven pre-dispatch failure may release the empty state; any
   possibly dispatched failure or owner death leaves an indeterminate record
   after lease expiry. Another node must use the committed registration or
   fail closed on the indeterminate state, never send a concurrent duplicate
   registration.
4. **Manual registration input:** embedding applications may provide an
   already-registered client through the same validated pre-registration
   structure. No arbitrary callback can mutate a loaded host document.

The implementation must update `PtcRunner.Kernel.HostConfig`, generated
`priv/schemas/ptc-host-config.schema.json`, host configuration documentation,
and safe `mix ptc.run --check` output together.

## Principal and storage boundary

Define a public authorization context supplied by the host application when it
constructs the host registry. It contains:

- a bounded opaque `tenant_id`;
- a bounded opaque `principal_id`;
- an authorization-store module and opaque adapter state; and
- an interaction adapter used only by an explicit authorization operation.

The local command uses fixed opaque local tenant/principal identifiers. A
future service constructs a fresh context from its authenticated request and
must never infer it from MCP data, a manifest, process dictionary state, or
global application environment.

Trusted direct embedding uses the same context and public OAuth authority
struct with `MCPSource.builder/1`. The embedding application completes an
explicit authorization through the callback-agnostic API before provider
build, then supplies the resulting context/authority pair to the common
builder. `HostInstallation.registry/2` validates host JSON into that same
authority struct and passes the caller-supplied context to the builder. Neither
entry point may construct a parallel token manager, request context, or HTTP
transport.

Grant storage is keyed by at least:

```text
{tenant_id, principal_id, resource, issuer, client_id, authority_fingerprint}
```

Client registrations are stored separately and keyed by the exact issuer plus
a hash of the registered client metadata. Changing issuer, resource, client
ID, token endpoint authentication method, redirect allowlist, scope ceiling,
refresh-access policy, or `unknown_expiry_ttl_ms` changes the authority
fingerprint and cannot reuse the old grant. There is one current grant per
stable authority key. Its versioned record separately
contains `requested_scopes`, as either `:omitted` or the normalized accumulated
set PtcRunner sent, and `granted_scopes`, as either `:unreported` or the
normalized actual set. Pending flows retain both the exact requested
representation and the exact scope set required by the operation that caused
authorization, plus the begin-time grant and authorization-requirement
versions.

If an authorization-code token response contains `scope`, normalize and store
that actual granted set. When the request sent a scope set, reject returned
members outside either that set or the installed ceiling. When the request
omitted `scope`, accept reported server defaults only within the installed
ceiling. If an explicitly scoped request receives no response `scope`, OAuth
defines the grant as the requested set, so store that set. If both request and
response omit `scope`, store `granted_scopes: :unreported`, never an invented
empty set. Such a grant may serve an operation with no explicit scope
requirement, but it cannot prove containment of a later required set.
Before initial or later authorization succeeds, a known resulting grant must
contain every scope in the pending flow's required set. A reported subset that
does not satisfy that set is not stored as a usable grant and returns the
closed authorization-required cause; this prevents a successful-looking
authorization immediately failing the operation that triggered it.

When `granted_scopes` is known, every refresh request sends exactly that
current set, preventing a later refresh from silently restoring the broader
original grant after an earlier narrowing. Only a genuinely `:unreported`
grant omits `scope`, because the client cannot safely invent the server's
default set. Refresh never changes `requested_scopes`. A refresh response that
omits `scope` retains the exact set sent, or remains `:unreported` when none
was sent. A reported refresh scope may retain or narrow the sent known set and
may not add a member beyond that set or the installed ceiling. When the prior
set was `:unreported`, a newly reported set becomes known only when every
member is inside the installed ceiling; the authorization server remains
responsible for the OAuth prohibition on refresh-time expansion that the
client cannot reconstruct from an unreported default. Atomic record
replacement updates tokens and both scope representations under the same
stable key. Request selection checks a known grant contains every explicitly
required scope; `:unreported` triggers explicit authorization when such a
requirement exists.

Runtime `insufficient_scope` challenges are stored as a bounded,
principal-bound, expiring host-only requirement record under the stable
authority key. The record contains only normalized required scope names and
validated authorization metadata identity plus the exact source grant
generation, never tool arguments, model data, provider error text, or token
material. Its atomic upsert reloads the current grant: it discards a stale
challenge when a newer known grant already contains every required scope,
otherwise it unions the requirement within the installed ceiling. An unknown
grant cannot prove satisfaction and retains the requirement. An explicit
`begin_authorization` atomically creates at most one live pending flow for the
stable grant key and snapshots both the current grant version and requirement
version. Another begin fails closed while that flow is live. Terminal
completion, denial, cancellation, or expiry atomically releases the slot.
Completion acquires the grant mutation lease, reloads both records, and
commits only if the grant still has the begin-time version; a refresh,
reauthorization, or deletion that changed it makes the flow stale and requires
a new explicit authorization. A successful grant commit consumes only
requirements satisfied by that exact flow and leaves any concurrently added
requirement in place.

Define a `PtcRunner.Kernel.MCPOAuth.Store` behaviour with:

- bounded load, put, and delete operations for pending flows, registrations,
  grants, and authorization-requirement records;
- an atomic requirement upsert conditional on the observed grant generation,
  plus a transactional authorization commit that conditionally replaces the
  grant and consumes only requirements satisfied by the flow while preserving
  every concurrent requirement update. Requirement versions participate in
  both operations; an ordinary load followed by put or delete is forbidden;
- atomic single-flight creation per stable grant key and one-time consumption
  of pending `state` and PKCE material, with expiry recovery;
- compare-and-swap versioning for ordinary grant replacement; and
- one exclusive, bounded creation lease per registration key with persisted
  `not_dispatched`, `dispatched`, `completed`, and
  `registration_indeterminate` state plus conditional commit; and
- one exclusive, bounded mutation lease per grant key shared by refresh and
  reauthorization commit, so two nodes cannot spend the same rotating refresh
  token or replace a grant across an in-flight refresh. The lease identifies
  its exact starting record version. A refresh mutation records
  `not_dispatched`, `dispatched`, or `completed` provenance while the lease is
  held, and an atomic `begin_dispatch` transition persists `dispatched` before
  the refresh token is handed to the network adapter. Refresh completion and
  poisoning, and reauthorization commit, are conditional on both the lease
  identity and starting version.

The behaviour is the cloud seam. Persistent adapters must encrypt secrets at
rest. Every adapter must provide atomic refresh-token rotation, lease expiry
after caller failure, indeterminate-grant poisoning, and no secret values in
errors. The repository ships:

- an owner-process in-memory adapter for tests, explicit same-process local
  authorization, and examples; and
- no plaintext persistent token adapter.

A future hosted application may implement the behaviour with Postgres plus
KMS- or application-level encryption. That adapter, inbound authentication,
tenant administration, and distributed deployment remain outside this plan.
An audited cross-platform OS credential-store adapter may be added separately;
the new macOS-only `ex_keychain` package is not a portable core dependency.

Define a separate `PtcRunner.Kernel.MCPOAuth.CredentialResolver` seam in the
authorization context. It receives only an installed, prevalidated binding ID
and an absolute deadline, returns one redacted secret handle for the immediate
OAuth operation, and is callable both before `RunBuilder` starts and later by
the token owner. Refactor the current private host resolver behind this seam;
do not retain a confidential-client secret in the grant or token manager.
Local environment-backed resolution and embedding-application resolution use
the same contract. Resolver calls are bounded by the caller's remaining
deadline and expose only closed errors.

This means the initial CLI flow is explicit and same-process: the operator
asks `mix ptc.run` to authorize named OAuth installations before build, the
loopback callback completes, and the resulting in-memory grant is used for
that invocation. Persistent login is available to embedding applications that
supply a secure store, but PtcRunner will not silently place refresh tokens in
a user directory. A runtime step-up requirement can be used by a later
explicit authorization operation only when the embedding supplies a secure
persistent store. The transient local CLI reports the same closed
`mcp_authorization_required` result but does not claim that a later process can
recover a tool-specific challenge; its documented local flow is
pre-execution authorization from the initial discovery challenge.

## Authorization and request lifecycle

### Explicit authorization

Add a repeatable CLI option resembling:

```console
mix ptc.run MANIFEST --host-config ptc-host.json --authorize-mcp github
```

Exact spelling is settled with the Mix task implementation. The command must:

1. load and validate the host document;
2. reject aliases that are absent, non-MCP, stdio, or statically
   authenticated;
3. validate and select only the named installation's OAuth client credential
   binding without resolving its secret;
4. discover and validate metadata under the authorization deadline and byte
   ceilings;
5. start an exact loopback callback before constructing the authorization URL;
6. create cryptographically random state and an S256 verifier, store them with
   a short deadline, and open or print the authorization URL;
7. accept one callback on the exact path, reject duplicate parameters, compare
   `state` without timing leakage, and consume the pending flow once. Redirect
   URI validation has already rejected fragments, which browsers do not send
   to the callback listener. Apply the final MCP RFC 9207 table to `iss`:
   require it when
   metadata advertises support, compare any present value to the recorded
   issuer using exact simple string comparison without URI normalization, and
   otherwise permit it to be absent;
8. acquire the stable grant key's mutation lease and reject the flow if its
   begin-time grant version is stale, then resolve a confidential-client secret
   immediately before code exchange. Use it only to exchange the code with the
   same redirect URI, verifier, resource, and client identity, and release the
   handle after the exchange completes;
9. validate and store the bounded token response. Once code exchange might
   have been dispatched, timeout or response loss consumes the pending flow
   and requires a fresh explicit authorization; never retry the same code; and
10. stop the callback listener before provider acquisition begins.

Initial and refresh token responses must contain a bounded `access_token` and
a `token_type` equal to `Bearer` under OAuth's ASCII case-insensitive
comparison. Missing or other token types fail before grant storage. Project
only `access_token`, optional `refresh_token`, optional `expires_in`, optional
`scope`, and the validated token type into the private grant representation.
Discard `id_token` and every unknown response member immediately after bounded
decode, without decoding claims or allowing those values into storage, owner
state, logs, errors, inspection, or tracing. Assent output is an intermediate
untrusted value, not a structure that may be retained wholesale.

Use a PtcRunner-owned single-shot loopback listener rather than Bandit. Bandit
publishes the pre-Plug `Plug.Conn`, including the authorization code and state
query, to global Telemetry before application redaction is possible. The
listener implements only a bounded HTTP/1 `GET` callback: bind only
`127.0.0.1` or `::1`, require an exact port and path from the installed
redirect allowlist, cap the request line, headers, query bytes, and parameter
count, reject transfer/content bodies and extra requests, return a fixed
success/failure page, and stop after one terminal callback or deadline. It
must not emit request targets, queries, headers, or owner state through
Telemetry, Logger, inspection, or process status. Browser launching is
best-effort. The explicit foreground authorization operation may present its
one-time URL to the invoking user so headless use remains possible. That URL is
the sole CLI-output exception for authorization material and may contain only
the validated authorization endpoint plus `response_type=code`, client ID,
exact redirect URI, requested scope when present, exact resource, S256
challenge/method, and random state. It contains no authorization code, verifier,
token, client secret, or provider response. Never copy it to Logger, Telemetry,
traces, inspection, snapshots, shell history, background status, or retained
artifacts; all other CLI output remains redacted.

Interactive authorization has a separate host-owned absolute deadline because
human browser interaction is not an MCP request. Network discovery, secret
resolution, callback wait, code exchange, and cleanup all consume that one
budget and receive only its remaining time. The installed value has a bounded
default and maximum; neither a manifest nor an MCP server can extend it.

The program does not start compiling, acquiring MCP catalogs, invoking a
model, or evaluating Kernel code until every requested authorization operation
has completed. Without a usable stored grant or an explicit authorization
request, an OAuth installation fails acquisition with a stable
`mcp_authorization_required` cause.

Embedding applications receive callback-agnostic `begin_authorization/3` and
`complete_authorization/3` operations. A future Phoenix controller can use
those operations with an HTTPS callback without importing the local listener.

### Discovery

Implement the final MCP discovery sequence:

- send one bounded unauthenticated `server/discover` POST to the installed
  resource using the final MCP request headers and client `_meta`, within the
  authorization deadline, and parse its bounded `WWW-Authenticate` challenge
  when it responds `401`;
- follow a validated `resource_metadata` URL when present;
- otherwise try the RFC 9728 well-known Protected Resource Metadata URL forms
  required by MCP;
- require exact resource equality and membership of the pinned issuer;
- try the required OAuth Authorization Server Metadata and OpenID discovery
  URL forms beneath the exact issuer;
- require exact issuer equality and reject redirects, downgrade, URL userinfo
  components, fragments, duplicate JSON keys, oversized documents, excess
  endpoints, and unknown critical values; and
- cache only non-secret validated metadata for its bounded HTTP freshness
  lifetime and never across a different issuer/resource pair. A new
  `WWW-Authenticate` challenge carrying `resource_metadata` always bypasses or
  revalidates the cached Protected Resource Metadata, even when the URL is
  unchanged and its prior freshness lifetime has not elapsed; a changed URL
  cannot reuse the previous entry.

Before any discovered fetch, apply an explicit egress policy. The default
allowlist contains only the installed resource and issuer origins; the host may
add exact HTTPS origins and exact private-network exceptions. Resolve every
hostname, reject the request if any candidate address is private, loopback,
link-local, multicast, or reserved without an exact exception, connect only to
an approved resolved address while preserving the original TLS hostname and
certificate validation, and verify the connected peer address before sending
the request. Reapply the checks on every new connection so DNS rebinding and
connection-pool reuse cannot bypass the decision. The loopback E2E harness
must opt in explicitly.

Scope selection follows the final MCP priority and the installed ceiling:

1. use the initial `WWW-Authenticate` `scope` set when present;
2. otherwise use Protected Resource Metadata `scopes_supported` when present;
3. otherwise omit `scope`;
4. treat a challenge set as authoritative for that operation even when it has
   no subset relationship with `scopes_supported`;
5. when host `refresh_access` is `when_supported`, add `offline_access` only
   when validated authorization-server metadata advertises it and the
   installed ceiling contains it, and for CIMD only when the client document
   explicitly declares the `refresh_token` grant; and
6. reject before browser interaction if the selected set contains a scope
   outside the installed ceiling.

An explicit later reauthorization unions the exact previously requested set
(or an empty set when it was `:omitted`) with the privately stored
authoritative challenge, only when every member remains inside the ceiling. A
token result must satisfy that required set before it can complete the flow.
Normal execution atomically records the private requirement but exposes only
the closed cause; it does not begin step-up or replay the request.

Only one live authorization flow exists per stable grant key. Reauthorization
holds the same per-key mutation lease as refresh from immediately before code
exchange through atomic grant commit and commits only against its begin-time
grant version. It may replace a completed or poisoned old version, while an
old refresh can neither complete nor poison the newly committed version; a
flow made stale by an intervening refresh or authorization fails closed
instead of overwriting the newer grant.

Metadata omission does not weaken the MCP profile. Before browser interaction,
validated authorization-server metadata must list `code` in
`response_types_supported`, must list `authorization_code` when
`grant_types_supported` is present, and must list `query` when
`response_modes_supported` is present. Omitted grant types use RFC 8414's
authorization-code/implicit default, and omitted response modes use its
query/fragment default; no other omission invents support. The client always
sends S256 PKCE, and authorization proceeds only when the metadata contains
`code_challenge_methods_supported` with `S256`. Missing metadata or an
incompatible field fails closed for both RFC 8414 and OpenID discovery.

### Token ownership and refresh

An acquired OAuth installation starts one `MCPOAuth.TokenManager` owner for its
exact grant key. It loads the grant through the store and provides a fresh
authorization header to `MCPRequestContext` before each admitted request.
Before every header issuance, within the request's absolute deadline, it loads
the current store version and either proves its cached generation is current
or replaces it with the newer stored grant. It never serves a cached access
token from a superseded generation. This mandatory check is the cross-process
and cross-node invalidation mechanism; an adapter may optimize it only with a
reliable subscription that preserves the same before-issuance guarantee.

The manager:

- treats access and refresh tokens as opaque bounded binaries;
- uses `System.monotonic_time/0` for in-process expiry decisions and stores
  UTC expiry only for persistence;
- treats an omitted initial `refresh_token` as an unrefreshable grant. The
  access token remains usable only until its known expiry or conservative
  local unknown-expiry deadline, then requires explicit authorization;
- computes that conservative deadline from the installed
  `unknown_expiry_ttl_ms` whenever a successful token or refresh response
  omits `expires_in`. If a refresh token exists, refresh may occur at that
  deadline; otherwise the grant becomes authorization-required. A `401` may
  invalidate it earlier, while no local timer claims the server-side token has
  expired;
- refreshes before expiry using a small fixed skew;
- takes the store's exclusive mutation lease in refresh mode, reloads the
  current version, refreshes once, and atomically replaces both access and
  rotated refresh tokens;
- preserves the previous refresh token only when a successful response omits
  a replacement, and never restores an older token after rotation;
- deletes or marks the grant unusable on `invalid_grant`;
- marks the grant `refresh_indeterminate` before releasing the lease whenever
  a refresh may have reached the authorization server but no valid response
  was received. It never retries or restores that refresh token, even after
  lease expiry; a new explicit authorization is required;
- never logs provider bodies or token endpoint messages; and
- has constant redacted OTP status and owner-linked cleanup.

The token manager persists the lease's `dispatched` state before handing the
refresh token to the bounded Req adapter, which never retries token POSTs. The
adapter reports whether a failure was definitely pre-dispatch or possibly
dispatched. A proven pre-dispatch failure may atomically restore the unchanged
active grant; any other timeout, connection loss, cancellation, malformed
response, or server error poisons it while the lease is still held. Owner death
after the pessimistic transition, including death before or during the socket
write, causes lease expiry to produce `refresh_indeterminate` instead of making
the old refresh token available again.

`MCPRequestContext` must obtain dynamic authorization headers through this
owner rather than freezing a bearer header during acquisition. Credential-free
and static modes keep their existing header semantics, but all three modes use
the same non-leaking Req/Mint transport adapter. At admission, the request
context creates one absolute monotonic deadline for the whole MCP operation.
Store access, just-in-time secret resolution, refresh, header construction, and
MCP HTTP all receive only the remaining budget. Replace the implicit
five-second owner call with that remaining timeout, propagate cancellation to
every in-flight stage, and do not start the MCP HTTP dispatch after expiry.
OAuth work remains `:not_dispatched` for the MCP mutation state, but refresh
has its own dispatch provenance and poisoning rule described above.

The private header result includes the stable grant key and exact grant
version/token generation used for the request. It never enters events or
inspection output. A response-driven invalidation is compare-and-swap
conditional on that version so a delayed `401` from version N cannot
invalidate a concurrent refresh or reauthorization committed as version N+1.

### Authorization failures and replay

Proactive refresh may occur before any MCP method. Once an MCP HTTP request
begins:

- a `401` conditionally invalidates only the exact access-token generation
  used by that request and returns
  `mcp_authorization_required`;
- a `403` with `insufficient_scope` atomically records the private bounded
  authorization requirement while returning only
  `mcp_authorization_required`;
- no browser interaction or scope step-up begins automatically;
- `tools/call` is never replayed, regardless of declared read/write effect or
  server idempotency annotations; and
- a possibly dispatched write keeps `mutation_state: :indeterminate`.

Safe acquisition methods such as `server/discover` and `tools/list` may be
repeated only by a new explicit build after authorization succeeds. Do not
place an OAuth retry loop inside the generic HTTP request function.
Snapshot-identity `tools/call` is still a tool call and is never transparently
replayed.

## Implementation slices

### Slice 1: bounded OAuth primitives

- Add Assent and a tested direct Mint runtime constraint, then add the
  PtcRunner-owned Req/Mint adapter after repeating the compatibility probe.
  Do not rely on Req/Finch's transitive Mint dependency for a directly used
  public API.
- Migrate all existing Streamable HTTP modes to that adapter and preserve
  current JSON/SSE, cancellation, deadline, response-ceiling, dispatch
  provenance, and static-header behavior while closing Finch telemetry
  exposure.
- Implement exact retained issuer validation, normalized resource/redirect
  parsing, challenge parsing, Protected Resource Metadata,
  authorization-server discovery, token response validation, S256/state
  creation, and exact error closure.
- Add fixtures for OAuth-only RFC 8414 metadata and OpenID-shaped metadata,
  including GitHub's no-ID-token shape as a fail-closed missing-PKCE case until
  that metadata advertises S256.
- Prove no redirect, downgrade, endpoint substitution, unbounded body, error
  body, or secret-bearing exception escapes.

### Slice 2: authority and authorization context

- Add the closed host schema for OAuth, pre-registered public/confidential
  clients, pinned issuer/resource/scope ceiling, and redirect allowlists.
- Add the authorization context, store behaviour, in-memory adapter, opaque
  grant keys, pending-flow and authorization-requirement TTLs,
  compare-and-swap replacement, and shared grant mutation lease.
- Add the bounded just-in-time credential resolver usable before build and
  during delayed refresh.
- Keep host loading side-effect free. OAuth client-secret bindings never enter
  the existing bulk build/acquisition credential barrier; resolution occurs
  only immediately before code exchange or an admitted request's bounded
  token-refresh stage, never during host decode, preflight, or use of an
  unexpired grant.
- Extend safe check output only with the closed `none`, `static`, or `oauth`
  authorization mode; expose no account, scope, issuer, client, redirect, or
  token detail.

### Slice 3: explicit local and embedding flow

- Add callback-agnostic begin/complete APIs.
- Add the exact loopback interaction and explicit CLI authorization option.
- Use the single-shot callback listener with no request-bearing dependency
  telemetry; do not promote Bandit or Plug to root runtime dependencies for
  this flow.
- Add pre-registered and Client ID Metadata Document clients.
- Add bounded public-client Dynamic Client Registration only when a supplied
  store advertises encrypted durable-registration capability and after issuer
  binding and the per-registration creation lease/state machine are covered.
- Make denial, timeout, state mismatch, issuer mismatch, callback replay,
  browser-launch failure, and cleanup deterministic.

### Slice 4: token manager and MCP integration

- Add the per-grant token owner and proactive refresh.
- Extend the common `MCPSource.builder/1` and `MCPRequestContext` path with a
  closed no-auth, static-header, or validated OAuth-authorization-owner option.
  Every mode selects the PtcRunner-owned Req/Mint adapter rather than Req.Finch
  before any credential or tool payload is attached. Both host-configured and
  direct embedding installations use that same path and preserve
  active-request shutdown semantics; do not add a HostInstallation-only
  transport.
- Persist bounded private challenge requirements through the store contract;
  public provider errors remain closed.
- Add stable authorization-required provider causes without changing static
  authentication behavior.
- Prove no transparent `tools/call` replay and preserve write mutation
  indeterminacy.

### Slice 5: interoperability and durable documentation

- Add a credential-free local OAuth-protected MCP E2E using the official Go
  SDK server behind a deterministic authorization/resource-server harness.
- Run a manual conforming remote-MCP authorization experiment with a
  disposable test grant; retain only the redacted outcome and protocol facts.
- Update module docs, `docs/guides/host-configuration.md`, CLI help,
  README/getting-started material where appropriate, generated schemas, error
  documentation, and product readiness.
- Remove this plan after the implemented contract is durable and every
  accepted slice is complete.

Each slice receives its own clean independent challenge/review cycle and may
land separately. Later slices rebase on the earlier slice so each PR remains
reviewable.

## Verification

Focused tests must cover:

- strict host decoding and generated-schema agreement;
- fixed issuer/resource/scope/redirect authority and manifest inability to
  widen it, including closed refresh-access policy decoding and
  `offline_access` constrained by both authorization-server metadata and the
  installed ceiling, plus persisted-grant invalidation when
  `unknown_expiry_ttl_ms` changes;
- RFC 9728 challenge and well-known fallback discovery;
- RFC 8414 and OpenID discovery URL variants with exact issuer checks;
- authorization-server flow compatibility, including required `code`, present
  grant-type support for `authorization_code`, present response-mode support
  for `query`, their allowed RFC 8414 omission defaults, and S256;
- unmodified issuer retention plus rejection of userinfo, query, fragment, and
  case/port/slash/percent-encoding near matches;
- pre-registration, Client ID Metadata Documents, DCR issuer binding, and
  registration persistence, including capability advertisement, exact CIMD
  identity/required fields and forbidden URL/authentication forms, transient
  store rejection before DCR dispatch, explicitly declared public `none`
  authentication with omission rejected, compatible present or defaulted CIMD
  grant/response types, CIMD refresh eligibility requiring an explicit
  `refresh_token` grant, native/web DCR application types,
  mixed-class redirect rejection, and conditional refresh-token registration
  from explicit authorization-server capability; concurrent creation,
  pre-dispatch recovery, persisted dispatch, owner death, conditional commit,
  and indeterminate-registration refusal;
- S256, state, callback issuer, one-time callback consumption, denial, and
  timeout, including rejection when PKCE metadata is absent; one live pending
  flow per grant key, reversed completion attempts from concurrent begins,
  pending-flow expiry recovery, and stale completion after refresh,
  reauthorization, or deletion;
- public and confidential token endpoint authentication;
- explicit `none` and `client_secret_basic` selection, authorization-server
  metadata compatibility/default handling, and identical authentication on
  code exchange and refresh, including reserved-character and non-ASCII client
  IDs and secrets through PtcRunner's RFC 6749 Basic encoder;
- exact endpoint/resource identity plus exact `resource` on authorization,
  code exchange, and refresh;
- mandatory case-insensitive Bearer `token_type` on initial and refresh
  responses, rejection of missing/other types, projection of only supported
  OAuth token fields, and immediate disposal/redaction of `id_token` and
  unknown response members;
- expiry skew, one refresh under concurrency, rotated refresh tokens,
  compare-and-swap conflicts, stable-key scope narrowing, safe proven
  pre-dispatch lease recovery, owner death before and after every persisted
  dispatch transition and socket write, response loss after server-side
  rotation, refresh-indeterminate poisoning, `invalid_grant`, and concurrent
  refresh versus reauthorization commit, plus omitted initial refresh tokens,
  retention of the current refresh token when a successful refresh omits a
  replacement both before and after an earlier rotation, omitted initial and
  refresh `expires_in`, conservative unknown-expiry deadlines, and two token
  managers or nodes proving the store version before header issuance so an
  unexpired superseded access token is never served;
- token and authorization-material redaction from inspect/status, Logger,
  Telemetry, traces, snapshots, inspection artifacts, CLI output, and every
  error path, except the deliberately presented one-time foreground
  authorization URL with its closed parameter set and no code, verifier,
  token, or secret. Attach handlers to the actual Finch and Bandit event
  prefixes during OAuth E2E and prove they receive no secret-bearing OAuth
  request or callback data; also inspect the PtcRunner adapter/listener's own
  events;
- no redirects and bounded challenge, metadata, token, and callback inputs;
- a new `resource_metadata` challenge bypassing a still-fresh cache entry,
  including both changed and unchanged metadata URLs;
- owner death and close during discovery, callback wait, refresh, and active
  MCP requests;
- one absolute MCP request deadline across admission, store access,
  just-in-time credential resolution, refresh, and HTTP dispatch, including
  configured ceilings above five seconds and cancellation at every stage;
- challenge, metadata, installed-ceiling, and narrowed token-response scope
  reconciliation; separate accumulated-requested and actual-granted sets;
  initial and later authorization refusal when the resulting known grant does
  not contain the pending operation's required set;
  omitted token-response `scope` after both explicitly scoped and unscoped
  requests; consecutive refreshes sending the current known narrowed set,
  scope omission only for `:unreported` grants, unknown default scopes;
  `offline_access` omitted by default, added only under host policy plus
  authorization-server advertisement and ceiling authority, and exercised
  with pre-registration, refresh-eligible and authorization-code-only CIMD,
  and DCR; principal-bound expiring requirement handoff into explicit
  reauthorization; atomic requirement upsert and authorization commit under
  both lost-update orderings; and delayed-generation `403` requirements racing
  refresh and reauthorization;
- public-address enforcement, DNS rebinding resistance, connected-peer
  validation, and exact private-network exceptions for discovery;
- unchanged credential-free and static bearer/basic/API-key behavior,
  including omitted and explicit-empty `auth` through host schema and runtime
  assembly, plus `oauth` coexisting only with normalized empty `auth`; run the
  complete JSON/SSE, cancellation, response-bound, and dispatch-provenance
  transport suite across no-auth, static, and OAuth modes through the common
  Req/Mint adapter;
- host-configured and direct-embedding OAuth using the same
  `MCPSource.builder/1`/request-context owner path, with no-auth, static
  headers, and dynamic authorization mutually exclusive; an unexpired stored
  grant must neither call nor require the client-secret resolver;
- exactly one upstream `tools/call` when the server responds `401` or `403`,
  including a possibly dispatched write, plus a delayed version-N `401`
  racing both refresh and reauthorization to version N+1; and
- explicit authorization completing before provider acquisition or model
  activity.

The local E2E authorization server must issue short-lived access tokens and
rotating refresh tokens, validate S256 and exact resource indicators, expose
both challenge-directed and fallback metadata discovery, and count MCP calls.
It must be deterministic and require no external credential. The protected MCP
endpoint must still use the official Go SDK protocol implementation so the test
does not merely prove an Elixir client against an Elixir imitation.

The live-provider experiment is a manual/scheduled interoperability check, not
the only acceptance gate. Select a remote MCP server whose validated metadata
advertises S256. It must prove authorization, catalog acquisition, one bounded
read call, proactive refresh when available, explicit reauthorization after
revocation, and zero secret material in trace and inspection outputs. Revoke
the disposable grant after the experiment. GitHub may be used after its
metadata advertises S256; until then, retain the 2026-07-29 result as a
fail-closed negative interoperability case rather than bypassing the final MCP
requirement.

Before every commit run `mix precommit`. Before every ordinary push rely on the
tracked pre-push hook. The final slice also runs the credential-free OAuth E2E,
the existing stateless MCP E2E, and the relevant published-package/archive
checks.

## Completion gates

This plan is complete only when:

- one OAuth-only and one OpenID-shaped authorization server pass the committed
  discovery and code-flow suite;
- a real OAuth-protected remote MCP server completes an explicit login,
  discovery, and bounded tool call;
- public clients, confidential clients, refresh rotation, and every supported
  registration mode pass;
- concurrent refresh cannot spend or restore an old refresh token;
- any possibly dispatched refresh with an indeterminate result poisons the
  grant and requires explicit reauthorization;
- normal execution never launches interaction or replays `tools/call`;
- multi-user tests prove two principals using the same installation cannot
  load, refresh, delete, or observe each other's grants;
- static authentication remains compatible;
- all secret-bearing state is redacted and all network/input bounds are
  enforced;
- the supported and deliberately unsupported OAuth profile is user-facing;
  and
- durable contracts have moved to module documentation and retained guides so
  this file can be deleted.

## Normative references

- [MCP authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)
- [MCP authorization-server discovery](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/authorization-server-discovery)
- [MCP client registration](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/client-registration)
- [MCP authorization security](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/security-considerations)
- [RFC 7636: PKCE](https://www.rfc-editor.org/rfc/rfc7636)
- [RFC 8414: Authorization Server Metadata](https://www.rfc-editor.org/rfc/rfc8414)
- [RFC 8707: Resource Indicators](https://www.rfc-editor.org/rfc/rfc8707)
- [RFC 9207: Authorization Server Issuer Identification](https://www.rfc-editor.org/rfc/rfc9207)
- [RFC 9728: Protected Resource Metadata](https://www.rfc-editor.org/rfc/rfc9728)
- [OAuth Client ID Metadata Document draft
  -00](https://datatracker.ietf.org/doc/html/draft-ietf-oauth-client-id-metadata-document-00)
