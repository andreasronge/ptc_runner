# Capability connectors

Status: implemented pre-production 0.x vertical slice, reviewed 2026-07-16.
The demand-triggered production follow-ons remain deferred.

## Decision

Ship one useful external-tools path before designing a connector framework:

> Extend the existing provider-builder seam just enough for one installed MCP
> source to produce several frozen `Kernel.Capability` values for one run.

The milestone is not complete at “the HTTP call works.” It must also supply one
runnable developer journey in which a model receives a frozen mission inventory,
generates PTC-Lisp that calls the discovered tools, and the completed exchange
can be inspected locally in `ptc_viewer`. This inspection path is explicitly
host-enabled and private; it does not make sensitive payloads part of canonical
traces.

The first release does not include a transport-neutral adapter hierarchy, a
catalog service, shared IAM, database configuration, inbound server frontend,
or dynamic capability changes. Those features require separate evidence.

## Why this is enough

The current Kernel already supplies the important runtime boundary:

- `Kernel.Capability` owns a public name, validation, description, visibility,
  and host callback.
- `Kernel.ProviderRegistry` maps bounded manifest names to trusted host
  builders.
- `Kernel.RunBuilder` resolves providers before creating separate immutable
  workflow and mission environments.
- `Kernel.Dispatcher` validates arguments, charges quota atomically, contains
  provider work, enforces limits, rejects late results, and normalizes errors.
- `Kernel.TraceCapability.new/1` already demonstrates that one trusted source
  can naturally produce several capabilities.

The missing vertical path is MCP discovery, installed endpoint and credential
configuration, schema/result validation, session ownership, and cleanup. It is
not a reason to model OpenAPI, databases, files, and native Elixir up front.

## MVP scope

The MCP MVP supports:

- one host-installed MCP Streamable HTTP source type;
- read-only tools initially;
- one source producing a bounded list of capabilities;
- explicit upstream-to-public name mappings;
- discovery during run assembly;
- one run-owned MCP session used for discovery and calls;
- frozen per-run tool metadata and snapshot hash;
- strict input and output validation;
- bounded JSON/text results;
- cleanup on build failure, completion, timeout, cancellation, caller death,
  and run closure;
- safe connector snapshot metadata in the canonical run summary; and
- one opt-in local inspection artifact for the development journey described in
  [`host-access-and-prelude-workspaces.md`](host-access-and-prelude-workspaces.md).

It explicitly excludes:

- cached or persisted catalogs and refresh commands;
- automatic startup discovery;
- OpenAPI and database adapters;
- filesystem roots beyond the existing explicit file capability;
- MCP resources, prompts, sampling, elicitation, and roots;
- a background Streamable HTTP GET notification stream, resumability, or tasks;
- writes, approval workflows, and automatic retries;
- a generic source behaviour intended for adapters that do not exist yet;
- shared principals, grants, roles, or policy engines;
- inbound HTTP or MCP exposure of PtcRunner; and
- changes to a run's capabilities after assembly.

## Minimal host seam

The host passes the exact registry available to a run build. Possession of that
registry is the 0.x source-authorization boundary; there is no process-global
catalog and no manifest-selectable access profile. A manifest cannot reach a
source omitted from the supplied registry.

Keep the implemented registry's arity-two builder contract. An installed MCP
source is one additional registry entry whose builder closure owns the endpoint,
credential callback, public-name mappings, and installed ceilings. The JSON
config supplied by the manifest is only the selection for that installed entry.

Normalize registry builder results internally to the following small shape:

```elixir
@type built_provider :: %{
        capabilities: [Kernel.Capability.t()],
        snapshot: map() | nil,
        close: (-> :ok) | nil
      }

@type builder ::
        (manifest_selection(), build_context() ->
           {:ok, built_provider()} | {:error, term()})
```

The existing `llm` and `file-read` builders normalize to one capability with no
snapshot or close function. The MCP-specific constructor may expose a host API
that returns the installed builder closure; it does not imply a generic
`CapabilitySource` behaviour.

