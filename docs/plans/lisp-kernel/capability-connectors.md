# Capability connectors and server frontends

Status: future plan, reviewed 2026-07-13. Not implemented and not part of the
normative V1 Kernel contract.

This plan describes how PtcRunner can consume tools from MCP, HTTP/OpenAPI,
databases, files, and native host extensions without rebuilding the deleted
generic upstream platform. It also separates that outbound extension work from
future HTTP or MCP frontends that expose PtcRunner workflows to other clients.

The central decision is:

> Make the generic abstraction a host-installed **capability source**, not an
> upstream server. Resolve every selected source into immutable
> `Kernel.Capability` values before a run begins; keep transport, credentials,
> sessions, and native handles outside Lisp.

The [`kernel-contract.md`](kernel-contract.md) remains authoritative until a
future slice promotes an approved part of this plan into that contract.

## Why this fits the current Kernel

The extension seam already exists:

- `Kernel.Capability` owns the public name, validator, bounded description,
  model visibility, and host callback.
- `Kernel.ProviderRegistry` maps bounded manifest names to host-owned builders.
- `Kernel.RunBuilder` resolves those builders before constructing separate
  workflow and mission environments.
- `Kernel.Dispatcher` validates arguments, atomically charges quota, contains
  provider processes, enforces timeout/heap/result limits, rejects late
  results, and creates the uniform Lisp result envelope.
- Manifests can select registered authority but cannot register executable
  callbacks or name Elixir modules and functions.

The current limitation is that a builder returns exactly one capability and
the manifest supplies provider configuration directly. A remote MCP server,
an OpenAPI document, or a database catalog normally produces several tools and
requires host-owned connection and cleanup state.

The old `lib/ptc_runner/upstream/**` and `mcp_server/` products combined
transport, discovery, credentials, sessions, roles, prompts, catalogs, policy,
and evaluator behavior. That breadth was deleted during the Kernel migration.
This plan restores only the small transport-to-capability normalization layer.

## Two independent directions

Do not use one subsystem for both directions.

| Direction | Purpose | Boundary |
| --- | --- | --- |
| Outbound connector | PtcRunner calls an MCP tool, fixed HTTP operation, database query, file operation, or native extension. | Installed source resolves to frozen `Kernel.Capability` values. |
| Inbound frontend | An HTTP or MCP client invokes a PtcRunner workflow. | Thin server invokes an administrator-installed named manifest through `RunBuilder`. |

An inbound MCP frontend is not an MCP connector. It does not grant an active
run access to every tool available to the calling MCP client, and it must not
reintroduce mutable evaluator sessions or upstream catalogs.

## Goals

- Give non-Elixir users useful external tools through manifests and PTC-Lisp.
- Use one transport-independent capability contract for local and remote
  extensions.
- Preserve workflow/mission authority separation and immutable environments.
- Keep destinations, commands, credentials, connection strings, and native
  callbacks under administrator control.
- Freeze selected names, schemas, metadata, limits, and source identity before
  execution.
- Reuse the existing dispatcher and canonical event vocabulary.
- Add one narrow connector at a time with end-to-end confinement tests.

## Non-goals

- A manifest-defined generic HTTP client, arbitrary SQL tool, shell command, or
  arbitrary MCP stdio command.
- Dynamic tool installation or capability mutation during a run.
- Restoring roles, mutable catalogs, prelude stores, or the deleted SubAgent
  and session products.
- Passing credentials, connection handles, PIDs, callbacks, or transport
  objects into Lisp values.
- Treating a provider subprocess as hostile-code isolation. Adversarial native
  extensions still require a separate node or OS/container boundary.
- Supporting every MCP feature in the first connector. Prompts, resources,
  sampling, elicitation, tasks, and arbitrary protocol extensions remain out of
  scope until the tools path is proven.

## Proposed vocabulary

Use names that distinguish installed authority from selected authority:

- **capability source** — an administrator-installed definition that can
  produce one or more capabilities;
- **source adapter** — trusted host code for `local`, `mcp`, `openapi`, or a
  database adapter;
- **source instance** — one installed and credential-bound configuration, such
  as `github-production` or `reporting-db`;
