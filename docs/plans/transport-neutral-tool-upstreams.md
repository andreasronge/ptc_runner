# Transport-neutral Tool Upstreams

High-level requirements for extending `ptc_runner_mcp` so external tools are
discovered and called through a transport-neutral `tool/*` interface. The first
new non-MCP transport target is a curated, read-only JSON adapter for plain
HTTPS APIs described by OpenAPI/JSON Schema, using Tilda Observatory as the
production-shaped test bed.

## Motivation

`ptc_runner_mcp` already acts as an MCP aggregator: client LLMs write small
PTC-Lisp programs, and the sandbox calls configured upstream MCP servers via
`(tool/call ...)`. This works well for reducing large upstream payloads
before they reach the model.

Not every production service should expose MCP directly. Many services already
have HTTPS APIs, service-token auth, OpenAPI schemas, logging, rate limits,
tenancy, and deployment practices. For those services, `ptc_runner_mcp` should
be able to consume the API schema, compile selected operations into tool
metadata, and expose them to PTC-Lisp through the same tool-discovery and
tool-call model as MCP upstreams.

Observatory is the initial proving ground. The target use case is coding
agents accessing production logs/traces safely and cheaply, with PTC-Lisp doing
local filtering/aggregation before returning a compact answer to the client.

## Goals

- Make upstream tools transport-neutral from the LLM's perspective.
- Rename the public discovery/call vocabulary from MCP-specific names to
  `tool/*`.
- Support upstreams backed by both MCP servers and HTTPS OpenAPI services in
  one config file.
- Reuse the existing credentials model for OpenAPI upstreams: bearer, basic,
  and custom-header auth backed by env/file/literal bindings.
- Keep all auth material outside PTC-Lisp programs.
- Compile OpenAPI operations into the same normalized internal tool metadata
  shape used by MCP upstreams.
- Fetch or load schemas at startup and on future explicit catalog refresh, not
  on every tool call.
- Let service schemas carry optional `x-ptc-*` vendor extensions for
  agent/tooling hints that OpenAPI cannot express well.
- Keep initial generated calls explicit and boring:
  `(tool/call 'observatory/list-traces {...})`.
- Keep the first OpenAPI milestone intentionally narrow: curated, explicitly
  included, JSON `GET` operations only.

## Non-goals

- Add OAuth to `ptc_runner_mcp`.
- Make PTC-Lisp construct or override auth headers.
- Generate dynamic namespaces such as `(observatory/list-traces {...})` in the
  first version.
- Turn `ptc_runner_mcp` into a general-purpose API gateway.
- Infer perfect agent-safe behavior from arbitrary OpenAPI documents with no
  operator curation.
- Support write operations by default.
- Support HATEOAS as the first discovery contract.
- Auto-page through cursor results.
- Support broad OpenAPI features such as arbitrary parameter serialization,
  operation-level cross-origin servers, non-JSON bodies, or JSONPath projection
  in v1.

## User-facing PTC-Lisp Interface

The LLM should think in terms of external tools, not transport protocols. Model
each upstream as a tool namespace, and each upstream operation as a qualified
symbol in that namespace. This is closer to Clojure REPL conventions than
string references:

- `dir` lists names in a namespace.
- `doc` describes a qualified var-like symbol.
- `meta` returns metadata for a qualified symbol.
- `apropos` searches available symbols.

Preferred names:

```clojure
(tool/servers)
(dir 'observatory)
(doc 'observatory/list-traces)
(meta 'observatory/list-traces)
(apropos "trace")
(tool/call 'observatory/list-traces {:org-id "org-acme" :limit 20})
```

`tool/dir`, `tool/doc`, `tool/meta`, and `tool/apropos` may exist as explicit
aliases, but the authoring target should be the Clojure-ish forms above when
they can be supported without ambiguity.

Compatibility / migration:

- `mcp/servers`, `apropos`, `dir`, `doc`, and `meta` currently exist as
  discovery forms in aggregator mode.