`build_context` needs only the destination, manifest directory where already
required by current providers, the building owner PID, and installed execution
ceilings. It is connector execution context, not `H0-lite` and not a reusable
authorization vocabulary. A run ID or correlation vocabulary is unnecessary at
this seam: safe snapshots are copied into `RunConfig` and correlated when
`run-started` is emitted.

The manifest may select an installed source, public tool names, destination,
and lower limits. It cannot provide an endpoint, credential, command, module,
function, access profile, grant, or source configuration.

Do not extract a public `CapabilitySource` behaviour in this milestone. A
public MCP-specific constructor plus the existing registry builder function is
enough. If a second real remote adapter later needs the same shape, extract only
the common fields and lifecycle proven by both implementations.

## Resource ownership

Discovery currently occurs before `Kernel.Runner` creates `RunState`, and the
implemented `RunConfig` has no provider-resource field. The connector therefore
requires one explicit breaking lifecycle change:

1. `RunBuilder` accumulates each successful builder's idempotent close function.
2. Any later provider, bundle, environment, or config failure closes the
   already-built resources in reverse order.
3. A successful `RunConfig` carries the close functions as opaque host-owned
   resources; they never enter Lisp or discovery metadata.
4. `Runner` first closes `RunState`, which kills and drains attached provider
   workers, and only then closes provider resources.
5. `ReplSession.close/1` performs the same ordering. A built configuration that
   is never run has one explicit `RunBuilder.close/1` path.
6. The MCP lease owner monitors the process that built the run, so caller death
   closes the session even when normal cleanup is skipped.

The lease process makes `close` idempotent and owns session termination; it is
not a pool, catalog, or general resource manager. In-flight HTTP work executes
in the dispatcher's attached provider worker so timeout or caller death kills
the request before the lease is closed.

## Run lifecycle

For every run build:

1. Resolve the requested alias from the host-supplied registry.
2. Load its installed endpoint, credential callback, mappings, and ceilings.
3. Start one owned MCP client/session.
4. Initialize and negotiate one supported protocol version.
5. Send `notifications/initialized`.
6. Fetch bounded, paginated `tools/list` in that same session.
7. Validate names, descriptions, schemas, and configured mappings.
8. Intersect installed tools and ceilings with manifest names, destination,
   and lower limits.
9. Freeze the selected metadata and deterministic snapshot hash.
10. Insert callbacks closed over the same source, session, and upstream name.
11. Route calls through `Kernel.Dispatcher`.
12. Cancel and drain provider work before closing the session when the run
    ends or assembly fails.

Discovery during assembly deliberately makes build availability depend on the
remote MCP server. That is an acceptable 0.x tradeoff: it avoids catalog
artifacts, refresh state, and possible disagreement between cached discovery
and a different run session. Add caching only after measured startup or
availability problems justify it.

When a server returns an MCP session ID, subsequent requests use it and cleanup
attempts the transport-defined HTTP `DELETE`. The client accepts bounded
`application/json` and `text/event-stream` responses to POST requests, but does
not open a background GET stream. Notifications received while waiting for a
POST response are bounded and ignored. No notification mutates the current run;
a later run discovers again.

The first implementation pins the 2025-11-25 protocol version and sends the
negotiated version header on later requests. To keep session mutation and retry
races out of this pre-production slice, a session-expired HTTP 404 becomes one
bounded `:session_expired` provider error and closes the lease; a later run
initializes and discovers again. Standards-compliant in-run session recovery is
a documented gap that must close before calling the connector production-ready.
Other automatic retries remain out of scope.

## Frozen capability contract

Each selected tool becomes one ordinary frozen capability containing at least:

```elixir
%Kernel.Capability{
  name: "issues.search",
  description: "Search visible issues",
  input_schema: %{...},
  output_schema: %{...},
  effect: :read,
  model_visible: true,
  callback: host_owned_callback
}
```

Only `input_schema`, `output_schema`, and `effect` need to be added to the
current capability struct. The connector callback enforces its installed and
manifest-narrowed request timeout and raw response ceiling, while the dispatcher
continues to enforce the existing run-wide timeout and argument/result ceilings.
Do not add a generic per-source quota group or per-capability limit hierarchy in
this slice. Existing environment and per-name call budgets remain authoritative.