- **grant** — the bounded subset and limits selected for one manifest
  destination;
- **connector lease** — opaque host-owned lifecycle state released when
  building fails or the run ends;
- **capability snapshot** — the frozen public names, schemas, metadata, limits,
  upstream identity, and content hash used by one run.

`ProviderRegistry` may be renamed in a breaking slice because “provider” is
easily confused with an LLM vendor. The important change is semantic: registry
entries return a bounded capability set and optional lease, not just one
callback.

## Proposed host contract

The exact structs belong in the implementation contract before code is added.
The intended shape is:

```elixir
@type build_context :: %{
        manifest_directory: binary(),
        destination: :workflow | :mission,
        installed_ceilings: Limits.t()
      }

@type built_source :: %{
        capabilities: [Capability.t()],
        snapshot: CapabilitySnapshot.t(),
        lease: ConnectorLease.t() | nil
      }

@callback build(installed_config(), grant(), build_context()) ::
            {:ok, built_source()} | {:error, ConnectorError.t()}
```

`Kernel.Capability` needs additional frozen metadata:

```elixir
%Kernel.Capability{
  name: "github.issues.search",
  description: "Search visible GitHub issues",
  input_schema: %{...},
  output_schema: %{...},
  effect: :read,
  model_visible: true,
  timeout_ms: 5_000,
  max_result_bytes: 256_000,
  callback: host_owned_callback
}
```

Schemas should use a documented bounded JSON Schema profile. Unsupported
keywords, excessive depth/size, remote `$ref`, ambiguous keys, or non-object
argument roots fail during source resolution. The capability callback and
connector lease remain excluded from discovery metadata and all Lisp values.

### Lifecycle

1. The host loads installed source instances and credentials.
2. The manifest selects a source, destination, allowlist, and requested limits.
3. The adapter discovers or loads source metadata under separate build-time
   ceilings.
4. Names are explicitly mapped, schemas are checked, grants are intersected,
   and a deterministic snapshot hash is created.
5. `RunBuilder` inserts only the resulting capabilities into the chosen
   environment.
6. Calls go through the existing `Kernel.Dispatcher`.
7. Any source lease is released exactly once after build failure, normal
   completion, abort, or frontend cancellation.

For the first remote connector, prefer a per-run lease. Pooling can be added
later only if credentials, session isolation, cancellation, and cleanup remain
unambiguous.

## Configuration boundary

Examples in this document are proposed syntax. They do not work on the current
branch yet.

Administrator configuration creates authority:

```yaml
capability_sources:
  github-production:
    adapter: mcp
    transport: streamable_http
    endpoint: https://mcp.example.internal/mcp
    credentials_ref: github-production
    protocol_version: "2025-11-25"
    tools:
      searchIssues:
        as: github.issues.search
        effect: read
      getIssue:
        as: github.issues.get
        effect: read

  reporting-db:
    adapter: postgres
    connection_ref: reporting-readonly
    operations_file: config/reporting-operations.json

  workspace-files:
    adapter: file
    root: /srv/jobs/workspace
    operations: [read, list, stat]
```

The manifest only selects installed authority:

```json
{
  "version": 2,
  "workflow": {
    "components": [{"id": "agent", "path": "agent.lisp"}],
    "entry": "agent/run"
  },
  "mission": {"components": [], "data": {}},
  "input": {"path": "request.json"},
  "capabilities": {
    "workflow": [
      {"source": "deepseek", "allow": ["llm.request"]}
    ],
    "mission": [
      {
        "source": "github-production",
        "allow": ["github.issues.search", "github.issues.get"],
        "limits": {"calls": 8, "timeout_ms": 5000}
      }
    ]
  }
}
```

The version is shown as `2` to make clear that this would be a breaking
manifest change. Do not add a compatibility shim to the 0.x loader. Installed
source configuration must have its own strict schema and must not share the
manifest directory or trust boundary.

## Example: consuming an MCP server

### Administrator setup

The administrator installs the endpoint, credentials, public-name mapping,
and allowed effect classification:

```yaml
capability_sources:
  issue-tracker:
    adapter: mcp
    transport: streamable_http
    endpoint: https://tools.internal.example/mcp
    credentials_ref: issue-tracker-oauth
    tools:
      search_issues:
        as: issues.search
        effect: read
      add_comment:
        as: issues.comment.create
        effect: write
        approval: required
```

Do not automatically lowercase or rewrite arbitrary MCP names. Explicit
mapping prevents lossy collisions between names that are distinct upstream but
would normalize to the same Kernel name.

### Manifest grant

This workflow grants only the read operation to mission evaluation:

```json
"capabilities": {
  "mission": [
    {
      "source": "issue-tracker",
      "allow": ["issues.search"],
      "limits": {"calls": 3, "timeout_ms": 4000}
    }
  ]
}
```

The omitted `issues.comment.create` operation does not exist in the mission
environment, even though the installed source knows about it.

### PTC-Lisp call

```clojure
(ns issue-report
  "Summarize matching issues.")

(defn run [input]
  (let [response (tool/issues.search {"query" (get input "query")
                                      "limit" 10})]
    (if (= :ok (get response :status))
      (return {"issues" (get response :value)})
      (fail {:reason :issue-search-failed
             :details response}))))
```

The compiler infers the `tool:issues.search` requirement from the qualified
`tool/` call and environment assembly rejects the bundle when the capability
was not granted.

At build time, the adapter performs the MCP initialization and paged
`tools/list`, validates the selected tool schema, creates a snapshot, and
freezes the callback. At call time it sends `tools/call` with the fixed upstream
tool name and validated JSON arguments.

If MCP returns structured content with an output schema, validate it and expose
the structured JSON value. A bounded text-only result may be normalized into a
documented JSON content envelope. Images, audio, embedded resources, and
resource links should be rejected in the first slice rather than silently
decoded into large or authority-bearing values.

An MCP tool result with `isError: true` is a completed remote call with a domain
error, not a transport or protocol failure. Normalize it as a recoverable
domain outcome. JSON-RPC, authentication, schema, session, or transport
failures become bounded `ProviderError` values and the dispatcher creates the
standard error envelope.

### Tool-list changes

The current run remains immutable when an MCP server advertises
`notifications/tools/list_changed`. Record the notification, mark the installed
source stale for the next build, and do not add or remove active capabilities.
If a frozen upstream tool disappears, its next call returns a bounded provider
error. A later run receives a newly validated snapshot.

## Example: consuming an OpenAPI service

Do not provide a generic `http/request` capability. Compile selected operations
from an administrator-installed OpenAPI document:

```yaml
capability_sources:
  inventory-api:
    adapter: openapi
    document: /etc/ptc/openapi/inventory.json
    base_url: https://inventory.internal.example
    credentials_ref: inventory-service
    operations:
      getInventoryItem:
        as: inventory.item.get
        effect: read
```

Manifest:

```json
"capabilities": {
  "mission": [
    {
      "source": "inventory-api",
      "allow": ["inventory.item.get"],
      "limits": {"calls": 5, "timeout_ms": 3000}
    }
  ]
}
```

PTC-Lisp:

```clojure
(let [response (tool/inventory.item.get {"sku" "A-1042"})]
  (if (= :ok (get response :status))
    (return (get response :value))
    (fail {:reason :inventory-unavailable :details response})))
```

The adapter owns URL construction, parameter encoding, authentication,
redirect policy, content types, and response decoding. The manifest cannot
override the base URL or headers. Redirects must remain inside an installed
destination allowlist, and request/response bodies remain bounded.

## Example: database operations

Expose administrator-defined named operations, not model-authored SQL:

```json
{
  "orders.find": {
    "sql": "SELECT id, status, total FROM orders WHERE customer_id = $1 ORDER BY id DESC LIMIT $2",
    "effect": "read",
    "parameters": {
      "type": "object",
      "properties": {
        "customer_id": {"type": "integer"},
        "limit": {"type": "integer", "minimum": 1, "maximum": 50}
      },
      "required": ["customer_id", "limit"],
      "additionalProperties": false
    },
    "result": {
      "type": "array",
      "maxItems": 50,
      "items": {
        "type": "object",
        "properties": {
          "id": {"type": "integer"},
          "status": {"type": "string"},
          "total": {"type": "number"}
        },
        "required": ["id", "status", "total"],
        "additionalProperties": false
      }
    }
  }
}
```