- `tool/mcp-call` currently exists as the upstream-call primitive.
- This is a breaking 0.x change: add `tool/call` and symbol-aware discovery,
  update prompts/docs/tests to prefer them, and remove the MCP-specific public
  Lisp forms instead of keeping long-lived aliases.
- Keep the map-shaped `tool/call` form as a parser-friendly explicit form:

  ```clojure
  (tool/call {:server "observatory" :tool "list_traces" :args {...}})
  ```

Result contract should remain the existing tagged shape:

```clojure
{:ok true :value payload :value_kind :json}
{:ok false :reason kw :message text}
```

Programs must check `:ok` before reading `:value`.

## Config Shape

The existing upstreams JSON should grow a new HTTP/OpenAPI transport next to
existing MCP transports.

Example:

```json
{
  "credentials": {
    "observatory-token": {
      "source": "file",
      "path": "/run/secrets/observatory-token",
      "scheme_hint": "bearer"
    }
  },
  "upstreams": {
    "observatory": {
      "transport": "openapi",
      "base_url": "https://observatory.example.com",
      "schema_file": "/etc/ptc_runner_mcp/observatory.openapi.json",
      "auth": [
        { "scheme": "bearer", "binding": "observatory-token" }
      ],
      "include_operations": [
        "list_traces",
        "get_trace",
        "get_trace_steps",
        "search_traces",
        "aggregate_costs"
      ],
      "operation_overrides": {
        "get_trace_steps": {
          "description": "Fetch trace steps. Prefer mode=summary unless full payload is explicitly needed.",
          "max_response_bytes": 524288,
          "default_args": {
            "mode": "summary"
          }
        }
      }
    },
    "local-observatory-mcp": {
      "transport": "http",
      "url": "http://127.0.0.1:3333/api/mcp",
      "allow_insecure_http": true
    }
  }
}
```

OpenAPI upstream fields:

- `transport`: required, `"openapi"`.
- `base_url`: required unless every operation server URL is accepted from the
  schema. Prefer requiring it for v1 to avoid surprising cross-host calls.
- `schema_url`: HTTPS URL to the OpenAPI document.
- `schema_file`: local OpenAPI document path. Prefer this or a pre-generated
  catalog for production.
- `auth`: same emitter list as HTTP MCP upstreams.
- `static_headers`: same non-secret header model as HTTP MCP upstreams.
- `include_operations`: required for v1. Omitted or empty should be a config
  error. Values are OpenAPI `operationId`s. Do not default to all read-only
  operations.
- `operation_overrides`: operator-supplied metadata patches by operation id.
  Overrides are the source of truth for safety-sensitive behavior and may
  narrow schema-provided `x-ptc-*` metadata.
- `request_timeout_ms`, `connect_timeout_ms`, `max_response_bytes`,
  `pool_size`, and backoff fields: same meaning as HTTP MCP upstreams where
  applicable.

For production, prefer `schema_file` or a pre-generated catalog checked into the
deployment artifact. `schema_url` is useful for local/dev and dynamic
environments, but fetching a schema at boot couples startup to schema hosting,
network availability, and schema auth.

V1 should require exactly one schema source. Supplying both `schema_file` and
`schema_url` is a config error so startup behavior has no hidden precedence or
network fallback.

`schema_url`, when used, should be HTTPS by default and should use the upstream's
normal `auth` emitters if the schema is private.

## V1 OpenAPI Scope

V1 is a curated OpenAPI read-only JSON adapter, not a broad OpenAPI gateway.

Supported:

- OpenAPI 3.x documents from `schema_file` or `schema_url`.
- Explicitly included operations only.
- JSON `GET` operations.
- Path params and simple query params.
- JSON `2xx` responses, plus `204` / empty `2xx` as success with no value.
- Response caps enforced before decode.
- No response projection in v1. Return decoded JSON and let PTC-Lisp
  project/filter after the call.

Rejected or deferred:

- Omitted `include_operations`.
- Write methods by default: `POST`, `PUT`, `PATCH`, `DELETE`.
- Safe `POST` query endpoints until a later milestone with explicit operation
  allow-listing and a process-level write/safe-post gate.
- Header params supplied by PTC-Lisp.
- Cookie params.
- Non-JSON request or response bodies.
- Auto-pagination.
- JSONPath projection.
- JSON Pointer projection.
- Operation-level `servers` that are not same-origin with `base_url`.
- Complex parameter serialization styles beyond the default simple query
  encoding.
- Complex schema constructs as a full validation target (`allOf`, `oneOf`,
  `anyOf`, deep `$ref` graphs). V1 may preserve these in metadata while doing
  limited validation.

## OpenAPI Compilation

At boot, `ptc_runner_mcp` should fetch or read the OpenAPI schema once and
compile selected operations into normalized tool entries.

Normalized tool entry shape should match MCP tool metadata where possible:

```elixir
%{
  "name" => "list-traces",
  "description" => "List traces",
  "inputSchema" => %{...},
  "outputSchema" => %{...},
  "annotations" => %{"readOnlyHint" => true},
  "_ptc" => %{
    "transport" => "openapi",
    "operationId" => "list_traces",
    "method" => "GET",
    "path" => "/api/traces"
  }
}
```

Default mapping:

- `operationId` becomes the canonical transport operation id.
- The PTC-Lisp surface name defaults to a kebab-case symbol derived from
  `operationId`, e.g. `list_traces` becomes `observatory/list-traces`.
- The compiled metadata retains the original operation id for request
  execution and diagnostics.
- `summary` / `description` become the tool description.
- Path parameters, query parameters, headers permitted by config, and request
  bodies become the input schema.
- `responses.200` / first 2xx JSON response becomes the output schema.
- `GET` defaults to read-only.
- `POST`, `PUT`, `PATCH`, and `DELETE` are disabled in v1 unless a later
  milestone adds explicit safe-post/write gates.
- `deprecated: true` hides the operation by default.
- OpenAPI constraints become schema-aware preflight validation when practical.

Required validation:

- Every exposed operation must have a stable tool name.
- Tool names must not collide within one upstream after Lisp name
  normalization.
- Path params required by the route must be required args.
- Unsupported parameter locations must be rejected or ignored loudly at config
  load.
- Header params from PTC-Lisp must be rejected in v1; only config-owned
  `auth` and `static_headers` may set headers.
- Request bodies are unsupported for v1 JSON `GET`.
- Response content must be JSON for structured result extraction in v1, except
  `204` / empty `2xx`, which should return success with no value.
- Operation-level `servers` must be rejected unless same-origin with
  `base_url`.

## Name Mapping

The registry and preflight validation should route by the Lisp-facing tool name,
not by the raw OpenAPI operation id. Avoid overloading `"name"` to mean both.

For OpenAPI upstreams:

- `"name"` is the exposed tool name used by discovery and calls, e.g.
  `"list-traces"`.
- `"_ptc.operationId"` is the original OpenAPI operation id, e.g.
  `"list_traces"`.
- `tool/call 'observatory/list-traces` resolves through the catalog name.
- The OpenAPI upstream implementation maps the catalog name to operation
  metadata and uses `operationId` only for diagnostics and schema provenance.

If two operation ids normalize to the same Lisp-facing name, config load should
fail unless an operator override gives one of them a distinct name.

## PTC Vendor Extensions

PTC-specific OpenAPI vendor extensions are schema/discovery metadata only. They
are read when compiling the catalog and are not sent on normal tool calls.

Candidate extensions:

```yaml
x-ptc-name: list_traces
x-ptc-read-only: true
x-ptc-default-args:
  limit: 50
x-ptc-result-path: $.traces
x-ptc-pagination:
  cursor_arg: cursor
  next_cursor_path: $.next_cursor
x-ptc-max-response-bytes: 524288
x-ptc-notes: Prefer filters before requesting full trace steps.
```