`input_schema` is required for every model-visible capability and describes its
binary-keyed argument object. `output_schema` is optional and describes only a
successful capability value, not the Dispatcher status envelope. `effect` uses
the same closed `:read | :write | :unknown` vocabulary as prelude exports and
defaults to `:unknown`; every MCP capability in this read-only milestone is
`:read`. Capability metadata projects these fields, while callbacks and compiled
validators remain opaque. Schema validation and the existing semantic
`validate` callback must both pass before dispatch; MCP success values are
validated by the connector before returning to Dispatcher.

Exact call authority remains structural:

```text
host-supplied source registry
        ∩ installed tool mapping and ceilings
        ∩ manifest selection and lower limits
        ∩ workflow/mission destination
        ∩ frozen environment membership
```

The callback is closed over one fixed upstream source and tool name. No generic
grant or runtime string selects a different operation.

Input and output schemas use a deliberately small JSON Schema 2020-12 profile.
V1 accepts `type`, `title`, `description`, `properties`, `required`,
`additionalProperties`, `items`, `enum`, `const`, `minimum`, `maximum`,
`minLength`, `maxLength`, `minItems`, and `maxItems`. It rejects reference,
composition, conditional, pattern, and unevaluated keywords. `type` is one
scalar JSON type rather than a union. Input roots and advertised output roots
are objects. Missing `additionalProperties` is normalized to `false` on every
object, deliberately narrowing the upstream contract. Each schema is at most
64 KiB encoded, depth 16, 128 properties per object, and 256 enum members;
catalog-wide limits apply in addition. JSV compiles this profile once during
assembly. Unsupported keywords, excessive structure, duplicate/ambiguous keys,
or non-object roots fail assembly. The first version rejects images, audio,
embedded resources, and resource links.

Result normalization is deliberately deterministic:

- `isError: true` becomes a bounded non-retryable provider/domain error;
- when `structuredContent` is present, validate it against the advertised
  output schema and return that JSON object as the capability value; and
- otherwise accept text-only content blocks and return
  `%{"text" => [bounded_text, ...]}`.

`isError` takes precedence over content. Structured content without an
advertised output schema, text-only content when an output schema was
advertised, mixed structured/text results, and any unsupported content block
become bounded `:invalid_result` provider errors.

Reject mixed or unsupported content rather than guessing, concatenating text,
or exposing raw MCP envelopes to Lisp.

## Configuration example

The host installation API remains illustrative because it is trusted Elixir
configuration:

```elixir
issue_tracker =
  MCPSource.builder(
    endpoint: "https://tools.internal.example/mcp",
    headers: fn ->
      [{"authorization", "Bearer " <> System.fetch_env!("ISSUE_TRACKER_TOKEN")}]
    end,
    tools: %{
      "search_issues" => %{as: "issues.search", effect: :read}
    }
  )

ProviderRegistry.new(%{"issue-tracker" => issue_tracker})
```

Manifest selection stays inside the existing `providers` shape:

```json
{
  "providers": {
    "mission": [
      {
        "name": "issue-tracker",
        "config": {
          "allow": ["issues.search"],
          "timeout_ms": 4000,
          "max_result_bytes": 256000
        }
      }
    ]
  }
}
```

The manifest `config` above is the exact MCP V1 selection shape. `allow` is
required and contains 1–128 unique mapped public capability names. Optional
`timeout_ms` and `max_result_bytes` are positive integers no greater than the
installed source ceilings or effective run ceilings. Unknown keys, upstream
tool names, duplicate names, an empty allowlist, or a name omitted from the
installed mapping fail assembly. Effect, endpoint, headers, credentials,
protocol version, and retry policy are never manifest fields.

The host application decides which source registry is supplied for that build.
The manifest cannot name another registry or expand the installed mapping.

The safe connector projection added to `run-started.data` is exactly
`connector_snapshots`, sorted by provider name:

```json
[
  {
    "provider": "issue-tracker",
    "protocol": "mcp-2025-11-25",
    "snapshot_hash": "lower-case-sha256",
    "tools": [
      {
        "name": "issues.search",
        "effect": "read",
        "input_schema_hash": "lower-case-sha256",
        "output_schema_hash": "lower-case-sha256-or-null"
      }
    ]
  }
]
```

Tools are sorted by public name. Schema hashes cover the normalized compact
JSON schema bytes used by the validator. `snapshot_hash` covers `protocol` and
the sorted `tools` array with keys in the order shown. The projection excludes
the endpoint, upstream names, headers, credentials, session ID, descriptions,
and full schemas. The complete model-visible schemas remain in the frozen
mission inventory and, when enabled, its captured LLM request.

Use one small internal deterministic JSON encoder for schema, inventory, and
snapshot hashes rather than three hashing implementations. It requires binary
object keys, sorts every object recursively by UTF-8 key bytes, preserves array
order, emits no insignificant whitespace, and rejects duplicate keys before
ordinary maps erase them. It is a hashing/rendering utility, not a new public
serialization format. Source hashes continue to cover exact source bytes and do
not use this encoder.

## Security and error rules

- Accept the endpoint only from host installation, require HTTPS except for an
  explicit loopback fixture mode, disable redirects, and never adopt an
  endpoint supplied by an MCP response. Proxy use is an explicit host option.
- Keep credentials and session IDs out of Lisp values, prompts, errors,
  ordinary traces, and snapshot hashes.
- Treat MCP metadata and results as untrusted input.
- Use stable bounded connector errors; do not return endpoints, headers,
  credentials, raw response bodies, stack traces, or local paths.
- Treat `isError: true` as a completed remote domain error. Treat JSON-RPC,
  authentication, transport, session, and schema failures as provider errors.
- Do not retry writes. The MVP is read-only.
- Provider callback processes are run-owned. Rejecting a late reply is not
  enough if external work continues after the run closes.