Manifest grant:

```json
{"source": "reporting-db", "allow": ["orders.find"], "limits": {"calls": 2}}
```

PTC-Lisp:

```clojure
(let [response (tool/orders.find
                 {"customer_id" (get data/input "customer_id")
                  "limit" 20})]
  (if (= :ok (get response :status))
    (return {"orders" (get response :value)})
    (fail {:reason :order-query-failed :details response})))
```

The adapter uses prepared parameters, a read-only database role, statement
timeout, row/result-size limits, and explicit JSON conversion. Write operations
need separate installed entries, idempotency policy, audit events, and any
required approval boundary. A general `database/query` accepting a SQL string
is outside this plan.

## Example: file operations

The existing `file-read` provider already demonstrates that a local operation
can use the same capability boundary without a network server. A future source
can group several separately granted operations:

```yaml
capability_sources:
  job-inputs:
    adapter: file
    root: /srv/ptc/jobs/current/input
    operations:
      read: {as: file.read, max_bytes: 1048576}
      list: {as: file.list, max_entries: 200}
      stat: {as: file.stat}
```

```clojure
(let [files-response (tool/file.list {"path" "reports"})]
  (if (= :ok (get files-response :status))
    (return (get files-response :value))
    (fail {:reason :file-list-failed :details files-response})))
```

Each operation retains descriptor/path identity checks, symlink confinement,
type checks, UTF-8/JSON normalization where applicable, and independent result
limits. File writes should be a separate adapter or installed source so a
read-only grant cannot accidentally expand through configuration.

## Example: native host extensions

Elixir embedders can continue installing direct builders. They use the same
snapshot and metadata rules but skip transport discovery:

```elixir
source = fn _installed, grant, %{destination: :mission} ->
  with true <- "clock.now" in grant.allow,
       {:ok, capability} <-
         Capability.new(
           name: "clock.now",
           description: "Return the host UTC time",
           input_schema: %{"type" => "object", "additionalProperties" => false},
           output_schema: %{
             "type" => "object",
             "properties" => %{"timestamp" => %{"type" => "string"}},
             "required" => ["timestamp"]
           },
           effect: :read,
           callback: fn %{} ->
             {:ok, %{"timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()}}
           end
         ) do
    {:ok, %{capabilities: [capability], snapshot: snapshot(capability), lease: nil}}
  else
    _ -> {:error, :invalid_clock_grant}
  end
end
```

This is trusted host code. Kernel contains ordinary faults but does not make a
malicious native callback safe.

## Example: exposing PtcRunner through HTTP

An inbound HTTP frontend should expose administrator-installed workflow names,
not arbitrary manifests or capability-source definitions:

```http
POST /v1/workflows/order-summary/runs
Content-Type: application/json
Authorization: Bearer <deployment token>

{"input": {"customer_id": 42}}
```

```json
{
  "ok": true,
  "run_id": "run-a13f09e21c44",
  "result": {"orders": []},
  "usage": {"capability_calls": 1, "evaluations": 2},
  "trace": "/v1/runs/run-a13f09e21c44/events"
}
```

The frontend resolves `order-summary` to a server-installed manifest, supplies
only validated input and request labels, invokes the shared `RunBuilder`, and
uses stable JSON error envelopes. Authentication, rate limiting, input size,
concurrency, cancellation, and trace access are frontend policy. They do not
change Kernel authority.

Start synchronously. Add a durable job API only when real deployments need
queueing, cancellation, or results that outlive the request process.

## Example: exposing PtcRunner as an MCP server

A thin inbound MCP frontend can publish installed workflows as MCP tools:

```json
{
  "name": "ptc.order_summary",
  "description": "Run the installed bounded order-summary workflow",
  "inputSchema": {
    "type": "object",
    "properties": {"customer_id": {"type": "integer"}},
    "required": ["customer_id"],
    "additionalProperties": false
  }
}
```