Use extensions sparingly. Prefer OpenAPI-native fields and conventions first.
Extensions are for behavior generic OpenAPI does not express well:

- PTC-facing operation name override.
- Read-only override for safe `POST` query endpoints.
- Default args.
- Result projection.
- Pagination shape.
- Response byte caps.
- Agent guidance for expensive tools.

Operator `operation_overrides` in `upstreams.json` should be able to patch or
override schema-provided `x-ptc-*` metadata. Safety-sensitive behavior should
prefer the narrower setting. Schema-provided metadata must not silently widen
capability granted by operator config.

## Request Execution

`(tool/call ...)` against an OpenAPI upstream should:

1. Look up the compiled operation metadata.
2. Accept the preferred symbol call form
   `(tool/call 'observatory/list-traces {...})`, plus the map-shaped explicit
   form.
3. Validate/coerce args according to the compiled input schema where practical.
4. Apply `default_args`.
5. Resolve auth headers from configured credential bindings.
6. Build the HTTPS request:
   - path params into path,
   - query params into query string,
   - JSON body params into request body.
7. Enforce timeout and max-response-byte caps.
8. Decode JSON responses.
9. Return the standard tagged result.

The symbol form is syntax sugar at the Lisp boundary only. Internally normalize
it to the same explicit map shape used by the existing upstream machinery:
`%{"server" => "observatory", "tool" => "list-traces", "args" => %{...}}`.
This keeps validation, telemetry, upstream ledgers, and registry dispatch keyed
by `server` and `tool` without adding a second `ref` parsing path deeper in the
MCP server.

No `x-ptc-*` metadata should be sent over the wire. Only the actual API request
args, auth headers, static headers, and protocol-required headers are sent.

HTTP status mapping should mirror existing upstream semantics where possible:

- `2xx` JSON response: success.
- `204` / empty `2xx` response: success with `:value nil` and
  `:value_kind :none`.
- `400`/`422` JSON problem or error response: recoverable upstream/tool error.
- `401`: auth failed; trigger credential re-resolution/backoff behavior.
- `403`: valid credential but unauthorized; recoverable upstream error.
- `404`: not found or misconfiguration, depending on operation/path context.
- `429`: rate limited; prefer a distinct `:rate_limited` reason.
- `5xx`: upstream unavailable.
- Response over cap: `:response_too_large`.
- Network/TLS/connect failures: upstream unavailable.

## Authentication Requirements

Authentication stays in config/runtime, not in PTC-Lisp.

Reuse existing credential concepts:

- Sources: `env`, `file`, `literal`.
- Emitters: `bearer`, `basic`, `custom_header`.
- `scheme_hint` compatibility checks.
- Per-request materialization for `env` and `file`.
- No in-process value cache for env/file-backed credentials.
- Redaction of resolved values in logs, traces, debug buffers, telemetry, and
  error messages.

Production recommendation:

- Prefer `file` source for service-token rotation:
  `/run/secrets/observatory-token` or equivalent.
- Deployment replaces the file atomically.
- Next request uses the new token without restart.
- Env source is acceptable for local/dev, but process env does not rotate
  meaningfully without restart.

Security rules:

- HTTPS required by default for `schema_url` and `base_url`.
- Plain HTTP requires explicit opt-in.
- Sending auth over plain HTTP requires a second explicit opt-in.
- Secret-bearing headers are rejected from `static_headers`; use `auth`.
- PTC-Lisp cannot override `Authorization`, `Cookie`, `Host`,
  `Proxy-Authorization`, `Mcp-Session-Id`, or protocol-controlled headers.
- Auth values never appear in `tool/meta`, traces, debug output, result
  envelopes, or error messages.
- OpenAPI schema fetch should use the same auth model if schema access is
  private.

Future credential source:

```json
{
  "source": "exec",
  "command": "/usr/local/bin/get-observatory-token",
  "scheme_hint": "bearer",
  "cache_ttl_ms": 300000
}
```