The MVP pins the MCP protocol version supported by its implementation and
tests. Relevant protocol contracts are [MCP tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
and [MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).

Make `Req` and `JSV` direct, pinned dependencies for this feature. Do not
implement an HTTP client or a JSON Schema evaluator inside PtcRunner. Support
one documented bounded subset of JSV's 2020-12 profile and reject unsupported
or remote-reference schemas during assembly.

### Connector observability

Connectors use the existing observability planes rather than installing a
connector-specific logger or trace sink:

- `Dispatcher` emits the canonical capability lifecycle and safe connector
  snapshot metadata through `Kernel.EventSink`;
- sparse operator diagnostics may use Elixir `Logger`, but never include the
  endpoint, credentials, headers, session ID, arguments, results, or response
  body;
- optional Telemetry reports aggregate transport measurements with
  low-cardinality tags and is never required for correctness; and
- exact bounded arguments and normalized results/errors go only to the
  host-enabled `InspectionSink`.

The connector callback does not mirror one call into multiple trace schemas.
Run, capability, and evaluation IDs provide correlation between the canonical
trace and private inspection sidecar.

## Database position

There is no 0.x configured database connector.

An Elixir host can already expose a named operation through trusted native code
using its existing Ecto, Postgrex, or MyXQL stack. That is the first database
path: the Kernel sees only an ordinary capability callback and schemas.

Do not add PostgreSQL packages to the core dependency tree or design YAML SQL,
pool references, type normalization, cursor bounds, redaction, and transaction
semantics until a concrete deployment cannot reasonably use native Elixir.
If that demand appears, start with a separate PostgreSQL read-only package for
fixed named queries—never a universal “connect to databases” feature.

## One delivery milestone

The MCP work is one product milestone. Small reviewable commits are useful, but
the milestone is not done until a real read-only MCP call works from manifest
through PTC-Lisp and cleanup completes.

### Small prerequisites

The connector transport should not be built before the model can reliably use
and diagnose it. Only these existing roadmap items are prerequisites:

1. Manifests can select the shipped `agent.core` dependency closure without
   copying its source. This is read-only installed library selection, not a
   prelude workspace.
2. `agent.core` receives a bounded frozen mission inventory rendered from
   `Prelude.prompt_exports/1` and model-visible capability metadata, including
   schemas, through the workflow-only `kernel-mission-inventory` route. The
   system prompt remains domain-blind and the route transfers no mission
   authority.
3. Installed ceilings are distinct from manifest-requested lower limits so one
   remote model/tool round trip fits within a practical bounded run.
4. The opt-in local inspection artifact and Viewer rendering described in the
   host/prelude plan can show the exact model request, normalized response,
   generated program, connector arguments/result, and evaluation outcome.

These are one narrow integration seam, not a prerequisite for IAM, workspaces,
catalog caching, arbitrary installed libraries, or production packaging.

### Implementation order

1. Add capability input/output schemas and effect metadata.
2. Normalize registry builder results and implement transactional resource
   ownership across build, run, and REPL closure.
3. Add Streamable HTTP initialization, discovery, calls, validation, and
   session cleanup.
4. Add safe connector snapshots to canonical run metadata and render them in
   `ptc_viewer`.
5. Complete the developer validation journey below.

### Developer validation journey

Check in one protocol-faithful fixture MCP server and a small, domain-neutral
lab setup. It must be runnable without credentials using a scripted LLM and may
also have one optional live-model E2E variant.

The matrix stays intentionally small:

- the existing `file-read` mission provider;
- one host-native fixture capability registered through the existing builder
  seam; and
- one MCP source exposing a structured-result tool, a text-result tool, and a
  tool that returns `isError: true`.

Run the same generic task with a direct capability inventory and with one small
wrapper prelude. This proves installed setup, manifest narrowing, prelude hashes
and prompt projection, tool discovery, generated PTC-Lisp, calls, and results
without pretending that three connector frameworks exist.

Required evidence:

- one real or protocol-faithful fixture MCP server works end to end;
- malformed discovery, pagination, duplicate mappings, invalid schemas, and
  excessive catalogs fail assembly;
- the exact manifest allowlist contract rejects unknown keys and cannot select
  upstream or unmapped names;
- schema-profile boundary fixtures cover every accepted keyword plus rejected
  references, composites, excess depth/properties/enums, and non-object roots;
- connector snapshot ordering and schema/snapshot hashes are byte-stable across
  repeated builds of identical discovery data;
- bad output, oversized content, disconnects, authentication failure, timeout,
  cancellation, caller death, and late replies are bounded;
- run closure cancels and drains work before session cleanup;
- workflow/mission separation and manifest narrowing cannot be bypassed; and
- secrets are absent from errors and ordinary traces;
- the scripted model journey generates and executes a program that uses the MCP
  source, while the file and native variants prove the unchanged local seams;
- `ptc_viewer` shows the safe connector/prelude fingerprints from the canonical
  trace and, only when explicitly enabled, the private model/program/call
  exchange; and
- Viewer API and rendering tests load the artifacts produced by the same
  end-to-end fixture rather than unrelated hand-written JSON.

## Demand-triggered follow-ons

Only add the following after the named evidence exists:

- **Catalog cache:** measured run-build latency or availability problems.
- **Generic source behaviour:** a second real adapter with duplicated code.
- **Configured PostgreSQL adapter:** a deployment that cannot use native
  Elixir named operations.
- **Shared host authorization:** an authenticated non-model caller that needs
  the same source through a domain service.
- **Inbound HTTP/MCP frontend:** a concrete caller that needs to invoke
  PtcRunner remotely; this is a separate plan and trust boundary.

## Related documents

- [`kernel-maintainer.md`](../../guides/kernel-maintainer.md) — current Kernel
  authority, ownership, and dispatch architecture.
- [`host-access-and-prelude-workspaces.md`](host-access-and-prelude-workspaces.md)
  — the small local inspection/prelude-selection prerequisites plus deferred
  host-access and authoring triggers.
- [`product-readiness.md`](product-readiness.md) — roadmap placement.
