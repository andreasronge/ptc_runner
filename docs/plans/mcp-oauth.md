# MCP OAuth authorization

**Status:** active; dependency and architecture feasibility checked and scope
reduced 2026-07-29. Implement against the final MCP `2026-07-28`
authorization profile.

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
  `2026-07-28` authorization profile with pre-registered clients or Client ID
  Metadata Documents.
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
- Dynamic Client Registration. The final MCP profile deprecates DCR in favor
  of Client ID Metadata Documents, and its registration-creation recovery
  state machine is disproportionate to the first implementation. The
  trigger-gated compatibility work is retained in
  [`future/mcp-dcr.md`](future/mcp-dcr.md).
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
  an S256 authorization URL with the MCP `resource` parameter. An initial
  2026-07-29 appended-OpenID probe omitted
  `code_challenge_methods_supported`; a follow-up against the final MCP
  first-priority RFC 8414 URL found GitHub advertising `S256`. GitHub is
  therefore a positive live interoperability target, while missing-PKCE
  behavior remains covered by a deterministic synthetic fixture;
- `oidcc 3.7.2` nevertheless requires OpenID-only metadata fields such as
  `jwks_uri`, `subject_types_supported`, and
  `id_token_signing_alg_values_supported`, so it cannot be the generic decoder
  for a conforming RFC 8414 OAuth-only authorization server without synthetic
  OIDC data;
- `assent 0.3.1` resolves and compiles beside the current `req 0.6.3`, but the
  usable subset reduces to state and PKCE construction, form/query encoding,
  and token-field projection once PtcRunner retains ownership of provider
  discovery, client authentication, HTTP, validation, redaction, and storage;
- the pinned Req/Finch/Mint stack exposes Mint's separation between a
  connection address and explicit `hostname` used for the Host header, SNI,
  and certificate verification. This makes the required resolve, classify,
  pin-approved-address, and preserve-original-hostname SSRF defense
  implementable without replacing the HTTP stack.

Do not add Assent or another OAuth client library as a runtime dependency.
PtcRunner owns a small OAuth primitives module using OTP's
`:crypto.strong_rand_bytes/1`, `Base.url_encode64/2`, and
`:crypto.hash/2`, plus explicit `application/x-www-form-urlencoded`
construction and bounded token-response projection. The module generates
state and an S256 verifier/challenge, constructs authorization and token
parameters, and validates only the supported response fields. State and the
verifier are generated independently from exactly 32 cryptographically random
bytes each and encoded with unpadded Base64URL (`padding: false`), producing
separate 43-character RFC 3986 unreserved values. State is accepted back only
through constant-time comparison and one-time flow consumption. A verifier is
the independently generated 43-character value just described. Validate it
against the RFC's 43–128-character `code-verifier` grammar before it enters
pending state or a request; padding, non-unreserved bytes, and any other length
fail closed. The S256 challenge is the unpadded Base64URL encoding of the
SHA-256 digest of that exact ASCII verifier. This small surface is easier to
audit than retaining a security-sensitive dependency whose provider
strategies, client-authentication construction, user-info fetching, automatic
browser behavior, default HTTP adapter, and returned structures are all
prohibited here.

Endpoint construction preserves an already validated endpoint's unrelated
query bytes and ordering, then appends PtcRunner's canonically form-encoded
parameters. Before construction, a bounded query parser rejects malformed
percent encoding and any existing parameter whose decoded, case-sensitive name
collides with a protocol-owned name. For the authorization endpoint those names
are `response_type`, `response_mode`, `client_id`, `redirect_uri`, `scope`,
`resource`, `code_challenge`, `code_challenge_method`, `state`, `request`, and
`request_uri`. Request Objects and pushed/request-URI authorization are
unsupported because their values can override PtcRunner's visible state, PKCE,
resource, scope, and redirect parameters. This also rejects a pre-existing
response-mode override such as `fragment` or `form_post`; the supported absent
default remains query delivery to the exact GET callback. For the token
endpoint, an existing query parameter must not collide with `grant_type`,
`code`, `redirect_uri`, `code_verifier`, `refresh_token`, `client_id`,
`client_secret`, `scope`, or `resource`, even though PtcRunner sends token
parameters in the POST form body. Unrelated routing parameters remain
byte-for-byte intact; PtcRunner neither replaces them nor emits a second
protocol-owned parameter.

PtcRunner's bounded adapter owns token-endpoint authentication. In particular,
it form-encodes the client ID and secret independently before constructing RFC
6749 `client_secret_basic`; raw `client_id:client_secret` concatenation is not
suitable for credentials containing reserved or non-ASCII characters.
Assent and `ExMCP.Authorization` may be used only as development-time
interoperability oracles in isolated probes; neither enters the dependency
graph or credential path.

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