`exec` should be deferred until file/env rotation is insufficient. It adds
process-spawn security, timeout, caching, and error-surfacing questions.

## Tilda Observatory Requirements

Observatory should expose normal HTTPS endpoints plus an OpenAPI schema. It does
not need to expose MCP directly for production.

Useful endpoints for the initial test bed:

- `GET /api/traces`
- `GET /api/traces/{id}`
- `GET /api/traces/{id}/steps`
- `GET /api/traces/search`
- `GET /api/analytics/costs`
- `GET /api/analytics/errors`

The API should include query-oriented endpoints, not only database-shaped
resources. Production traces can be large, so agents need bounded operations:

- List traces with status/error/cost signals.
- Search by external `trace_id`.
- Fetch trace summaries cheaply.
- Fetch steps in `summary` mode by default.
- Fetch one full step payload by step id when needed.
- Aggregate cost by org/model/time window server-side.
- List recent failures with error class and trace id.

Observatory owns service-token issuance and authorization:

- token id / client name,
- scopes such as `traces:read`, `trace_steps:read`, `analytics:read`,
- tenant/org restrictions,
- environment restrictions such as production/staging,
- audit logs for operation, org, trace id, timestamp, and token id,
- revocation,
- rate limits.

## Catalog Refresh

Initial implementation can keep the current boot-time frozen catalog behavior.
However, OpenAPI schemas are likely to evolve, so a later explicit refresh
operation should be planned:

- Refresh one upstream's schema and compiled catalog.
- Preserve stable operation names when possible.
- Report added/removed/changed tools in diagnostics.
- Avoid refreshing implicitly during tool calls.

Open question: whether refresh should be an MCP admin tool, a PTC-Lisp
discovery form, a release command, or all of the above.

For v1, keep refresh restart-only or admin/release-only. Do not expose catalog
refresh as a normal Lisp discovery form; the current catalog model is
intentionally frozen at boot.

## Solution Outline

Implement this as a sequence of small breaking changes. This is a 0.x library,
so prefer deleting MCP-specific public Lisp vocabulary once callers and tests
are moved, instead of carrying long-lived compatibility shims.

### 1. Transport-neutral Lisp surface

Keep the existing upstream supervision and call architecture. The current
`PtcRunnerMcp.Upstream` behaviour is already close to transport-neutral:
`list_tools/1` returns normalized tool metadata and `call/4` dispatches a named
tool with JSON-like args. The first change should be at the PTC-Lisp surface and
catalog discovery vocabulary.

Code touchpoints:

- `lib/ptc_runner/lisp/analyze.ex`
  - Add `tool/servers` as the transport-neutral alias for `mcp/servers`.
  - Keep `dir`, `doc`, `meta`, and `apropos` as the preferred Clojure-ish
    discovery forms; they already accept quoted symbols for refs.
- `lib/ptc_runner/lisp/eval.ex`
  - Route `tool/servers` to the existing `:servers` discovery operation.
  - Add a narrow special case for `(tool/call 'server/tool args-map)`, because
    generic `tool/*` calls currently reject positional args. Convert that form
    to a normal string-keyed map:
    `%{"server" => "server", "tool" => "tool", "args" => %{...}}`.
  - Continue accepting `(tool/call {:server "..." :tool "..." :args {...}})` as
    the explicit parser-friendly form. Delete `tool/mcp-call` in the same
    breaking change.
- `mcp_server/lib/ptc_runner_mcp/aggregator_tools.ex`
  - Rename the registered closure from `"mcp-call"` to `"call"` and parse the
    explicit `server/tool/args` map shape.
  - Preserve the existing validation, per-program cap, upstream ledger,
    telemetry, `McpResult` tagging, and programmer-fault vs world-fault
    classification.
  - Update user-facing hints from `(tool/call ...)` / `(tool/servers)` to
    `(tool/call ...)` / `(tool/servers)` plus `dir` / `doc` / `apropos`.
