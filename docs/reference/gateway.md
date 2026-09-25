# Gateway configuration

The loopback gateway exposes health checks and an authenticated MCP tool server.

Start it with the installed executable:

```sh
ptc gateway /absolute/path/ptc-gateway.json --env-file /absolute/path/credentials.env
```

A source checkout runs the equivalent `mix ptc.gateway` command from
`ptc_gateway/`.

Remote clients need an authenticated tunnel to loopback. Native TLS, proxy
trust, direct private-network binding, and container port publishing are not
supported. Changing configuration, credentials, templates, or pins requires a
whole-domain restart.

## Version 1 contract

`priv/schemas/ptc-gateway-config.schema.json` is generated from
`PtcRunner.Kernel.GatewayConfig.schema/0` by `mix ptc.gen_docs`. The root
staleness gate checks it. The schema and this semantic table are normative.
There is no implicit configuration search or implicit environment-file search.

| Surface | Rule |
| --- | --- |
| JSON | UTF-8, at most 1,000,000 bytes; duplicate and unknown keys rejected at every depth. Strings exclude NUL, CR and LF. Schema string maxima are also byte maxima. |
| Required fields | `version`, `listen`, `authentication`, `host`, `admission`, `tools`; nested requirements are specified by the schema. |
| Version | Exactly `1`. Optional `$schema` has the exact published gateway schema URL. |
| Listener | Literal `127.0.0.1` or `::1`; port 1–65535, fixed path `/mcp`. |
| Origins | `listen.allowed_origins` defaults to `[]`; at most 128 unique HTTP(S) serialized origins, each at most 2048 bytes. No userinfo, path, query, fragment, whitespace, escapes, uppercase host, or explicit default port. |
| Authority | Every request requires exactly the configured literal listener authority, including its port except port 80; IPv6 uses brackets. No proxy headers are trusted. |
| Bearer | `authentication.bearer.binding` names a host credential bound to an environment variable or a file. A literal host credential is refused, so neither document carries the bearer value. Capture enforces 32–4096 ASCII bytes in HTTP bearer-token grammar. |
| Admission | `max_inflight_requests`, `max_concurrent_runs`, and `max_active_provider_calls` each require 1–65535; `max_waiting_provider_calls` requires 0–65535. Each authenticated request reserves one in-flight slot before body reading and holds it through response completion, so a peer that stops sending its body holds a slot until the two-second body-read budget expires. |
| Tools | 1–128 entries, unique names matching `[a-zA-Z0-9_.-]{1,128}`, validated in UTF-8 name-byte order. Titles require 1–256 bytes; descriptions 1–4096. Each normalized schema is at most 64 KiB and the encoded static catalog at most 4 MiB. |
| Application | `application.manifest` names one manifest file, at most 1024 bytes. The serving constructor requires object input/output contracts and a validated read/write effect. |
| Event policy | `events.policy` must be `normal`, which is what an omitted `events` section or field already means. A `private` policy refuses the constructor ahead of the content-digest and write-permission checks and is reported as `template_invalid`. Gateway `artifacts` configuration may authorize normal trace and inspection destinations; holding the endpoint or setting `allow_write` never grants a private-result override. To serve such an application, set its manifest policy to `normal` and record the new content pin. |
| Artifacts | Optional `artifacts` has `root` and optional `trace` and `inspection` booleans (both default false). The root resolves from the gateway document directory and must pass the project artifact root's private-directory checks at startup. Enabled traces go to `traces/<run_ref>.jsonl` and inspection records to `inspection/<run_ref>.ptcins` under that root. Reservation failure refuses the call before execution. Omit the section to record no artifacts. Point a `ptc-project.json` `artifacts.root` at the same directory to browse served runs with `ptc viewer` or `ptc repl`. |
| Write permission | `allow_write` defaults to false. A compiled write effect requires true; permission never changes the compiled effect. |
| Content pin | Required `expected_application_content_digest`, exactly `sha256:` plus 64 lowercase hex characters; effective application identity is not interchangeable. |
| Installation pins | Required exact map `installation_config_pins`, keyed by installation name. Missing, extra, stale or mismatched values refuse startup. |
| Snapshot pins | Required exact map `provider_snapshot_pins`, keyed `workflow/name` or `mission/name`. Values pin acquisition identity, never volatile content. Tools without providers require both maps to be empty. |
| Paths | Host, application manifests, audit directory and artifact root resolve from the gateway document directory. Nested host-owned paths retain host-document-relative semantics. |
| Environment file | Anchored once from the invocation directory. Warm startup captures the bearer and selected provider credentials in one scope, restoring environment and lock before listener binding, including on failure. |
| Private audit | Required iff any tool sets `allow_write: true`; forbidden otherwise. Required fields: `directory`, `max_file_bytes` (1024–67108864), `max_retained_files` (2–128). |