`ExMCP.Authorization` is likewise a useful interoperability oracle, not a
dependency.
Its full MCP/ACP stack and automatic `401/403 -> authorize -> retry` transport
policy conflict with PtcRunner's smaller protocol surface and write-failure
safety.

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
  "install": {
    "github": {
      "source": "mcp",
      "transport": {
        "type": "streamable_http",
        "endpoint": "https://example.invalid/mcp",
        "oauth": {
          "installation_id": "github-primary",
          "issuer": "https://authorization.example.invalid",
          "resource": "https://example.invalid/mcp",
          "scope_ceiling": ["repository:read", "offline_access"],
          "default_scopes": ["repository:read"],
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
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "loopback_redirect": {
              "host": "127.0.0.1",
              "path": "/callback"
            }
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
- `resource` is the canonical HTTPS MCP endpoint used for the initial
  unauthenticated request and every authenticated MCP request. Canonicalization
  lowercases the scheme and host, rejects userinfo and fragments, and retains
  resource-significant path, port, trailing-slash, and query distinctions.
  Query bytes are not reordered, decoded, or otherwise normalized.
  Uppercase scheme or host input is accepted for MCP interoperability and
  canonicalized before comparison. The operator pins the resource through the
  endpoint; if the host schema also exposes a `resource` field, both values
  must canonicalize to the same identifier or decoding fails. Discovered
  metadata and every RFC 8707 resource parameter must match that canonical
  identity, so a token obtained for one audience is never sent to a different
  endpoint.
- `scope_ceiling` is a duplicate-free, bounded host list and may be empty.
  It is the maximum set PtcRunner may request, not the set it requests
  unconditionally. A manifest cannot add or replace it;
- `default_scopes` is a duplicate-free bounded host list contained by
  `scope_ceiling`. It is used only when both the initial challenge and
  Protected Resource Metadata omit scopes. If all three sources are empty,
  authorization fails before browser interaction because PtcRunner cannot
  prove an authorization server's implicit defaults remain within the host
  ceiling. Every authorization request therefore sends an explicit non-empty
  scope set, and no usable grant has unreported authority. This is the named
  **MCP-OAUTH-EXPLICIT-SCOPE** PtcRunner interoperability deviation: the MCP
  profile otherwise says to omit `scope` when no source supplies one. The
  implementation must carry this deviation and rationale into durable
  user-facing OAuth documentation;
- `refresh_access` is the closed host-owned policy `none` or
  `when_supported`, defaulting to `none`. Refresh authority requires
  `when_supported` plus explicit `refresh_token` grant support in both
  validated authorization-server metadata and the installed client
  registration; RFC 8414's omitted `grant_types_supported` default does not
  include it. `offline_access` is an optional refresh scope, requested only
  when that complete pre-response refresh eligibility is true, the server
  advertises the scope, and the host `scope_ceiling` contains it. Its absence
  does not disable an otherwise supported refresh grant, and resource
  challenges and Protected Resource Metadata need not advertise it. A manifest
  or remote server cannot enable refresh policy;
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
- production redirect URIs are a bounded set of complete exact HTTPS URI
  strings, validated without userinfo, query, or fragment. Preserve each
  validated input byte-for-byte for registration comparison, authorization
  transmission, pending-flow binding, and authority fingerprinting; do not
  normalize host case, an omitted/default port, path percent-encoding, or any
  other spelling. Parse a separate safety view to require HTTPS, a valid host,
  and an allowed exact path and port. No approved host grants authority to
  another string spelling, path, or port. A local interaction instead installs
  one loopback-IP redirect descriptor with an exact `127.0.0.1` or `::1`
  literal and path, binds port `0`, and uses the operating-system-assigned
  ephemeral port in the authorization request. The registered loopback redirect and
  authorization request must match exactly except for the port as required by
  RFC 8252; `localhost` is rejected rather than treated as equivalent to a
  loopback IP literal. This native loopback form is supported only for public
  clients using `none`; confidential clients use an exact HTTPS redirect
  completed by their embedding application;
- client IDs and redirect authority are configuration, not secrets, but remain
  out of the safe connector snapshot because they do not describe tool
  behavior;
- authorization-server endpoints obtained from validated metadata for the
  exact pinned issuer must be HTTPS. Same-origin endpoints are accepted by
  default; every additional metadata or endpoint origin must appear in an
  exact host allowlist; and
- all discovery and OAuth egress uses the network policy described below.
  Private, loopback, link-local, multicast, and reserved addresses are denied
  by default. An operator may install exact origins as private-network
  exceptions for an enterprise deployment or deterministic local test.

Every scope-bearing input uses one shared parser before comparison or storage:
host configuration, `WWW-Authenticate`, Protected Resource Metadata,
authorization-server metadata, client metadata, token and refresh responses,
and private authorization requirements. Scope names are case-sensitive ASCII
and must match RFC 6749 `scope-token`
(`%x21 / %x23-5B / %x5D-7E`) byte for byte. List-shaped inputs contain at most
64 unique entries of 1–256 bytes each and are accepted only when their
deterministic space-joined serialization is at most 8 KiB. String-shaped OAuth
`scope` values have that same 8 KiB aggregate limit and must match
`scope-token *( SP scope-token)` with one ASCII space as the only separator:
leading, trailing, or repeated spaces, tabs, other whitespace, Unicode,
duplicates, an excessive token count, an oversized member, or an oversized
aggregate are rejected rather than reinterpreted. A normalized scope set means
only a duplicate-free set of those exact case-sensitive members; deterministic
serialization sorts their original bytes and joins them with one ASCII space.
No normalization case-folds or rewrites a member. The host's `scope_ceiling`
and `default_scopes` may be empty, but a present discovered
`scopes_supported` member in Protected Resource or authorization-server
metadata must contain at least one member. An empty discovered array is invalid
rather than authoritative or equivalent to omission, so it cannot bypass
`default_scopes` or produce a scope-less authorization request.

Add the following registration modes in order:

1. **Pre-registered client:** explicit client ID, exact supported token
   endpoint authentication method, corresponding optional secret binding,
   duplicate-free bounded `grant_types` containing `authorization_code`, and
   validated production redirects or one loopback redirect descriptor.
   `refresh_token` is optional and is the out-of-band registration assertion
   that makes this client refresh-eligible; PtcRunner never infers it from a
   returned refresh token. This is the first interoperable slice and covers
   providers such as Google that issue console-managed OAuth client credentials
   without DCR.
2. **Client ID Metadata Document:** the HTTPS metadata URL is the client ID.
   Use it only when authorization-server metadata advertises
   `client_id_metadata_document_supported: true`. Require an HTTPS URL with a
   non-root path and no userinfo, fragment, query, or dot-segment path
   components before normalization. Fetch it with the same network and
   document bounds and require exact HTTP `200`. After bounded media-type
   parsing, accept only
   `application/json` or an `application/*+json` structured-syntax subtype,
   with media type and subtype compared case-insensitively; reject every other
   type. Require exact document `client_id` equality and at least `client_id`,
   `client_name`, and `redirect_uris`. An installed HTTPS redirect must be
   present exactly; an installed native loopback descriptor must match one
   loopback-IP redirect in scheme, address literal, and path while ignoring
   only its registered port under RFC 8252. The first implementation supports
   CIMD public clients only:
   `token_endpoint_auth_method` must be explicitly `none` because RFC 7591
   defaults an omitted value to `client_secret_basic`. Secret fields,
   symmetric client authentication, `jwks`, `jwks_uri`, and other unsupported
   key-based authentication metadata fail closed. If `grant_types` or
   `response_types` is present, require `authorization_code` and `code`
   respectively; accept omission only under the applicable RFC 7591 defaults.
   Reject client metadata with `require_pushed_authorization_requests: true` or
   `dpop_bound_access_tokens: true` before interaction because the first
   implementation supports neither PAR nor DPoP; these client-side requirements
   receive the same fail-closed treatment as their server/resource equivalents.
   A CIMD client is refresh-eligible only when its explicit `grant_types`
   contains `refresh_token`; the omitted default is authorization-code-only.
   That client grant plus explicit authorization-server support controls
   refresh eligibility; `offline_access` remains optional and is requested only
   under the separate installed-ceiling rule above.
3. **Manual registration input:** embedding applications may provide an
   already-registered client through the same validated pre-registration
   structure. No arbitrary callback can mutate a loaded host document.

DCR configuration is rejected as unsupported by this plan. The deprecated
compatibility mechanism, its encrypted durable-registration capability, and
its creation lease/provenance state machine remain isolated in the
trigger-gated [`future/mcp-dcr.md`](future/mcp-dcr.md).

The implementation must update `PtcRunner.Kernel.HostConfig`, generated
`priv/schemas/ptc-host-config.schema.json`, host configuration documentation,
and safe `mix ptc.run --check` output together.

## Principal and storage boundary

Define a public authorization context supplied by the host application when it
constructs the host registry. It contains:

- a bounded opaque `tenant_id`;
- a bounded opaque `principal_id`;
- an opaque store-issued principal lifecycle epoch;
- an authorization-store module and opaque adapter state; and
- an interaction adapter used only by an explicit authorization operation.

The local command uses fixed opaque local tenant/principal identifiers. A
future service constructs a fresh context from its authenticated request and
must never infer it from MCP data, a manifest, process dictionary state, or
global application environment. Before constructing that context, the host
atomically claims the principal through the store. An existing active
`{tenant_id, principal_id}` claim is idempotent and returns its current epoch.
Deletion retires all principal state and leaves an epoch-bearing tombstone;
recreating the same principal ID receives a new epoch.

Trusted direct embedding uses the same context and public OAuth authority
struct with `MCPSource.builder/1`. The embedding application completes an
explicit authorization through the callback-agnostic API before provider
build, then supplies the resulting context/authority pair to the common
builder. Extend the existing `HostInstallation.registry/1` entry point by
explicitly introducing `registry/2`; the new arity validates host JSON into
that same authority struct and passes the caller-supplied authorization context
to the builder. Neither entry point may construct a parallel token manager,
request context, or HTTP transport. `registry/1` remains valid for hosts with
no OAuth installation and rejects an OAuth-bearing host with a closed
authorization-context-required error. The CLI explicitly constructs its fixed
process-local principal/context and calls `registry/2`; no embedding API
silently inherits that local identity.

Every installed OAuth authority has a bounded, host-assigned
`installation_id` that remains stable across authority edits and is never
derived from an MCP response or mutable installation alias. Host configuration
requires this explicit immutable ID inside the OAuth authority; direct
embedding supplies it explicitly. Renaming an alias retains the ID. Replacing
the logical installation uses the old ID's retirement operation before a new
ID becomes live. IDs are unique across all OAuth installations in a tenant:
host-document validation rejects duplicates, and direct embedding must
claim the current authority through the store before loading or creating grant
state. The store maintains a non-secret current-authority index
`{tenant_id, installation_id} -> {status, authority_fingerprint,
authority_epoch}`. Claiming an absent or retired entry activates it with a new
monotonic opaque epoch; claiming the same active fingerprint is idempotent and
returns that epoch so separate principals and processes may legitimately use
the installation; claiming a different active fingerprint returns a
collision/replacement-required error. Grant storage is keyed by at least:

```text
{tenant_id, principal_id, installation_id, resource, issuer, client_id,
 principal_epoch, authority_fingerprint, authority_epoch}
```

The authority fingerprint is a versioned canonical encoding of the complete
validated, default-expanded security authority rather than a selected field
list. It includes the installed resource endpoint; issuer and resource;
scope ceiling and defaults; refresh and expiry policies; authorization
deadline; every exact additional origin and private-network exception;
registration mode; client ID or CIMD URL; token endpoint authentication
method; normalized pre-registration grant types; confidential-client
credential-binding identifier; and every exact production or loopback redirect
field. Adding a new security-relevant authority field requires adding it to the
fingerprint in the same change.
Changing any of these values changes the fingerprint and cannot reuse the old
grant. Before a replacement authority becomes live, a persistent host uses a
fenced begin/drain/complete replacement protocol against the current-authority
index. Begin atomically marks the old epoch retiring and persists the exact
replace/release intent and rejects new ordinary state mutations, OAuth
credential-dispatch transitions, or MCP dispatch admissions. A bounded
coordinator lease lets the caller cancel owner-local work and wait outside
every owner for every distributed MCP admission and every already-dispatched
refresh or authorization-code mutation to return an acknowledged
transport-termination result. Conditional terminalization of an operation
already marked `dispatched` remains allowed only to acknowledge termination
and discard or poison its result under the retiring epoch; it cannot install a
grant. An operation deadline or lease expiry triggers cancellation and
recovery but is not evidence that a paused, partitioned, or disconnected
worker has stopped using its socket, so it cannot satisfy the drain. Recovery
requires a positive termination acknowledgement from the dispatch
owner/network task or operator-confirmed irreversible fencing of that worker
process; the first implementation has no unsafe force-complete path. The
durable intent is resumable: coordinator lease
expiry permits another authorized coordinator or maintenance worker to take
over, and
begin with the identical idempotency key returns the existing intent. A
conflicting intent fails closed; retirement never silently aborts back to
active. A future store extension may add a named cleanup sub-transition that
is authorized only by the durable retirement intent after normal work is
blocked and before completion; it must carry the retiring epochs and intent
identity and cannot create new authority. The initial implementation defines
no such cleanup transition because DCR is unsupported. Complete by the current
coordinator atomically retires every older
fingerprint for that tenant and stable installation ID across all principals
and installs the new fingerprint and epoch. Principal deletion uses the same
protocol, advancing its lifecycle epoch and retiring all grants, pending flows,
requirements, leases, MCP admissions, and OAuth credential-dispatch records
for that tenant/principal before the external identity is considered deleted.
The host must not publish the
replacement or report deletion complete until store completion succeeds. The
process-local CLI store needs no cross-process retirement because owner
shutdown destroys the entire store.
There is one current grant per stable authority key. Its record has a token
generation used for grant CAS and a separate non-secret metadata revision.
Token replacement, poisoning, or deletion advances the token generation;
metadata-only revalidation and response-driven access-token rejection do not.
The record has a nullable `access_rejected_generation` set atomically only when
a `401` names the exact current generation. The record contains
the exact normalized non-empty `requested_scopes` PtcRunner sent and exact
normalized `granted_scopes`. Its metadata revision retains the validated
Protected Resource Metadata resource identity, selected issuer membership, and
freshness deadline together with the authorization-server identity, token
endpoint, selected token endpoint authentication method, explicit
`refresh_token` grant support, and freshness deadline. For CIMD it also retains
the exact client-document identity, explicit client grant types, and freshness
deadline. The grant separately records non-secret `refresh_authorized`, true
only when host policy, installed client authority, and validated server
metadata permit refresh and the token response supplied a refresh token.
Refresh can therefore decide whether any part of the
resource-to-issuer-to-token-endpoint-to-client binding must be rediscovered
before any credential is dispatched. Pending flows retain the exact requested
and required scope sets, begin-time token generation, and
authorization-requirement versions. They also durably retain one bounded
non-secret validated begin-time binding: Protected Resource identity and
issuer membership; authorization-server issuer, authorization and token
endpoints, supported token authentication, explicit refresh support,
`authorization_response_iss_parameter_supported` decision, source identity,
and freshness; applicable CIMD identity, validated client fields, and
freshness; plus the exact client ID and redirect URI used by this flow. A
callback completed in another process or node therefore never depends on a
process-local metadata cache.

If an authorization-code token response contains `scope`, normalize and store
that actual granted set. When the request sent a scope set, reject returned
members outside either that set or the installed ceiling. When the request
receives no response `scope`, OAuth defines the grant as the requested set, so
store that set. PtcRunner never omits authorization scope and never stores an
unreported default grant.
Before initial or later authorization succeeds, a known resulting grant must
contain every scope in the pending flow's required set. A reported subset that
does not satisfy that set is not stored as a usable grant and returns the
closed authorization-required cause; this prevents a successful-looking
authorization immediately failing the operation that triggered it.

When `granted_scopes` is known, every refresh request sends exactly that
current set, preventing a later refresh from silently restoring the broader
original grant after an earlier narrowing. Refresh never changes
`requested_scopes`. A refresh response that omits `scope` retains the exact set
sent. A reported refresh scope may retain or narrow the sent known set and may
not add a member beyond that set or the installed ceiling. Atomic record
replacement updates tokens and both scope representations under the same
stable key. Request selection checks the grant contains every explicitly
required scope.

Runtime `insufficient_scope` challenges are stored as a bounded,
principal-bound, expiring host-only requirement record under the stable
authority key. The record contains only normalized required scope names and
validated authorization metadata identity plus the exact source token
generation, never tool arguments, model data, provider error text, or token
material. Its atomic upsert reloads the current grant: it discards a stale
challenge when a newer known grant already contains every required scope,
otherwise it unions the requirement within the installed ceiling. An unknown
grant cannot prove satisfaction and retains the requirement. A challenge for
the exact generation sent is authoritative even when that generation's token
response nominally reported the challenged scope. A delayed challenge is
reconciled with the complete stored requirement: only a strictly newer
generation reporting every member may clear it; otherwise it remains for
explicit reauthorization. The manager installs the corresponding exact
generation or scope-requirement fence before each response-driven store
round-trip. A persistence failure becomes a transport failure and cannot allow
the same manager to reissue that authority; only a strictly newer grant that
reports every required scope clears the process-local requirement fallback.
An explicit
`begin_authorization` atomically creates at most one live pending flow for the
stable grant key and snapshots both the current token generation and requirement
version. Another begin fails closed while that flow is live. Terminal
completion, denial, cancellation, or expiry atomically releases the slot.
Completion acquires the grant mutation lease, reloads both records, and
commits only if the grant still has the begin-time token generation; a refresh,
reauthorization, or deletion that changed it makes the flow stale and requires
a new explicit authorization. A successful grant commit consumes only
requirements satisfied by that exact flow and leaves any concurrently added
requirement in place.

Define a `PtcRunner.Kernel.MCPOAuth.Store` behaviour with:

- atomic principal claim and fenced begin/complete retirement operations.
  Claiming an active
  `{tenant_id, principal_id}` is idempotent and returns its current epoch;
  begin marks it retiring, and complete advances the epoch, leaves a tombstone,
  and removes all principal state only after both MCP-admission and OAuth
  credential-dispatch drains;
- atomic current-authority claim and fenced begin/complete replacement and
  release operations.
  Claim is idempotent only for the same
  `{tenant_id, installation_id, authority_fingerprint}`. Begin requires the
  expected old fingerprint and durably records the exact target action,
  expected epochs, and bounded idempotency key while marking the epoch
  retiring. A separately expiring coordinator lease serializes drain work;
  any authorized caller may inspect pending intents, acquire an expired lease,
  and resume them. Complete requires the durable intent, current coordinator
  lease, drained MCP and OAuth dispatch sets, and every intent-authorized
  cleanup completion, performs bulk retirement, and either
  installs the replacement fingerprint with a new epoch or leaves an
  epoch-bearing release tombstone. Delete-and-recreate therefore cannot
  produce an ABA match. Every pending-flow, requirement, grant load or
  mutation, lease acquisition, dispatch fence, and conditional completion
  carries both the principal epoch and authority fingerprint/epoch and
  atomically rejects a mismatch or retiring state. The only retiring-state
  exceptions are terminal acknowledgement/release or irreversible fencing of
  an already-issued MCP admission, conditional terminalization of an OAuth
  operation already durably marked `dispatched`, and a named cleanup
  sub-transition authorized by that exact durable retirement intent. None may
  admit new dispatch or publish a grant or new authority. Thus no stale runtime
  or authorization context can read or recreate retired state;
- an atomic bounded batch-claim operation for registry assembly. It validates
  the complete duplicate-free `{installation_id, authority_fingerprint}` set,
  returns every existing/new authority epoch only when all claims are
  compatible, and makes no index change when any member collides. Direct
  embedding of one installation uses the same operation with a singleton set;
- a bounded MCP dispatch-admission operation. Immediately before handing an
  authenticated MCP request to the network adapter, it atomically rechecks the
  principal epoch, active authority fingerprint/epoch, and exact token
  generation, and rejects that generation when its access-rejection marker is
  set, then requests an admission TTL no longer than the caller's remaining
  local request budget. The store stamps that admission using its authoritative
  clock. A token-generation mismatch returns
  `stale_before_dispatch` so the caller may reacquire a header without network
  replay; a marked generation returns `rejected_before_dispatch` so the caller
  enters the normal refresh or authorization-required path without sending the
  rejected header. Epoch or retiring-state mismatches fail closed. Non-token
  grant updates and recovery transitions preserve the marker until a fenced
  token mutation installs a new generation and clears it. A successful
  transport completion or acknowledged transport termination releases the
  admission. Admission runs in context-owned asynchronous work and the store
  associates it with the actual request worker. If that worker exits before
  receiving its header or before acknowledging release, the request context
  adopts the opaque release operation and retries it asynchronously;
  persistent adapters must not depend on local process monitoring for this
  transition. Provider close reports failure and leaves that cleanup owner
  running while release is unacknowledged rather than killing retry state.
  Its deadline is retained for cancellation and diagnosis, but
  expiry alone leaves a recovery-visible drain record. Begin-retirement
  prevents new admissions, and complete-retirement cannot succeed until every
  prior admission has supplied that acknowledgement or its worker has been
  irreversibly fenced as described above. Waiting and local cancellation run
  in callers, never inside a store, request-context, or token-owner callback;
- bounded enumeration and inspection of non-secret pending retirement intents
  so a maintenance worker can recover coordinator death without exposing
  principal identity beyond its already authorized tenant scope;
- bounded load, put, and delete operations for pending flows, grants, and
  authorization-requirement records;
- atomic bulk retirement by `{tenant_id, installation_id}` across every
  principal, by `{tenant_id, principal_id, installation_id}`, and by
  `{tenant_id, principal_id}`. Retirement covers every authority fingerprint
  and atomically invalidates grants, pending flows, requirements, and
  pre-dispatch mutation leases. A `dispatched` OAuth mutation remains as a
  drain record until acknowledged transport termination or irreversible worker
  fencing; its conditional terminalization discards or poisons any result
  without recreating retired state;
- an atomic requirement upsert conditional on the observed grant generation,
  plus a transactional authorization commit that conditionally replaces the
  grant and consumes only requirements satisfied by the flow while preserving
  every concurrent requirement update. Requirement versions participate in
  both operations; an ordinary load followed by put or delete is forbidden;
- an atomic generation-conditional access-token rejection operation that does
  not take or invalidate the refresh/reauthorization mutation lease and does
  not advance token generation. Header issuance refuses a current generation
  carrying its rejection marker. A successfully dispatched refresh or code
  exchange may still commit against its fenced starting generation and clears
  the marker when it installs the new generation; a delayed rejection for the
  old generation then becomes a no-op. This preserves one-use/rotating
  credential results without ever serving the rejected access token;
- atomic single-flight creation per stable grant key and a durable flow phase
  machine with expiry recovery. Callback acceptance makes the exact
  `pending_callback` flow `callback_consumed` once, consuming `state` while
  returning the PKCE verifier exactly once to the completing caller and
  retaining its bounded non-secret begin-time metadata binding and the minimum
  fenced phase/lease metadata needed to terminalize it; the authorization code
  remains only in that caller. Callback issuer validation always uses the
  persisted begin-time `authorization_response_iss_parameter_supported`
  decision. Before handing the code to the network adapter, the caller checks
  every binding freshness deadline. If any part is stale, it re-fetches the
  resource, server, and applicable CIMD documents outside the owner and
  requires exact equality of resource/issuer membership, client identity,
  authorization and token endpoints, token authentication, redirect authority,
  issuer-response decision, and flow-relevant grant support. Any incompatible
  change terminalizes the flow without dispatch and requires a new explicit
  authorization. Given an unchanged complete binding,
  `begin_code_dispatch` conditionally renews its freshness and atomically
  changes that same flow to `code_dispatched`; it verifies the exact pending
  flow, begin-time binding revision, authority epoch/fingerprint, lease, and
  starting token generation in the same transition. Cancellation may
  atomically change either pre-dispatch phase to `cancelled`, release the
  single-flight slot, and revoke that exact flow's matching
  authorization-mode mutation lease when it remains `not_dispatched`. The
  cancellation and dispatch transitions therefore have one atomic winner and
  cannot revoke a lease after code dispatch. Once `code_dispatched`,
  cancellation returns a distinct `code_dispatch_indeterminate` result and
  cannot claim that authorization was stopped or alter a later fenced
  completion. A caller that dies in `callback_consumed` leaves no reusable code
  and is terminalized by bounded recovery, which performs the same conditional
  lease revocation; a caller that dies after `code_dispatched` follows the
  existing no-retry, indeterminate-code-exchange recovery;
- compare-and-swap versioning for ordinary grant replacement; and
- one exclusive, bounded mutation lease per grant key shared by refresh and
  reauthorization commit, so two nodes cannot spend the same rotating refresh
  token or replace a grant across an in-flight refresh. The lease identifies
  its exact starting token generation. Callers request a relative TTL covering
  their remaining local operation budget; the store stamps expiry using its
  own authoritative clock and returns an opaque fencing identity, never a
  runtime-local monotonic timestamp. The store must grant the requested
  duration; inability to do so fails before any credential is dispatched.
  Refresh and
  authorization-code mutations record `not_dispatched`, `dispatched`, or
  `completed` provenance while the lease is held. Atomic fenced
  `begin_refresh_dispatch` and `begin_code_dispatch` transitions recheck the
  active lease identity, mode, starting token generation, and deadline, then
  persist `dispatched` immediately before the refresh token or one-use
  authorization code is handed to the network adapter. For refresh or code
  exchange after metadata revalidation, that same atomic transition also
  installs the complete validated non-secret Protected Resource,
  authorization-server, and applicable CIMD client-document binding as one
  metadata revision conditional on the authority fingerprint and the exact
  starting revision. Refresh binds `refresh_authorized` to that exact revision;
  code exchange renews only the matching pending-flow binding. There is no
  earlier metadata write and no token-generation change.
  Completion, poisoning where applicable, and reauthorization commit
  are conditional on that lease identity and starting token generation. No
  token-spending request may begin after its fence or lease has expired. Once
  marked `dispatched`, the durable mutation also participates in any matching
  principal/authority retirement drain. Retirement cannot complete merely
  because its mutation lease expires, and a retiring epoch permits only its
  fenced terminal acknowledgement with no grant commit.

The behaviour is the cloud seam. Persistent adapters must encrypt secrets at
rest. Every adapter must provide atomic refresh-token rotation, lease expiry
after caller failure, indeterminate-grant poisoning, and no secret values in
errors. All durable lease, metadata, token-usability, pending-flow, requirement,
and retirement deadlines use an adapter-authoritative clock. Persistent
adapters accept relative TTLs for store-owned budgets and stamp those deadlines
atomically with the mutation. For every lifetime derived from an external
response—token `expires_in` or metadata freshness—the caller first obtains an
opaque store-time anchor immediately before the outbound request. The fenced
commit supplies that anchor and bounded TTL; the store calculates expiry from
the anchor, debiting network, parsing, validation, and store latency, and
rejects a result already expired at commit. It never restarts the full lifetime
at commit. Adapters return only bounded remaining TTLs plus opaque time anchors
and fencing identities. They must not persist or compare
`System.monotonic_time/0` values from a BEAM node. On load after a node restart,
the adapter evaluates persisted deadlines against the same authoritative clock
and returns a clamped remaining TTL; the caller derives a fresh process-local
monotonic deadline. The in-memory adapter captures an owner-local monotonic
anchor before the request and never persists its values. The repository ships:

- an owner-process in-memory adapter for tests, explicit same-process local
  authorization, and examples; and
- no plaintext persistent token adapter.

A future hosted application may implement the behaviour with Postgres plus
KMS- or application-level encryption. That adapter, inbound authentication,
tenant administration, and distributed deployment remain outside this plan.
An embedding application using a persistent adapter must call the public
retirement operation transactionally with installation replacement and
principal deletion. PtcRunner documents this identity-lifecycle invariant
rather than silently retaining inaccessible credentials.
An audited cross-platform OS credential-store adapter may be added separately;
the new macOS-only `ex_keychain` package is not a portable core dependency.

Define a separate `PtcRunner.Kernel.MCPOAuth.CredentialResolver` seam in the
authorization context. It receives only an installed, prevalidated binding ID
and an absolute deadline, returns one redacted secret handle for the immediate
OAuth operation, and is callable both before `RunBuilder` starts and later by
the token owner. Do not widen or repurpose the public
`ProviderRegistry.credential_resolver` bulk callback: it keeps its current
`[binding_id] -> credential_values` build-barrier contract. Wire the separate
just-in-time resolver through the authorization context and the new
`HostInstallation.registry/2` integration instead. Refactor the current private
host resolver implementation so local environment-backed resolution and
embedding-application resolution can satisfy this new contract without
retaining a confidential-client secret in the grant or token manager. Resolver
calls are bounded by the caller's remaining deadline and expose only closed
errors.

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

Exact spelling is settled with the Mix task implementation. The command
supports both authorization before a normal run and
`--authorize-mcp NAME --check` in one invocation. In the combined form it
authorizes every named installation first, retains the grant only in that
process-local store, and then performs the existing real provider
acquisition/discovery check with that same store. Authorization failure stops
before the check. An authorization-only mode is not implied, and a later
process cannot reuse the transient grant.

The command must:

1. load and validate the host document;
2. reject aliases that are absent, non-MCP, stdio, or statically
   authenticated, and reject OAuth clients that are not public clients using
   `none` with an installed loopback-IP redirect descriptor. Confidential
   clients and exact HTTPS callbacks remain embedding-only and fail here
   before metadata discovery, credential resolution, or listener startup;
3. validate and select only the named installation's public OAuth authority;
4. discover and validate metadata under the authorization deadline and byte
   ceilings;
5. start an exact loopback callback before constructing the authorization URL;
6. create cryptographically random state and an S256 verifier, store them with
   a short deadline, and print the authorization URL for the operator to open;
7. accept one callback on the exact path, parse bounded parameters, reject
   duplicates of any recognized parameter, immediately discard unrecognized
   extension parameters without retention or logging, compare `state` without
   timing leakage, and apply the final MCP RFC 9207 table to `iss`: require it
   when
   the persisted begin-time metadata binding advertises support, compare any
   present value to the recorded issuer using exact simple string comparison
   without URI normalization, and otherwise permit it to be absent. Only after
   exact state/issuer validation,
   accept either a non-empty `code` with no `error`, or a non-empty OAuth
   `error` with no `code`. Both present, both absent, empty values, or duplicated
   recognized parameter names fail closed without changing the flow. The
   success shape atomically transitions the exact flow from
   `pending_callback` to `callback_consumed`; consume the stored `state` at
   that transition but retain the minimum phase/lease record until
   cancellation, dispatch, or completion makes the flow terminal. The error
   shape may contain only bounded `error_description` and `error_uri`; discard
   both without fetching, logging, or reflecting them and atomically
   terminalize the flow as denied without token dispatch. Redirect URI
   validation has already rejected fragments, which browsers do not send to
   the callback listener;
8. acquire the stable grant key's mutation lease and reject the flow if its
   begin-time token generation is stale. Revalidate any stale part of the
   persisted begin-time resource/server/client binding, requiring exact
   flow-relevant equality. Before handing the one-use code to the adapter,
   atomically cross the exact flow's fenced `begin_code_dispatch` transition;
   a stale or changed binding, stale generation, cancelled/expired flow,
   wrong-mode lease, or too-short lease fails without dispatch. Exchange the
   code using public-client method `none` with the same token endpoint,
   redirect URI, verifier, resource, and client identity;
9. validate and store the bounded token response. Once code exchange might
   have been dispatched, timeout or response loss consumes the pending flow
   and requires a fresh explicit authorization; never retry the same code; and
10. stop the callback listener before provider acquisition begins.

An embedding-provided HTTPS callback uses the same fenced completion and code
dispatch phases. For a supported confidential client only that embedding path
resolves the prevalidated credential binding immediately before exchange, uses
the secret handle for `client_secret_basic`, and releases it when the exchange
completes. The CLI algorithm never selects or resolves a client-secret binding.

Initial and refresh token responses must contain an `access_token` whose UTF-8
JSON string is 1–8,192 bytes and matches RFC 6750 `b64token` exactly: one or
more ASCII letters, digits, `-`, `.`, `_`, `~`, `+`, or `/`, followed only by
zero or more trailing `=` bytes. Reject controls, whitespace, non-ASCII bytes,
an empty value, and `=` anywhere except the trailing suffix before any grant
storage or header construction. A projected `refresh_token`, when authorized,
is likewise 1–8,192 bytes and matches RFC 6749 `1*VSCHAR`; form encoding
therefore never turns a control, Unicode value, or empty provider value into a
stored credential. `token_type` must equal `Bearer` under OAuth's ASCII
case-insensitive comparison. Every code-exchange and refresh request sends
`Content-Type: application/x-www-form-urlencoded` and
`Accept: application/json`. Success requires exact HTTP `200` and a bounded
JSON response with an `application/json` media type, allowing only an
explicitly validated UTF-8 charset parameter. A `201`, `202`, `204`, or any
other status never enters success-field projection. This negotiation is
mandatory for providers such as GitHub that otherwise default to form-encoded
token responses. Missing or other token types fail before grant storage. Project
only `access_token`, optional `expires_in`, optional `scope`, and the validated
token type into the private grant representation by default. Project an
optional `refresh_token` only when the flow's effective
`refresh_authorized` decision is true: host `refresh_access` is
`when_supported`; the installed client and validated authorization-server
metadata explicitly support `refresh_token`; and the response actually
supplies the token. Requesting `offline_access` can improve provider behavior
but occurs only after the host/client/server pre-response eligibility checks
and is not itself an eligibility prerequisite. An initial response that
supplies a refresh token without that authority has the token
immediately discarded and remains an access-token-only grant; token presence
alone never creates refresh authority. A refresh response is accepted only for
an already refresh-authorized fenced operation.
When present, `expires_in` must be a JSON integer in
`1..31_536_000` seconds; reject zero, negative, fractional, string, or larger
values before arithmetic or storage. Convert the already-bounded seconds to a
relative millisecond TTL with checked integer arithmetic. The fenced grant
commit derives durable expiry from the store-time anchor captured before the
token request, so response handling and commit latency can only shorten the
usable lifetime. It returns a bounded remaining TTL; a caller derives only a
process-local monotonic deadline from that value. The in-memory store uses its
pre-request owner-local monotonic anchor. Fail closed if the result is already
expired or any conversion cannot be represented. This fixed one-year maximum
is a PtcRunner local-usability policy, not a claim about the authorization
server's token lifetime.
Discard `id_token` and every unknown response member immediately after bounded
decode, without decoding claims or allowing those values into storage, owner
state, logs, errors, inspection, or tracing. The decoded response is an
intermediate untrusted value, not a structure that may be retained wholesale.

A token endpoint error is recognized only on exact HTTP `400` or `401` with
the same bounded `application/json` media-type rule and duplicate-member
rejection as success. Project only one required bounded `error` string matching
OAuth's error-code character grammar. Immediately discard
`error_description`, `error_uri`, every other response member, and all
authentication response headers without reflecting, logging, or retaining
them. A valid refresh `400 invalid_grant` atomically makes the grant unusable
and requires explicit authorization. Every other valid error after refresh
dispatch—including `401 invalid_client`—becomes `refresh_indeterminate`; the
spent refresh token is never restored or retried. Any valid error after code
dispatch terminalizes the pending flow and requires a fresh explicit
authorization; the one-use code is never retried. A non-200 success-shaped
body, non-400/401 error-shaped body, absent or wrong media type, duplicate
member, oversized body, malformed JSON, missing/invalid `error`, or any other
unexpected response follows the same possibly-dispatched poisoning or
terminalization rule rather than being interpreted by shape.

Use a PtcRunner-owned single-shot loopback listener rather than Bandit. Bandit
publishes the pre-Plug `Plug.Conn`, including the authorization code and state
query, to global Telemetry before application redaction is possible. The
listener implements only a bounded HTTP/1 `GET` callback: bind only
the installed `127.0.0.1` or `::1` literal on port `0`, read back the assigned
ephemeral port, and combine it with the exact installed path. Never accept or
resolve `localhost`, bind a wildcard interface, or silently switch IP family.
Cap the request line, headers, query bytes, and parameter count, reject
transfer/content bodies and extra requests, return a fixed success/failure
page, and stop after one terminal callback or deadline. It must not emit
request targets, queries, headers, or owner state through Telemetry, Logger,
inspection, or process status. Before parsing or consuming any callback
parameter, require one syntactically valid HTTP/1.1 `Host` field whose authority
exactly matches the runtime redirect's literal IP and assigned ephemeral port:
`127.0.0.1:PORT` or `[::1]:PORT`. Reject a missing, duplicated, malformed, or
mismatched authority and reject absolute-form request targets, so DNS rebinding
cannot consume the single-shot flow under another origin. Core and CLI code
never launch a browser:
placing the one-time URL in an `open`, `xdg-open`, or other child-process
argument would expose OAuth state through process status. The foreground
operation prints the URL once and waits on the already-started callback
listener; the operator opens it explicitly. An embedding may present the URL
inside its own trusted UI, without sending it through a subprocess argument.
That URL is the sole CLI-output exception for authorization material and may
contain only the validated
authorization endpoint plus `response_type=code`, client ID, exact runtime
redirect URI, requested scope when present, exact resource, S256
challenge/method, and random state. It contains no authorization code,
verifier, token, client secret, or provider response. Never copy it to Logger,
Telemetry, traces, inspection, snapshots, shell history, background status, or
retained artifacts; all other CLI output remains redacted.

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

Embedding applications receive callback-agnostic `begin_authorization/3`,
`complete_authorization/3`, and `cancel_authorization/3` operations. Cancellation
is idempotent and conditional on the principal epoch, authority epoch, and
opaque pending-flow identity. In either `pending_callback` or
`callback_consumed`, it atomically changes that exact flow to `cancelled`,
invalidates its code-dispatch fence, releases the single-flight slot, and
revokes its exact matching authorization-mode mutation lease when that lease
is still `not_dispatched`. A concurrent `begin_code_dispatch` has one atomic
winner: cancellation returns the idempotent cancelled result and immediately
unblocks another grant mutation when it wins, while cancellation after
`code_dispatched` returns `code_dispatch_indeterminate` because the code may
already have reached the token endpoint. The latter does not alter a grant, a
newer flow, or the fenced completion of the dispatched exchange. Failure
before the URL can be presented, premature listener termination while the flow
is still `pending_callback`, caller crash recovery, or operator cancellation
invokes this transition rather than relying on an unfenced in-memory flag.
Normal single-shot listener shutdown after it has atomically produced
`callback_consumed` is expected and must not cancel that flow. Bounded recovery
applies the cancellation transition to abandoned `callback_consumed` flows. A
future Phoenix controller can use these operations with an HTTPS callback
without importing the local listener.

### Discovery

Implement the final MCP discovery sequence:

- send one bounded unauthenticated `server/discover` POST to the installed
  resource using the final MCP request headers and client `_meta`, within the
  authorization deadline, and parse every bounded `WWW-Authenticate` field
  when it responds `401` using the shared Bearer challenge parser below;
- follow a validated `resource_metadata` URL when present;
- otherwise try the two RFC 9728 well-known Protected Resource Metadata URLs
  required by MCP in order. For
  `https://resource.example/a/b?tenant=one`, first try
  `https://resource.example/.well-known/oauth-protected-resource/a/b?tenant=one`,
  inserting the well-known component before the exact path and retaining the
  exact query, then try the root
  `https://resource.example/.well-known/oauth-protected-resource` candidate.
  A root-path resource de-duplicates identical candidates without changing
  order;
- canonicalize resource scheme and host case, then require exact canonical
  resource equality and membership of the pinned issuer. Protected Resource
  Metadata with `dpop_bound_access_tokens_required: true` fails before
  interaction because DPoP is outside the supported profile. Protected
  Resource Metadata containing `signed_metadata` also fails before any field
  from that document is used. RFC 9728 permits an implementation without signed
  metadata support to ignore that member and consume the plain fields, so this
  is a deliberate PtcRunner fail-closed interoperability restriction—not an
  RFC requirement—until JOSE signature and key validation are implemented;
- try authorization-server metadata URLs in the final MCP priority order. For
  an issuer such as `https://auth.example/tenant`, try
  `https://auth.example/.well-known/oauth-authorization-server/tenant`, then
  `https://auth.example/.well-known/openid-configuration/tenant`, then
  `https://auth.example/tenant/.well-known/openid-configuration`. For a
  root-path issuer, try the corresponding OAuth and OpenID root forms and
  de-duplicate identical candidates without changing order;
- treat a Protected Resource, RFC 8414, or OpenID metadata candidate as
  successful only when it returns exact HTTP `200`, has a `Content-Type` whose
  case-insensitive type and subtype are exactly `application/json` with no
  parameter except an optional validated UTF-8 charset, and passes the bounded
  JSON and semantic validation below. Never parse a non-200 or missing/wrong
  media-type body as metadata. A challenge-directed `resource_metadata` URL is
  authoritative and fails closed when that contract is not met. For an ordered
  well-known fallback, an unsuccessful candidate advances to the next exact
  candidate without following redirects; exhaustion fails closed. CIMD uses
  the same exact-200 rule and its separately defined JSON media-type allowlist;
- require exact issuer equality and reject redirects, downgrade, URL userinfo
  components, fragments, duplicate JSON keys, oversized documents, excess
  endpoints, and unknown critical values. Authorization and token endpoint
  queries use the bounded preservation-and-collision rules above; and
- cache only non-secret validated metadata for its bounded HTTP freshness
  lifetime, keyed by the current authority fingerprint and authority epoch in
  addition to the exact issuer/resource pair. Never reuse a cache entry across
  another fingerprint or epoch, even when issuer and resource match, because
  network exceptions, client authority, and redirect authority participate in
  metadata validation. A new
  `WWW-Authenticate` challenge carrying `resource_metadata` always bypasses or
  revalidates the cached Protected Resource Metadata, even when the URL is
  unchanged and its prior freshness lifetime has not elapsed; a changed URL
  cannot reuse the previous entry.
  `Cache-Control` parsing accepts at most one syntactically valid non-negative
  `max-age` across all field lines. A malformed or duplicate `max-age` is
  immediately stale and single-use rather than falling back to a default or
  selecting one conflicting value.

One shared bounded Bearer challenge parser handles both the initial discovery
`401` and runtime `401`/`403` authorization failures. It combines all
`WWW-Authenticate` field lines using RFC 9110 semantics and parses the actual
challenge/auth-parameter grammar rather than splitting on commas. It ignores
other authentication schemes. Initial unauthenticated discovery permits zero
Bearer challenges—whether headers are absent or contain only other schemes—and
then uses the ordered well-known Protected Resource Metadata fallback. One
valid Bearer challenge may supply scope or `resource_metadata`; malformed or
multiple Bearer challenges are rejected even when apparently identical.
Repeated auth-parameter names are rejected case-insensitively, so header
ordering cannot select a different scope or metadata URL. Runtime `401`
handling generation-conditionally marks the exact access token rejected before
and regardless of challenge parsing; malformed, missing, or ambiguous
challenge data cannot keep a server-rejected token reusable. A runtime `401`
may lack a usable challenge and still returns authorization-required after
marking the token. Runtime `403 insufficient_scope` requires exactly one valid
Bearer challenge before storing any requirement. Parsed parameters govern only
metadata and scope handling, and every stored requirement also passes the
installed-ceiling checks.

All OAuth JSON uses one bounded decoder that rejects duplicate member names
before projecting or validating any value. This applies identically to
Protected Resource Metadata, authorization-server metadata, CIMD client
documents, and initial and refresh token success/error responses; parser ordering can never
select among duplicate resource, issuer, client, authentication, scope, access,
or refresh-token fields.

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
2. otherwise use a valid non-empty Protected Resource Metadata
   `scopes_supported` when present; an empty present array invalidates that
   metadata rather than advancing to defaults;
3. otherwise use the installed `default_scopes`, failing before interaction
   when that list is empty;
4. treat a challenge set as authoritative for that operation even when it has
   no subset relationship with `scopes_supported`;
5. add `offline_access` only when host `refresh_access` is `when_supported`,
   both the installed client and validated authorization-server metadata
   explicitly support `refresh_token`, the authorization server advertises
   `offline_access`, and the installed ceiling contains it; and
6. reject before browser interaction if the selected set contains a scope
   outside the installed ceiling.

Step 3 is the **MCP-OAUTH-EXPLICIT-SCOPE** deviation defined with the host
authority above. A conforming MCP server may expect the client to omit `scope`
when all sources are silent; PtcRunner deliberately refuses that flow because
it cannot prove the server's implicit grant stays within the installed
ceiling. This restriction is documented as an interoperability limitation, not
as an MCP requirement.

An explicit later reauthorization unions the exact previously requested set
with the privately stored authoritative challenge, only when every member
remains inside the ceiling. A token result must satisfy that required set
before it can complete the flow. Normal execution atomically records the
private requirement but exposes only the closed cause; it does not begin
step-up or replay the request.

Only one live authorization flow exists per stable grant key. Reauthorization
holds the same per-key mutation lease as refresh from immediately before code
exchange through atomic grant commit and commits only against its begin-time
token generation. It requests a store-owned lease TTL covering the remaining
local authorization budget, and the fenced code-dispatch transition fails before
the one-use code leaves the process if that guarantee or lease identity no
longer holds. It may replace a completed or poisoned old version, while an old
refresh can neither complete nor poison the newly committed version; a flow
made stale by an intervening refresh or authorization fails closed instead of
overwriting the newer grant.

Apply a documented PtcRunner fail-closed authorization profile after validating
the underlying RFC 8414 or OpenID document; these flow-compatibility checks are
PtcRunner policy, not extra fields required by the MCP discovery page.
`response_types_supported`, required by the underlying metadata formats, must
list `code`; `grant_types_supported`, when present, must list
`authorization_code`; and `response_modes_supported`, when present, must list
`query`. Omitted grant types use RFC 8414's authorization-code/implicit
default for the initial code flow, but refresh eligibility always requires
explicit `refresh_token` support; omitted response modes use its query/fragment
default. No other omission invents support. The client always sends S256 PKCE,
and authorization proceeds only when the metadata contains
`code_challenge_methods_supported` with `S256`. Missing metadata or an
incompatible field fails closed for both RFC 8414 and OpenID discovery.
Authorization-server metadata with
`require_pushed_authorization_requests: true` also fails before interaction:
PtcRunner does not implement PAR and never silently falls back to a direct
authorization request when the server requires it.

### Token ownership and refresh

An acquired OAuth installation starts one `MCPOAuth.TokenManager` owner for its
exact grant key. It loads the grant through the store and provides a fresh
authorization header to `MCPRequestContext` before each admitted request.
Before every header issuance, the request caller loads the current store
version within the request's absolute deadline and asks the token owner to
atomically prove its cached generation is current or replace it with the newer
stored grant. It never serves a cached access token from a superseded
generation. This mandatory check is the cross-process and cross-node
invalidation mechanism; an adapter may optimize it only with a reliable
subscription that preserves the same before-issuance guarantee.
Header issuance first proves a generation at that atomic store load. Immediately
before the socket dispatch, the caller obtains the store-backed MCP
dispatch-admission lease described above. A stale token generation causes
header reacquisition under the same deadline without any upstream request
having occurred. Once admitted, an ordinary later token-generation commit may
affect the next request but does not retroactively invalidate the in-flight
request; principal retirement and authority replacement/release instead enter
retiring state, prevent new admissions, and cannot complete until every earlier
admission drains. Revocation therefore cannot report completion while an old
bearer request may still dispatch.

Store access, secret resolution, and token-endpoint network I/O never run
inside `MCPRequestContext` or `TokenManager` GenServer callbacks. The admitted
request task performs that bounded I/O. Owner calls perform only brief atomic
generation checks, reservation or lease decisions, and generation-conditional
state replacement. A caller that must refresh obtains the store-backed grant
mutation lease, performs the bounded network operation outside both owners,
and returns the result for a lease- and generation-conditional commit. Thus
unrelated concurrent MCP calls do not queue behind another call's store
round-trip or refresh, while callers for the same grant still serialize at the
mutation lease. A caller that encounters another active or unresolved refresh
lease reloads and waits outside the owners, bounded by its absolute request
deadline, until it observes a usable committed generation or an
authorization-required state.

The manager:

- treats access and refresh tokens as opaque bounded binaries;
- uses `System.monotonic_time/0` only for process-local expiry and request
  budget decisions. It never persists or transmits an absolute monotonic
  value. The store owns durable expiry evaluation and returns bounded remaining
  TTLs that are rehydrated into fresh local monotonic deadlines after every
  load or node restart;
- refuses refresh unless the loaded grant has both a refresh token and an
  independently persisted `refresh_authorized: true` decision for the current
  authority fingerprint/epoch and metadata revision. A refresh token alone is
  never evidence of eligibility;
- treats an omitted initial `refresh_token` as an unrefreshable grant. The
  access token remains usable only until its known expiry or conservative
  local unknown-expiry deadline, then requires explicit authorization;
- computes that conservative deadline from the installed
  `unknown_expiry_ttl_ms` whenever a successful token or refresh response
  omits `expires_in`. Refresh may occur at that deadline only when both a
  refresh token and current persisted `refresh_authorized: true` exist;
  otherwise the grant becomes authorization-required. A `401` may invalidate
  it earlier, while no local timer claims the server-side token has expired;
- refreshes before expiry using a small fixed skew;
- takes the store's exclusive mutation lease in refresh mode, reloads the
  current token generation and metadata revision, and checks both the retained
  Protected Resource Metadata and authorization-server metadata freshness
  and, for CIMD, client-document freshness before exposing any token to the
  network adapter. When any part is stale, the admitted caller rediscovers
  Protected Resource Metadata first, revalidates exact resource identity and
  membership of the pinned issuer, rediscovers that issuer's
  authorization-server metadata, and then re-fetches and validates CIMD when
  applicable, all outside the owners within the same absolute deadline and
  egress policy. The resulting binding must still explicitly advertise
  `refresh_token` in both authorization-server and installed client metadata,
  remain allowed by host policy, and agree with the stored
  `refresh_authorized` decision. `offline_access` advertisement is not required
  at refresh time. It passes the complete validated binding to the atomic
  fenced dispatch transition described above. The refresh request uses only
  the newly validated token endpoint and a still-compatible configured
  authentication method. Resource identity, issuer membership, issuer
  identity, endpoint, supported authentication method, or effective refresh
  eligibility changes that cannot be validated fail before dispatch and
  require explicit authorization; no refresh token is sent to the stale
  endpoint. It then
  refreshes once and atomically replaces both access and rotated refresh
  tokens;
- for a public client, requires every successful refresh response to return a
  non-empty refresh token different from the token just spent. A missing or
  unchanged token fails closed, poisons the grant, and requires explicit
  authorization because this profile does not implement sender-constrained
  refresh tokens;
- for a confidential client, preserves the previous refresh token when a
  successful response omits a replacement, and never restores an older token
  after rotation;
- atomically deletes or marks the grant unusable only on the validated exact
  `400 invalid_grant` error response described above;
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
MCP HTTP all receive only the remaining local budget. Store APIs receive that
budget as a relative TTL or timeout, never as the absolute monotonic value.
Replace the implicit
five-second owner call with that remaining timeout, propagate cancellation to
every in-flight stage, and do not start the MCP HTTP dispatch after expiry.
OAuth work remains `:not_dispatched` for the MCP mutation state, but refresh
has its own dispatch provenance and poisoning rule described above.

Replace `safe_call/2`'s catch-all exit mapping as part of this integration.
Owner absence or shutdown maps to `:closed`; expiration of the remaining
`GenServer.call` budget maps to the MCP timeout vocabulary; and explicit caller
cancellation retains its cancellation classification. None of these may be
misreported as another category.

The private header result includes the stable grant key and exact token
generation used for the request. It never enters events or
inspection output. A response-driven rejection atomically marks only that
exact generation without advancing it, as defined by the store contract. A
delayed `401` from generation N therefore neither blocks a refresh or
reauthorization already dispatched from N nor rejects its committed generation
N+1.

### Authorization failures and replay

**MCP-AUTH-DEV-001 — no automatic step-up or replay:** the final MCP
authorization profile says user-delegated clients SHOULD attempt step-up
authorization and retry the original request. PtcRunner deliberately does
neither automatically. A dispatched operation, especially a write, cannot
safely be assumed replayable. PtcRunner records the private authorization
requirement and returns `mcp_authorization_required`; after a separate explicit
authorization succeeds, the host or workflow must issue a new operation. This
documented safety deviation must be carried verbatim in substance into the
durable user-facing authorization guide and Kernel maintainer documentation.

Proactive refresh may occur before any MCP method. Once an MCP HTTP request
begins:

- a `401` conditionally marks rejected only the exact access-token generation
  used by that request before inspecting its challenge and returns
  `mcp_authorization_required`; challenge parsing failure cannot skip or roll
  back that rejection. Definitive response status and headers stop untrusted
  body processing immediately, so a stalled or oversized body cannot hide the
  rejection. The runtime-shared local fence and durable transition use a fresh,
  bounded post-response budget rather than the HTTP request deadline. The
  manager atomically installs the shared fence and starts a bounded non-owner
  persistence worker before replying;
- a `403` with `insufficient_scope` atomically records the private bounded
  authorization requirement only after the shared Bearer challenge parser and
  ceiling validation succeed, while returning only
  `mcp_authorization_required`. Its runtime-shared local fence and durable
  transition use the same fresh, bounded post-response budget. The manager
  atomically installs the shared fence and starts a bounded non-owner
  persistence worker before replying, so caller or Dispatcher death cannot
  skip durable persistence. The shared fence is keyed by an opaque digest of
  local store identity and grant key, survives manager replacement or death,
  and clears only after durable persistence or a strictly newer sufficient
  grant. Each transition uses its own process-independent `:persistent_term`
  entry, so no fence-owner restart window exists within the running VM. The
  secret-free entry is published before mutation acknowledgement. Store
  wrappers expose the same non-secret local identity as their backing adapter.
  Manager shutdown drains these workers before discarding
  manager-local state. Failed persistence is retained and retried on close;
  continued failure makes close fail without stopping the fenced manager. When
  provider acquisition fails before returning a close handle, a supervised
  cleanup owner adopts the manager and retries bounded shutdown so no fenced
  manager is orphaned;
- an ordinary, missing, malformed, non-`insufficient_scope`, or unsatisfiable
  dynamic `403` challenge does not create a scope fence and returns a
  non-retryable authentication or authorization result. Only a durable
  transition failure after one valid satisfiable challenge is a transport
  failure;
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

- Add the small PtcRunner-owned state, S256 PKCE, form-encoding, and bounded
  token-projection module with no OAuth client-library dependency.
- Add a tested direct Mint runtime constraint and the PtcRunner-owned Req/Mint
  adapter. Do not rely on Req/Finch's transitive Mint dependency for a directly
  used public API.
- Migrate all existing Streamable HTTP modes to that adapter and preserve
  current JSON/SSE, cancellation, deadline, response-ceiling, dispatch
  provenance, and static-header behavior while closing Finch telemetry
  exposure.
- Implement exact retained issuer validation, canonical resource parsing,
  byte-exact redirect retention with a separate parsed safety view, the shared
  bounded case-sensitive scope parser, challenge parsing, Protected Resource
  Metadata, authorization-server discovery, token response validation,
  S256/state creation, and exact error closure.
- Add fixtures for OAuth-only RFC 8414 metadata and OpenID-shaped metadata,
  including GitHub's current no-ID-token, S256-capable shape as a positive
  case and a synthetic fail-closed missing-PKCE case.
- Prove no redirect, downgrade, endpoint substitution, unbounded body, error
  body, or secret-bearing exception escapes.

### Slice 2: authority and authorization context

- Add the closed host schema for OAuth, pre-registered public/confidential
  clients, pinned issuer/resource/scope ceiling/defaults, redirect authority,
  and tenant-unique immutable installation IDs.
- Add the authorization context, store behaviour, in-memory adapter, opaque
  grant keys, pending-flow and authorization-requirement TTLs,
  compare-and-swap replacement, shared grant mutation lease, stable
  installation/principal indexes, principal lifecycle claims, atomic authority
  claim/replacement/release, and retirement operations.
- Keep durable persistence out of the first implementation. A filesystem
  snapshot adapter used only by tests would exercise a persistence protocol
  that no production host uses while adding its own encryption, fsync,
  recovery, distributed-clock, and fault-injection state machine to the
  credential path. Retain the required persistent-adapter contract at the
  behaviour boundary and defer an executable durable conformance subject until
  a concrete hosted or embedding adapter exists; the trigger and acceptance
  work are recorded in
  [`future/mcp-oauth-durable-store.md`](future/mcp-oauth-durable-store.md).
- Add the bounded just-in-time credential resolver usable before build and
  during delayed refresh. Keep the existing public
  `ProviderRegistry.credential_resolver` bulk callback unchanged and wire the
  new seam through the authorization context and explicit
  `HostInstallation.registry/2`.
- Keep host loading side-effect free. Runtime registry assembly batch-claims
  every validated OAuth authority in the supplied store all-or-nothing before
  any grant access; decode and schema checking do not mutate the store. OAuth
  client-secret bindings never enter the existing bulk build/acquisition
  credential barrier;
  resolution occurs only immediately before code exchange or an admitted
  request's bounded token-refresh stage, never during host decode, preflight,
  or use of an unexpired grant.
- Extend safe check output only with the closed `none`, `static`, or `oauth`
  authorization mode; expose no account, scope, issuer, client, redirect, or
  token detail.

### Slice 3: explicit local and embedding flow

- Add callback-agnostic begin/complete/cancel APIs.
- Add and test the reusable ephemeral-port loopback-IP interaction, with
  `localhost` rejected, through the embedding APIs and a deterministic command
  harness. Do not expose the CLI authorization option until Slice 4 can use its
  grant through the common dynamic-header request path.
- Use the single-shot callback listener with no request-bearing dependency
  telemetry; do not promote Bandit or Plug to root runtime dependencies for
  this flow.
- Add pre-registered and Client ID Metadata Document clients.
- Make denial, timeout, state mismatch, issuer mismatch, callback replay,
  printed-URL presentation, and cleanup deterministic.

### Slice 4: token manager and MCP integration

- Add the per-grant token owner and proactive refresh.
- Expose the explicit CLI authorization option and compose it with both normal
  execution and `--check`; authorization and acquisition retain the transient
  grant in one process and use the same common request integration.
- Keep store, secret-resolution, and network I/O in the admitted request task;
  owner callbacks contain only brief generation, reservation, lease, and
  conditional-commit transitions. Preserve timeout, closed-owner, and
  cancellation as distinct outcomes.
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
  documentation, and product readiness. Document MCP-AUTH-DEV-001,
  MCP-OAUTH-EXPLICIT-SCOPE, the signed-metadata restriction, and the
  deliberately unsupported DCR compatibility path.
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
  refresh eligibility constrained by explicit authorization-server and
  installed-client `refresh_token` support, plus optional `offline_access`
  constrained by that same complete pre-response refresh eligibility,
  authorization-server scope metadata, and the installed ceiling;
  persisted-grant invalidation when
  `unknown_expiry_ttl_ms` changes; query-bearing resources in host
  configuration and direct embedding preserving exact query identity through
  authorization, token, and MCP requests; `default_scopes` constrained by the
  installed ceiling, explicit use when discovery omits scopes, and closed
  refusal when discovery and installed defaults are all empty, labeled
  **MCP-OAUTH-EXPLICIT-SCOPE** in durable user-facing documentation and tested
  as a deliberate deviation from MCP's omit-scope fallback; rejection of a
  present empty `scopes_supported` array in either Protected Resource or
  authorization-server metadata rather than treating it as authoritative,
  absent, or capable of bypassing `default_scopes`; byte-exact
  production redirect-URI equality with host-case, omitted versus explicit
  `:443`, path percent-encoding, cross-path, and cross-port near matches
  rejected rather than normalized;
- RFC 9728 challenge and well-known fallback discovery, including correct
  retained-path insertion with an absent or byte-exact retained query,
  path-candidate-before-root priority, root-only success, and root-resource
  candidate de-duplication;
- combined and separate `WWW-Authenticate` fields with other schemes before
  and after one Bearer challenge, plus initial discovery with no header,
  other-schemes-only headers, and one valid Bearer without `resource_metadata`
  all reaching ordered well-known fallback. Malformed or multiple Bearer
  challenges, comma-confusable values, and case-insensitive duplicate or
  conflicting auth parameters are rejected. Runtime `401` cases with malformed,
  zero, or multiple Bearer challenges must prove the rejected token generation
  is marked rejected and never reused; runtime `403 insufficient_scope`
  requires exactly one valid Bearer challenge before storing a requirement;
- RFC 8414 and OpenID discovery URL variants with exact issuer checks,
  including all three path-issuer forms in priority order and de-duplication of
  root-issuer candidates. Every Protected Resource, RFC 8414, and OpenID
  candidate must cover exact `200 application/json`, optional validated UTF-8
  charset, non-200, absent/wrong media type, redirect, malformed document, and
  ordered fallback/exhaustion behavior. A failed challenge-directed
  `resource_metadata` fetch must not fall through to well-known discovery;
- authorization-server flow compatibility, including required `code`, present
  grant-type support for `authorization_code`, present response-mode support
  for `query`, their allowed RFC 8414 omission defaults, and S256;
- unmodified issuer retention plus rejection of userinfo, query, fragment, and
  case/port/slash/percent-encoding near matches;
- pre-registration and Client ID Metadata Documents, including capability
  advertisement, exact CIMD identity/required fields and forbidden
  URL/authentication forms, required exact HTTP `200`, accepted
  `application/json` and
  `application/*+json` responses plus rejection of other media types,
  duplicate JSON member rejection before any client field is used,
  explicitly declared public `none` authentication with omission rejected,
  compatible present or defaulted CIMD grant/response types, CIMD refresh
  eligibility and pre-registration refresh eligibility each requiring an
  explicit `refresh_token` grant, manual input through the same validated
  pre-registration structure, rejection of CIMD
  `require_pushed_authorization_requests: true` and
  `dpop_bound_access_tokens: true` before interaction, and closed rejection
  plus user-facing documentation of unsupported DCR;
- ephemeral loopback port allocation with an exact IP literal and path,
  rejection of `localhost`, wildcard binding, wrong IP family, fixed-port
  assumptions, callback attempts on any non-selected port, missing/duplicate/
  malformed/mismatched `Host` fields for both IPv4 and bracketed IPv6, and
  absolute-form request targets, all rejected before flow consumption; CLI
  output presenting the one-time URL without spawning a browser process or
  placing it in process arguments, explicit operator-opened callback completion,
  premature listener failure cancelling `pending_callback`, and expected
  post-callback listener shutdown leaving `callback_consumed` live;
- S256, state, callback issuer, one-time callback consumption, denial, and
  timeout, including rejection when PKCE metadata is absent; generation from
  two independent 32-byte random values, distinct unpadded 43-character
  Base64URL state and verifier output, state/verifier uniqueness across a
  bounded sample, verifier-grammar rejection for padding, invalid characters,
  and lengths outside 43–128, plus a strict harness that independently checks
  the S256 challenge; one live pending flow per grant key, constant-time state
  comparison, reversed completion attempts
  from concurrent begins, pending-flow expiry recovery, and stale completion
  after refresh, reauthorization, or deletion; idempotent explicit
  cancellation in both `pending_callback` and `callback_consumed`, an atomic
  cancellation-versus-`begin_code_dispatch` race with exactly one winner,
  distinct `code_dispatch_indeterminate` cancellation after dispatch, and
  browser or embedding caller abandonment before dispatch releasing the
  pending slot without allowing a later code exchange. Cancellation after
  authorization-lease acquisition but before dispatch must revoke the matching
  `not_dispatched` lease in the same transaction and let another refresh or
  authorization mutation proceed immediately;
- callback parameter shape requiring exact state/issuer validation and then
  exactly one of non-empty `code` or non-empty OAuth `error`; duplicated,
  mixed, absent, or empty recognized parameters fail without code exchange;
  bounded unrecognized extension parameters and error details are discarded
  without fetch, retention, reflection, or logging;
- callback completion in a different process and simulated node using only the
  durable pending-flow record, including the persisted begin-time issuer
  response decision, token endpoint, client/redirect identity, and complete
  metadata revision. Fresh bindings dispatch normally; expired but exactly
  revalidated bindings renew atomically at `begin_code_dispatch`; a changed
  resource/issuer membership, endpoint, token-auth method, issuer-response
  decision, client document, redirect, or grant support fails before code
  dispatch and requires a new explicit flow;
- public and confidential token endpoint authentication;
- explicit `none` and `client_secret_basic` selection, authorization-server
  metadata compatibility/default handling, and identical authentication on
  code exchange and refresh, including reserved-character and non-ASCII client
  IDs and secrets through PtcRunner's RFC 6749 Basic encoder;
- CLI authorization rejecting confidential clients, production HTTPS
  callbacks, and every other non-public-loopback authority before discovery,
  secret resolution, or listener startup, while direct embeddings prove the
  same confidential authorities remain usable through their HTTPS callback;
- exact endpoint/resource identity plus exact `resource` on authorization,
  code exchange, and refresh, including acceptance and canonicalization of
  uppercase resource scheme/host while preserving path, port, and
  trailing-slash and exact query distinctions; authorization and token
  endpoints with unrelated pre-existing query parameters preserving their
  exact bytes/order, plus rejection of malformed queries and collisions with
  every protocol-owned authorization URL or token form parameter, including
  pre-existing `response_mode=fragment`, `response_mode=form_post`, `request`,
  and `request_uri`; collision tests include percent-encoded parameter names;
- mandatory case-insensitive Bearer `token_type` on initial and refresh
  responses; exact bounded RFC 6750 `b64token` validation of `access_token` and
  bounded RFC 6749 `1*VSCHAR` validation of any retained `refresh_token` before
  storage, including negative cases for empty values, CR/LF and other
  controls, whitespace or Unicode bearer values, invalid bearer punctuation,
  and misplaced `=` padding; rejection of missing/other token types,
  projection of only supported OAuth token fields, and immediate
  disposal/redaction of `id_token` and unknown response members; mandatory
  form request content type plus
  `Accept: application/json` on both token operations; exact HTTP `200` success
  with strict JSON response media type and duplicate JSON member rejection
  before any initial or refresh response field is used; rejection of
  success-shaped `201`, `202`, and `204` responses; bounded exact `400`/`401`
  OAuth error projection retaining only a grammar-valid `error` code and
  discarding descriptions, URIs, headers, and unknown fields; deterministic
  `400 invalid_grant`, `401 invalid_client`, unknown-error, wrong-status,
  missing/wrong-media-type, duplicate-key, malformed, and oversized error
  cases proving the correct refresh poisoning or code-flow terminalization; an
  unsolicited initial `refresh_token` being
  immediately discarded under every ineligible host-policy, installed-client,
  or authorization-server grant combination, with refresh requiring both that
  token and the independent persisted
  `refresh_authorized` decision rather than token presence; `expires_in`
  integer boundaries at 1 and
  31,536,000 seconds plus rejection of zero, negative, fractional, string, and
  larger values, checked relative-millisecond conversion, store-authoritative
  pre-request expiry anchoring, and identical validation on authorization-code
  and refresh responses. Delayed response validation and a slow fenced store
  commit must debit elapsed time and reject an already-expired token rather
  than restarting its full lifetime;
- expiry skew, one refresh under concurrency, rotated refresh tokens,
  compare-and-swap conflicts, stable-key scope narrowing, safe proven
  pre-dispatch lease recovery, owner death before and after every persisted
  dispatch transition and socket write, response loss after server-side
  rotation, refresh-indeterminate poisoning, `invalid_grant`, and concurrent
  refresh versus reauthorization commit, plus omitted initial refresh tokens,
  public-client poisoning when a successful refresh omits or repeats the spent
  refresh token, confidential-client retention of the current refresh token
  when a successful refresh omits a replacement both before and after an
  earlier rotation, omitted initial and refresh `expires_in`, conservative
  unknown-expiry deadlines, stale Protected Resource or authorization-server
  metadata forcing ordered rediscovery and exact resource/issuer revalidation
  before refresh, including CIMD freshness and continued client/server
  `refresh_token` support without requiring `offline_access`; compatible
  token-endpoint/auth-method rotation proceeding; and removed issuer
  membership, removed refresh eligibility, or incompatible rotation failing
  before credential dispatch. Slow-response and slow-store tests for Protected
  Resource, authorization-server, and CIMD documents must likewise prove
  externally advertised freshness never increases at commit.
  A future persistent-adapter conformance suite must use nodes with
  deliberately unrelated monotonic origins and skewed wall clocks, restart a
  node between commit and load, and prove that adapter-authoritative remaining
  TTLs and opaque fences neither extend token usability nor permit concurrent
  refresh-token spending. The active in-memory suite uses two token managers
  to prove that a generation committed before the MCP
  dispatch-admission fence is never served: a commit between header load and
  that fence produces `stale_before_dispatch` and header reacquisition with no
  network request. A generation-N `401` between header issuance and dispatch
  admission marks N, makes admission return `rejected_before_dispatch`, and
  produces no network request with that header. Non-token updates and recovery
  must not erase that marker. A normal commit after dispatch admission affects
  only a later request and does not retroactively invalidate the admitted
  request;
- a generation-N `401` arriving after refresh-token or authorization-code
  dispatch but before commit: the rejection marker must prevent reuse of N
  while the fenced successful result still commits N+1 and clears the marker;
- token and authorization-material redaction from inspect/status, Logger,
  Telemetry, traces, snapshots, inspection artifacts, CLI output, and every
  error path, except the deliberately presented one-time foreground
  authorization URL with its closed parameter set and no code, verifier,
  token, or secret. Attach handlers to the actual Finch and Bandit event
  prefixes during OAuth E2E and prove they receive no secret-bearing OAuth
  request or callback data; also inspect the PtcRunner adapter/listener's own
  events;
- no redirects and bounded challenge, metadata, token, and callback inputs;
- fail-closed fixtures for Protected Resource Metadata requiring DPoP and
  containing `signed_metadata`, plus authorization-server metadata requiring
  pushed authorization requests, proving rejection before browser interaction
  or credential dispatch and proving no unsigned field from a signed document
  is consumed; durable user-facing support documentation labels
  `signed_metadata` rejection as PtcRunner's interoperability restriction
  rather than an RFC requirement;
- a new `resource_metadata` challenge bypassing a still-fresh cache entry,
  including both changed and unchanged metadata URLs; identical issuer/resource
  pairs under different authority fingerprints, epochs, network policies, and
  redirect/client authority must never share a metadata cache entry;
- owner death and close during discovery, callback wait, refresh, admission,
  header delivery, and active MCP requests, including a close timeout followed
  by store recovery proving that detached release remains alive;
- one absolute MCP request deadline across admission, store access,
  just-in-time credential resolution, refresh, and HTTP dispatch, including
  configured ceilings above five seconds and cancellation at every stage;
- shared scope parsing across every list- and string-shaped source, including
  byte-exact case-sensitive containment and rejection of tabs, Unicode,
  leading/trailing/repeated spaces, invalid scope-token bytes, duplicates, and
  every count/member/aggregate boundary, plus serialize/parse round trips at
  the maximum accepted list and aggregate size;
- challenge, metadata, installed-ceiling, and narrowed token-response scope
  reconciliation; separate accumulated-requested and actual-granted sets;
  initial and later authorization refusal when the resulting known grant does
  not contain the pending operation's required set;
  omitted token-response `scope` retaining the explicit request set;
  consecutive refreshes sending the current known narrowed set; no
  authorization or refresh path creating an unreported-scope grant;
  `offline_access` omitted by default and added only under host refresh policy,
  explicit client/server `refresh_token` support, authorization-server scope
  advertisement, and ceiling authority; authorization-code-only clients never
  request it, while refresh-eligible servers with no `offline_access` scope
  still retain and use a returned refresh token. Exercise both
  refresh-eligible and authorization-code-only
  pre-registration and CIMD clients; principal-bound expiring requirement
  handoff into explicit
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
- unchanged public `ProviderRegistry.credential_resolver` typing and bulk
  build-barrier behavior, separate just-in-time OAuth secret resolution, and
  a combined `--authorize-mcp --check` invocation proving authorization and
  acquisition share the same transient process-local store. `registry/1` must
  continue accepting non-OAuth hosts and reject OAuth-bearing hosts, while the
  CLI and embeddings use `registry/2` with their explicit contexts;
- authority replacement using the fenced drain protocol to retire every old
  fingerprint for the stable tenant/installation index across at least two
  principals, principal deletion retiring all associated secret-bearing state,
  and in-flight refresh or authorization completion being unable to recreate
  retired state. Mutating each fingerprint input independently—including
  additional-origin and private-network exception sets, a confidential-client
  credential-binding identifier, normalized pre-registration grant types, and
  redirect details—must require fenced replacement, while semantically
  identical default-expanded configurations must produce the same versioned
  canonical fingerprint. Alias
  rename must preserve the explicit immutable installation ID; logical
  replacement with a new ID must retire the old ID first. Host configuration
  and direct embedding must reject tenant-local ID collisions before accessing
  grant state; concurrent claims with the same fingerprint must be idempotent,
  concurrent claims with different fingerprints must produce one winner, and
  compare-and-swap replacement/release must not race with claim or in-flight
  grant completion. An old runtime must fail every grant load and mutation
  after replacement or release, including release followed by reclaim of the
  same fingerprint, proving the authority epoch prevents ABA reuse;
- a multi-installation registry batch claim must make no durable change when a
  later member collides, while a compatible batch returns every claim epoch;
- principal retirement must fence every old authorization context, and
  delete/recreate of the same principal ID must receive a new epoch that
  prevents ABA reuse while leaving other principals unaffected;
- principal retirement and authority replacement/release must prevent new MCP
  dispatch admissions and OAuth credential-dispatch transitions, cancel local
  pre-dispatch work, and remain incomplete until every previously admitted MCP
  request and already-dispatched refresh/code exchange returns an acknowledged
  completion/transport-termination result or its worker is irreversibly fenced.
  Race retirement immediately before and after `begin_refresh_dispatch` and
  `begin_code_dispatch`, including a confidential flow paused after secret
  resolution: the pre-dispatch loser must release secrets without network I/O,
  while the dispatched winner must drain without committing a grant. A
  suspended or store-partitioned operation spanning admission or mutation-lease
  expiry must leave retirement incomplete, and no old bearer, refresh token,
  authorization code, or client secret may begin network dispatch after
  retirement reports completion;
- coordinator death before and after retirement begin, dispatch drain, and
  complete must leave one durable intent that another authorized coordinator
  can resume after the bounded lease expires; repeated identical begin is
  idempotent, a conflicting target is rejected, and external replacement or
  deletion remains unpublished until completion;
- concurrent requests proving slow store reads and refresh network I/O do not
  execute inside or block either owner callback, while same-grant mutation
  remains single-flight; refresh and code-exchange dispatch fencing immediately
  before, at, and after lease expiry, including refusal of a lease that cannot
  cover the requested relative remaining budget; distinct timeout,
  cancellation, and closed-owner results from every owner call;
- exactly one upstream `tools/call` when the server responds `401` or `403`,
  including a possibly dispatched write, plus a delayed generation-N `401`
  racing both refresh and reauthorization to generation N+1. A `401` status
  line must reject N even when its remaining header block stalls, is malformed,
  or exceeds the header ceiling; a `403` still requires one complete bounded
  Bearer challenge. Cancel the bounded provider task after the response
  callback starts its manager transition but before the callback can return,
  and prove the runtime-shared and durable fences still complete;
- explicit authorization completing before provider acquisition or model
  activity; and
- no Assent or other OAuth client library in the runtime dependency or
  published-package graph.

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
the disposable grant after the experiment. GitHub's first-priority RFC 8414
metadata advertised S256 in the follow-up 2026-07-29 probe, so it is a current
positive candidate; retain a synthetic missing-PKCE server as the durable
fail-closed negative case rather than depending on live metadata drift.

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
- MCP-AUTH-DEV-001, MCP-OAUTH-EXPLICIT-SCOPE, and the signed-metadata
  interoperability restriction are explicit in user-facing and maintainer
  documentation;
- multi-user tests prove two principals using the same installation cannot
  load, refresh, delete, or observe each other's grants;
- static authentication remains compatible;
- all secret-bearing state is redacted and all network/input bounds are
  enforced;
- the supported pre-registration/CIMD profile and deliberately unsupported DCR
  compatibility path are user-facing; and
- durable contracts have moved to module documentation and retained guides so
  this file can be deleted.

## Normative references

- [MCP authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)
- [MCP authorization-server discovery](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/authorization-server-discovery)
- [MCP client registration](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/client-registration)
- [MCP authorization security](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/security-considerations)
- [RFC 7636: PKCE](https://www.rfc-editor.org/rfc/rfc7636)
- [RFC 8252: OAuth 2.0 for Native Apps](https://www.rfc-editor.org/rfc/rfc8252)
- [RFC 8414: Authorization Server Metadata](https://www.rfc-editor.org/rfc/rfc8414)
- [RFC 8707: Resource Indicators](https://www.rfc-editor.org/rfc/rfc8707)
- [RFC 9207: Authorization Server Issuer Identification](https://www.rfc-editor.org/rfc/rfc9207)
- [RFC 9728: Protected Resource Metadata](https://www.rfc-editor.org/rfc/rfc9728)
- [OAuth Client ID Metadata Document draft
  -00](https://datatracker.ietf.org/doc/html/draft-ietf-oauth-client-id-metadata-document-00)