- `mcp_server/lib/ptc_runner_mcp/catalog_prompt.ex`,
  `mcp_server/lib/ptc_runner_mcp/tools.ex`,
  `mcp_server/lib/ptc_runner_mcp/agentic/prompt.ex`, and
  `mcp_server/lib/mix/tasks/mcp.repl.ex`
  - Update prompt text, advertised descriptions, and REPL help to the
    transport-neutral vocabulary.

Tests:

- Add/adjust `test/repl_discovery_test.exs` coverage for `(tool/servers)`.
- Add `mcp_server/test/ptc_runner_mcp/aggregator_*_test.exs` coverage for:
  `(tool/call 'alpha/echo {:msg "hi"})`, map-shaped `(tool/call {...})`, unknown
  upstream, unknown tool, missing required args, cap exhaustion, and `pmap`.
- Update prompt/description tests that currently pin `tool/mcp-call`.

Acceptance:

- Existing MCP stdio and MCP HTTP upstreams are callable through `tool/call`.
- Discovery docs and hints no longer require the model to know whether an
  upstream is MCP, HTTP MCP, or OpenAPI.
- `upstream_calls`, payload metrics, debug recording, and response profiles keep
  their current shapes unless a field name is explicitly renamed.

### 2. Normalized catalog metadata

Before adding OpenAPI, make the catalog explicitly model the difference between
the Lisp-facing tool name and transport-native operation identifiers.

Code touchpoints:

- `mcp_server/lib/ptc_runner_mcp/upstream.ex`
  - Extend the documented `tool_schema` shape to allow canonical MCP-style
    fields (`"name"`, `"inputSchema"`, `"outputSchema"`) and existing internal
    fields (`:name`, `:input_schema`, `:output_schema`) until the codebase is
    normalized.
  - Add `"_ptc"` metadata to the normalized shape for transport provenance:
    transport, raw operation id, method, path, and any execution hints.
- `mcp_server/lib/ptc_runner_mcp/upstream/catalog.ex`
  - Include `"openapi"` in the transport tag map.
  - Render the Lisp-facing `"name"` only; never render raw `operationId` unless
    it is also the chosen Lisp-facing name.
- `mcp_server/lib/ptc_runner_mcp/catalog_builtins.ex` and
  `mcp_server/lib/ptc_runner_mcp/catalog_description.ex`
  - Ensure `dir`, `doc`, `meta`, and `apropos` operate on the normalized tool
    name and include `_ptc` provenance in `meta`, not in the compact rendered
    catalog line.
- `mcp_server/lib/ptc_runner_mcp/agentic/capability_summary.ex`
  - Keep summaries transport-neutral; show effect/read-only hints and concise
    operation descriptions, not transport plumbing.

Tests:

- Pure catalog tests for mixed MCP/OpenAPI snapshots and name collision errors.
- Discovery tests that prove `doc 'observatory/list-traces` resolves by exposed
  name while `meta` retains `operationId: "list_traces"`.

Acceptance:

- A catalog entry has one exposed name, one optional native operation id, and no
  ambiguity about which string is used for calls.
- No OpenAPI transport code is needed for this stage; fixtures can supply
  synthetic normalized entries.

### 3. OpenAPI config parsing

Add `transport: "openapi"` to the existing upstreams JSON parser. Reuse the HTTP
credential and security model rather than adding a second auth stack.

Code touchpoints:

- `mcp_server/lib/ptc_runner_mcp/application.ex`
  - Extend `parse_upstream_entry/3` to dispatch `"openapi"`.
  - Add `parse_openapi_upstream/3` next to `parse_http_upstream/3`.
  - Reuse the existing URL, static header, auth emitter, duplicate header,
    insecure HTTP, insecure auth, proxy, timeout, pool-size, and backoff
    validation helpers where their semantics match.
  - Require exactly one schema source for v1: `schema_file` or `schema_url`.
  - Require non-empty `include_operations`.
  - Parse `operation_overrides` as data and pass it through to the OpenAPI impl;
    do not interpret safety-sensitive widening in the generic config parser.
  - Update dependency checks so OpenAPI requires `:req` only when `schema_url`
    or runtime HTTPS calls are configured.