## Pins

From the root project, obtain the two provider pin maps using the existing safe
command. It never runs the workflow and prints no credential or volatile
provider content:

```sh
mix ptc.provider_pins /absolute/path/app.json --host /absolute/path/host.json --env-file /absolute/path/credentials.env
```

An application without providers prints exactly:

```json
{"installation_config_pins":{},"provider_snapshot_pins":{}}
```

Provider-bearing output uses the same keys and `sha256:<64 lowercase hex>`
values. Copy both complete maps into that tool's configuration. Obtain the
application content pin without running the workflow or resolving credentials:

```sh
ptc validate /absolute/path/app.json --host-config /absolute/path/host.json
```

The command prints one JSON object whose `application_content_digest` is that
manifest's `sha256:<64 lowercase hex>` pin. Copy it into
`expected_application_content_digest`. The value covers the application bytes
alone, so it is stable across runtime versions, unlike the
`effective_application_digest` printed beside it. Omit `--host-config` when the
manifest selects no provider.

## Private audit directory

Startup resolves the audit ancestry, and every resolved ancestor must be a
directory owned by you or root and not group- or world-writable unless
sticky. This makes `/tmp` and the default `TMPDIR` usable locations. The audit
directory itself must not be a symbolic link. Startup creates missing
directories as 0700 and files as 0600 before writing any content. The private
directory is exclusively locked for the owner's lifetime. After an unclean
owner death, the retained lock requires you to stop the old process before
removing it.

Each startup durably opens a new numbered file and separately appends and
flushes a temporary probe before readiness. The probe is then removed. Only
after the replacement is durable may retention remove closed files, oldest
first, so narrowing `max_retained_files` prunes down to the new bound on the
next startup. A startup that fails after opening its replacement removes it
again, so a failed start leaves no empty file counting against that bound.
Active files are never truncated. Unexpected files, hard links, oversized files
or wrong permissions refuse startup. There
is no HTTP audit-reading endpoint. Every dispatched write durably appends one
bounded record before run admission is released. It contains only the call ID,
tool name, start/end times, closed outcome and dispatch state, write uncertainty,
disconnect flag, and cleanup status.

## Health

| Request | Response |
| --- | --- |
| `GET /health/live` | 200 `{"status":"live"}` while listener and gateway owner remain alive. |
| `GET /health/ready` | 200 `{"status":"ready"}` when the warm domain is ready; otherwise 503 `{"status":"not_ready"}`. |
| Other method on either health path | 405. `OPTIONS` is unsupported. |
| Other path | 404. |
| Invalid authority, on any path | 400 before routing. |

Health needs no bearer and returns no CORS headers. Responses use
`application/json` and `Cache-Control: no-store`. Readiness uses the warm
runtime's bounded snapshot, including captured credentials, pinned providers,
run admission and provider-call admission. Saturation stays ready; required
runtime loss or fencing makes readiness permanently false while liveness
continues. Invalid static startup configuration prevents listener binding.

## MCP discovery, listing, and calls

`POST /mcp` accepts only MCP revision `2026-07-28` methods
`server/discover`, `tools/list`, and `tools/call`. It is stateless: `Mcp-Session-Id` and
`Last-Event-ID` are ignored and no session header is returned. Other HTTP
methods return 405, and unsupported MCP methods return HTTP 404 with JSON-RPC
`-32601`.

Requests require the exact listener authority, an allowed or absent `Origin`,
one bearer authorization, `Content-Type: application/json` (optionally with a
UTF-8 charset), and an `Accept` value that admits both `application/json` and
`text/event-stream` at nonzero quality. Critical headers may occur only once.
Authorization permits outer HTTP OWS but requires one or more SP bytes between
the case-insensitive `Bearer` scheme and token. Authentication precedes content
and body parsing. Limits are an 8 KiB HTTP/1 request line, 64 headers, 32 KiB
of decoded header-name plus header-value bytes, 8 KiB per complete HTTP/1 header field line, 2 MiB body,
64 KiB decoded `_meta`, JSON depth 64 and 100,000 nodes. String IDs contain
1–256 UTF-8 bytes; integer IDs are in the interoperable safe range. A body read
waits at most two seconds for the next bytes: a peer that stops sending gets
HTTP 408 `{"error":"request_timeout"}` and an unreadable body HTTP 400
`{"error":"request_invalid"}`. Neither is reported as an internal error, and
both close the connection rather than leave an unread body to drain. A peer
that closes its own write side mid-body receives no reply at all: the read
fails immediately and the connection ends.