`tools/call` invokes one named manifest and returns its bounded structured
result. The frontend should not expose general Lisp evaluation, mutable
sessions, arbitrary manifest paths, connector configuration, credentials, or
ambient tool forwarding. This keeps it a protocol adapter over the same CLI
product rather than a second orchestration product.

## MCP scope and protocol position

The first outbound MCP slice targets the stable MCP `2025-11-25` tools
contract:

- initialization and negotiated protocol version;
- Streamable HTTP transport;
- paginated `tools/list`;
- `tools/call`;
- input and optional output schemas;
- bounded text or structured JSON results;
- explicit session cleanup when the server supports it;
- observation of tool-list change notifications without mutating the active
  snapshot.

The official specification defines stdio and Streamable HTTP transports. Start
with Streamable HTTP because stdio requires launching and supervising an
administrator-selected subprocess. Add stdio later with explicit executable,
argument, environment, stderr, child-process, and resource policies.

References:

- [MCP 2025-11-25 transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- [MCP 2025-11-25 tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
- [MCP 2025-11-25 authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)

Pin supported protocol versions in installed configuration and tests. A future
MCP specification does not silently change the semantics of an existing
PtcRunner release.

## Authority and security rules

- Endpoints, executable commands, database connections, credentials, and
  native builders are installed by the host, never supplied by a manifest.
- The manifest allowlist only narrows an installed source. It can never widen
  its tools, destinations, effects, limits, or model visibility.
- Workflow and mission grants remain structurally separate. LLM/control tools
  normally belong to workflow; model-authored domain/data tools normally
  belong to mission.
- Connector metadata is untrusted until bounded and validated. MCP annotations
  and OpenAPI descriptions do not create authority.
- Secrets never enter Lisp data, prompts, results, errors, normal traces, or
  snapshot hashes.
- HTTP clients enforce scheme, host, port, DNS/IP, redirect, proxy, and maximum
  body policy to prevent SSRF and authority expansion.
- Remote results are untrusted JSON. Validate keys, depth, size, schemas, UTF-8,
  finite numbers, and duplicate-key behavior before they re-enter Lisp.
- External effects cannot be rolled back when a run times out. Write tools need
  clear effect metadata, idempotency behavior, retry rules, and optional
  approval policy.
- Native adapters remain trusted extension code. Remote servers may be
  untrusted, but the adapter parsing their messages is part of the trusted host
  boundary.

## Errors and result normalization

Keep the existing Kernel dispatch envelope. Connector adapters return only
`{:ok, json_value}` or `{:error, ProviderError.t()}`. Prefer the current closed,
transport-neutral `ProviderError` kinds:

- `:denied` for an installed authentication or authorization rejection;
- `:not_found` for a removed or unknown frozen operation;
- `:unavailable` for network, remote-session, or service availability failure;
- `:invalid_request` for a request rejected before useful remote execution;
- `:internal` for a contained adapter invariant or normalization failure.

The dispatcher continues to own timeout, invalid-result, result-exceeded,
quota, and run-closure classifications. Do not create parallel MCP, HTTP, or
database variants of those errors. If a real connector proves the closed
vocabulary insufficient, change the Kernel contract and all adapters together
before adding a new kind.

Exact upstream exceptions, URLs with query parameters, headers, SQL, stack
traces, response bodies, and credentials do not become Lisp-visible details.
Canonical events may record installed source name, public capability name,
adapter kind, snapshot hash, status, duration, and bounded usage. Diagnostic
transcripts remain separately opt-in and redacted.

## Implementation phases

### C0: contract prerequisites

- Add bounded input/output schemas and effect metadata to `Kernel.Capability`.
- Define the installed-source, manifest-grant, snapshot, lease, and error
  structs before runtime work.
- Separate installed ceilings from manifest-requested limits.
- Define stable machine-readable build/CLI errors.

Exit gate: one local multi-capability fixture source builds deterministic
snapshots, rejects schema/name/grant errors, and cleans up exactly once.

### C1: generic source assembly

- Generalize registry builders to return bounded capability lists.
- Freeze source identity, public name mapping, schemas, effects, visibility,
  quotas, and hashes into each environment.
- Add lease ownership to every `RunBuilder` success/failure/abort path.
- Expose source and snapshot facts through sanitized canonical events.

Exit gate: two sources may provide several capabilities without name
collisions, authority expansion, lifecycle leaks, or changes to Dispatcher
semantics.

### C2: MCP Streamable HTTP tools

- Implement initialization, version negotiation, paginated discovery,
  `tools/call`, session handling, cancellation, and cleanup.
- Support a strict structured/text result subset.
- Treat list changes as next-run refreshes.
- Bind credentials and endpoints only through installed configuration.

Exit gate: a real fixture MCP server works end to end through a manifest and
PTC-Lisp, while contract tests cover malformed JSON-RPC, authentication,
pagination, tool changes, disconnects, timeout, cancellation, late replies,
oversized results, schema mismatch, redirects, and secret redaction.

### C3: second adapter proof

Implement either OpenAPI operations or database named queries. Choose based on
an immediate user workflow, not a desire for adapter count.

Exit gate: the second adapter demonstrates that the source contract is truly
transport-neutral without adding adapter-specific behavior to Kernel,
Dispatcher, Lisp, or component compilation.

### C4: inbound frontend

Add a thin HTTP or MCP frontend over administrator-installed named manifests.
Do not combine it with outbound source discovery.

Exit gate: the same manifest produces equivalent bounded results and canonical
events through CLI and the server frontend, with frontend authentication,
concurrency, cancellation, and input limits tested separately.

## Required test matrix

- Installed configuration rejects unknown keys, unsafe paths, arbitrary
  destinations, commands, credentials, and excessive definitions.
- Manifest grants cannot select unknown sources/tools or override installed
  endpoints, effects, schemas, credentials, or ceilings.
- Public-name mapping is explicit, deterministic, collision-free, and stable
  across discovery order.
- Schema discovery is bounded by bytes, depth, count, time, and supported
  keywords.
- Duplicate JSON keys, invalid UTF-8, non-finite numbers, non-JSON values, and
  oversized results fail before reaching Lisp.
- Provider slot, call quota, timeout, heap, result, run closure, and late-result
  behavior remain those of the existing dispatcher.
- Build failure and run termination release each lease once without
  `Process.sleep`-based tests.
- HTTP redirects, DNS changes, proxies, and resolved addresses cannot escape
  installed destination policy.
- MCP discovery pagination, session expiry/reinitialization, tool removal,
  list-change notification, explicit cancellation, and cleanup are covered.
- Database operations use prepared parameters and enforce role, statement,
  rows, result, and transaction limits.
- Secrets are absent from results, errors, standard logs, normal traces,
  snapshots, and viewer responses.
- Write retries cannot duplicate an effect without declared idempotency or an
  explicit workflow decision.
- CLI and any inbound frontend produce the same Kernel result and event facts
  for the same installed manifest and input.

## Decisions to make before C0

1. Rename `ProviderRegistry` now or retain the name until the manifest V2
   schema lands.
2. Choose the supported JSON Schema dialect/profile and whether schemas are
   stored verbatim or normalized.
3. Decide whether per-capability limits live only in installed configuration or
   may be lowered in a manifest grant.
4. Define read/write/idempotent/destructive effect metadata and any approval
   hook without making annotations authorization.
5. Define the result subset for MCP text and structured content.
6. Decide whether connector sessions are always per run in the first release.
7. Choose the first real MCP fixture/server and one user journey that proves
   value without domain-specific system prompts.

## Related documents

- [`product-readiness.md`](product-readiness.md) — product sequence and release
  gates; this plan expands its capability-ecosystem phase.
- [`kernel-contract.md`](kernel-contract.md) — current normative V1 authority
  and dispatch behavior.
- [`tracelog-contract.md`](tracelog-contract.md) — sanitized canonical event
  and source contract.
- [Kernel component bundles](../../guides/capability-prelude.md) — current
  component requirements and capability authority.
- [Kernel tutorial](../../guides/kernel-tutorial.md) — current implemented
  manifest and PTC-Lisp user journey.