- `mcp_server/lib/ptc_runner_mcp/credentials.ex` and
  `mcp_server/lib/ptc_runner_mcp/credentials/*.ex`
  - No new credential source for v1. Reuse current materialization and redaction.

Tests:

- Config tests for valid `schema_file`, valid `schema_url`, missing schema
  source, both schema sources present, empty `include_operations`, unknown auth
  binding, HTTP without opt-in, auth over HTTP without the second opt-in, and
  secret-bearing `static_headers`.

Acceptance:

- A valid OpenAPI upstream parses into `%{impl: PtcRunnerMcp.Upstream.OpenApi,
  config: ...}`.
- Invalid or unsafe OpenAPI configs fail at boot with actionable messages.

### 4. OpenAPI schema compiler

Implement OpenAPI parsing and operation compilation as pure modules first. Keep
runtime HTTP execution out of this stage so schema edge cases are easy to test.

Proposed modules:

- `mcp_server/lib/ptc_runner_mcp/upstream/open_api/schema_loader.ex`
  - Load JSON from `schema_file` or fetch it from `schema_url`.
  - Enforce schema byte caps before decode.
  - Use configured auth/static headers only for `schema_url` if the schema is
    private.
- `mcp_server/lib/ptc_runner_mcp/upstream/open_api/compiler.ex`
  - Resolve the selected `operationId`s.
  - Reject unsupported methods, parameter locations, request bodies, response
    content types, and cross-origin operation-level servers.
  - Normalize names to kebab-case unless `x-ptc-name` or
    `operation_overrides[name]` supplies an exposed name.
  - Merge OpenAPI fields, `x-ptc-*` extensions, and operator overrides with the
    operator override as the narrowest authority.
  - Build the tool input schema from path/query params plus default args.
  - Preserve unsupported schema constructs in metadata when useful, but do not
    pretend v1 can fully validate them.
- `mcp_server/lib/ptc_runner_mcp/upstream/open_api/names.ex`
  - Centralize operation id to Lisp-facing name normalization and collision
    errors.

Tests:

- Fixture OpenAPI documents under `mcp_server/test/fixtures/openapi/`.
- Compiler tests for path params, query params, output schema selection,
  deprecated operations, operation id inclusion, name overrides, collisions,
  unsupported methods, header params, cookie params, non-JSON responses,
  request bodies, and same-origin server checks.

Acceptance:

- Given the Observatory fixture schema and includes, the compiler returns the
  normalized tool entries expected by catalog/discovery.
- Compilation has no network side effects except the explicit `schema_url` load.

### 5. OpenAPI upstream execution

Add a new `PtcRunnerMcp.Upstream.OpenApi` implementation that conforms to the
existing upstream behaviour.

Code touchpoints:

- `mcp_server/lib/ptc_runner_mcp/upstream/open_api.ex`
  - `start_link/2` loads/fetches the schema, compiles included operations, and
    stores compiled operation metadata in the impl GenServer.
  - `list_tools/1` returns the compiled tool list.
  - `call/4` resolves by exposed tool name, materializes credentials per
    request, applies default args, validates/coerces supported arg shapes,
    builds the request, enforces timeout and response byte caps, decodes JSON,
    and maps the result to `{:ok, value}` / `{:error, reason, detail}`.
  - Register by upstream name under `PtcRunnerMcp.Upstream.OpenApi.Names`,
    mirroring `Upstream.Http` / `Upstream.Stdio`, because the behaviour dispatch
    callback receives `server_name`, not the impl pid.
- `mcp_server/lib/ptc_runner_mcp/upstream/supervisor.ex`
  - Start the OpenAPI impl registry.