Every request has object `params._meta` fields
`io.modelcontextprotocol/protocolVersion` and
`io.modelcontextprotocol/clientCapabilities`, with optional schema-shaped
`io.modelcontextprotocol/clientInfo`. `MCP-Protocol-Version` and `Mcp-Method`
must match the body. `Mcp-Name` is forbidden for these methods. Responses are
deterministic JSON, at most 4 MiB, and use `Cache-Control: no-store`.
Missing or malformed required metadata returns HTTP 400 JSON-RPC `-32602`.
Admission saturation returns HTTP 429 `-31999`; an unavailable or fenced
runtime returns HTTP 503 `-31998`.

Discovery advertises the fixed revision and static tool capability. Listing
returns every configured tool in UTF-8 name-byte order with its configured
name, title and description, exact normalized input/output schemas, and only
the compiler-derived `annotations.readOnlyHint`. A cursor, unknown parameter,
or malformed method parameters returns HTTP 200 JSON-RPC `-32602`.

A call accepts only `name`, optional object `arguments` (default `{}`), and the
required `_meta`. Exactly one `Mcp-Name` must decode to the body name. Schema
leaves annotated with `x-mcp-header` require exactly matching `Mcp-Param-*`
headers; duplicate, missing, unexpected, malformed, and mismatched headers return
`-32020`. Unknown call fields return `-32602`.

After validating a known call, the gateway atomically reserves run admission,
commits HTTP 200 `text/event-stream`, and only then activates execution. It emits
one final `message` event and closes. While silent it writes an SSE comment at
most every five seconds to detect a disconnected client. Success returns
deterministic JSON in both `structuredContent` and its exact text encoding.
Execution-domain failures return a complete tool error. A write failure with
possible effects uses exactly `Operation may have changed data; do not retry
automatically`; the gateway makes no retry or transaction claim.

SIGINT and SIGTERM stop the gateway owner and exit zero only after its listener,
provider runtime, audit owner, and admissions have stopped cleanly. From a
source checkout, use `scripts/run_gateway_source.sh CONFIG [--env-file FILE]`;
the wrapper forwards both signals into the same staged shutdown path, including
during application and gateway startup.

The official suite is pinned in
`ptc_gateway/test/support/mcp_conformance/package.json` at
`@modelcontextprotocol/conformance@0.2.0-alpha.11`. Applicable server scenario
IDs are `server-stateless`, `tools-list`, `dns-rebinding-protection`, `caching`,
`http-header-validation`, and `http-custom-header-server-validation`.
The remaining listed server scenario IDs are
excluded: `tools-call-*` require diagnostic tools and content families not
provided by configured workflows; `completion-complete`, `resources-*`, `prompts-*`, and
`sep-2164-resource-not-found` require unsupported feature families;
`server-sse-multiple-streams` requires GET/session streams;
`json-schema-2020-12` exercises a tool call; and `input-required-result-*`
requires server requests and multi-round tool execution. Neither this milestone
nor the parent claims the complete server suite.

The checked-in expected-failures baseline narrows mixed scenarios to this
profile. It excludes server-stateless checks requiring diagnostic tools, response
streams, logging tools, or optional server identity; caching checks for prompts
and resources. Both header-validation scenarios execute without a baseline,
including Base64/literal custom parameter decoding and mismatch rejection.
All applicable checks execute through the authenticated conformance proxy in
the gateway CI gate. Gateway boundary tests additionally enforce every critical
header duplicate and the exact parser and application header ceilings.
Integration boundaries also exercise exact and excessive body,
metadata, JSON depth/node, ID, normalized-schema, static-catalog, and encoded
response sizes.

## Startup failures

Only the first error is returned. Precedence is document read/JSON, structural
schema and byte bounds, origins, duplicate tool names, audit presence, host,
artifact-root validation, then each tool's constructor/pin and write permission in name order, audit
filesystem probe, run admission, warm credential capture/provider pins, and
listener binding. A stage must succeed before the next stage runs.

The CLI writes one JSON object `{"error":"<code>"}` and newline to stderr,
nothing to stdout, and exits 78. Successful startup is silent. No names, paths,
credentials, causes or stack traces belong in startup diagnostics.

The finite catalog is `config_unavailable`, `duplicate_json_key`,
`config_invalid`, `origin_invalid`, `tool_name_duplicate`, `audit_invalid`,
`host_invalid`, `template_invalid`, `catalog_too_large`, `application_content_digest_mismatch`,
`write_forbidden`, `audit_unavailable`, `artifact_root_unavailable`, `run_admission_unavailable`,
`credential_unavailable`, `installation_pin_mismatch`, `provider_pin_mismatch`,
`provider_pin_unavailable`, `provider_admission_unavailable`,
`provider_runtime_unavailable`, `listener_unavailable`, and `internal_error`.
Unrecognized internal failures map to `internal_error`.