- `mcp_server/lib/ptc_runner_mcp/upstream/http/transport.ex`
  - Do not couple OpenAPI calls to Streamable HTTP MCP session logic. Use `Req`
    through a small OpenAPI-specific request helper, extracting shared byte-cap
    or timeout mechanics only if that reduces duplication without obscuring the
    different protocols.

Tests:

- Unit tests with a local Plug/Bandit fixture for successful GET, path params,
  query params, default args, empty 204, 400/422, 401, 403, 404, 429, 5xx,
  timeout, response cap, malformed JSON, and credential rotation from file.
- End-to-end aggregator tests that call an OpenAPI fixture through
  `(tool/call 'observatory/list-traces {...})` and verify `upstream_calls`
  ledgers, redaction, response profiles, and payload metrics.

Acceptance:

- OpenAPI and MCP upstreams can coexist in one config and one frozen catalog.
- The caller cannot supply auth headers or override protocol-controlled headers
  from PTC-Lisp.
- Secret values are absent from logs, traces, debug buffers, telemetry, catalog
  metadata, and error messages.

### 6. Observatory fixture and docs

Use Observatory as the production-shaped fixture after the generic
OpenAPI adapter works against local tests.

Code/docs touchpoints:

- Add an Observatory OpenAPI fixture with only the v1 read-only operations.
- Add a sample upstream config showing `schema_file`, file-backed bearer auth,
  `include_operations`, and operation overrides.
- Update `docs/mcp-server-configuration.md`, `docs/aggregator-mode.md`, and
  `docs/guides/mcp-getting-started.md` to use `tool/call` and explain OpenAPI
  upstreams.
- Add release dry-run or integration coverage only if it can run without real
  Observatory credentials.

Acceptance:

- A developer can run the local fixture config and evaluate representative
  trace-list/search/detail/cost queries without external services.
- Production credentials are never required for CI.

## Migration Plan

1. Land the transport-neutral `tool/call` and `tool/servers` surface for
   existing MCP upstreams and remove `mcp/servers` / `tool/mcp-call` from the
   public Lisp surface in the same cleanup.
2. Normalize catalog metadata and discovery around exposed tool names plus
   transport provenance.
3. Add `transport: "openapi"` config parsing and validation for the curated
   read-only JSON scope.
4. Implement OpenAPI schema read/fetch and operation compilation.
5. Add OpenAPI upstream execution through the existing upstream registry/call
   path.
6. Add Observatory fixture/schema tests.
7. Exercise real Observatory production-like traces and verify payload
   reduction, auth failure behavior, and redaction.

## Decisions Before Implementation

- **Breaking rename:** remove `mcp/servers` and `tool/mcp-call` as public Lisp
  forms when `tool/servers` and `tool/call` land.
- **`tool/call` internal contract:** normalize the symbol form at the Lisp
  boundary to `%{"server" => "...", "tool" => "...", "args" => %{...}}`.
- **Schema source:** require exactly one of `schema_file` or `schema_url`.
- **HTTP dependency boundary:** use existing `:req`, but keep OpenAPI request
  code separate from Streamable HTTP MCP session code.
- **Projection:** defer JSON Pointer/JSONPath projection; v1 returns decoded
  JSON and PTC-Lisp does local shaping.
- **Override precedence:** operator config may narrow or rename `x-ptc-*`
  metadata, but schema metadata must never widen capability beyond
  `include_operations` and process-level gates.
- **Observatory contract:** initial operation ids, auth scopes, required
  tenant/org args, and trace-step summary defaults should be treated as part of
  the fixture/schema contract before production exercise.

## Deferred Questions

- How much JSON Schema validation/coercion should happen before the request in
  v1?
- Should OpenAPI operation names preserve snake_case or be normalized to
  kebab-case for PTC-Lisp display? Current preference: kebab-case at the Lisp
  surface, original operation id in metadata.
- Should direct synthetic calls like `(observatory/list-traces {...})` be added
  later as sugar over `(tool/call 'observatory/list-traces {...})`?
- Should write operations require both config allow-listing and a process-level
  `--aggregator-allow-writes` style flag?
