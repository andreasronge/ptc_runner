# Host access and prelude workspaces

Status: future implementation plan, reviewed 2026-07-13. This is not part of
the current kernel contract and is not implemented yet.

This plan defines how a human using `ptc_viewer` and a model running inside the
kernel can be given controlled access to host-owned resources. It also defines
the first writable host resource: a versioned prelude workspace in which a
model or human can inspect source, create a candidate, validate it, and propose
or perform promotion when explicitly authorized.

The central decision is deliberately small:

> Share principals, grants, resource identities, bounds, and audit context.
> Keep trace queries, prelude storage, connector transport, and user-interface
> concerns in separate services and adapters.

This avoids two bad outcomes: duplicating authorization rules in every
frontend, or hiding unrelated operations behind an uninspectable generic
`resource/call` capability.

## 1. Relationship to the current kernel

The current kernel already has the right separation for the read-only case:

- `Kernel.TraceLog` owns canonical trace validation and queries;
- `Kernel.TraceCapability` projects selected queries into explicit Lisp
  capabilities;
- `ptc_viewer` has its own adapter to the same trace semantics;
- private trace material requires a separate host-controlled source grant;
- compiled environments and frozen bundles remain immutable during a run.

This plan generalizes the authorization context around those components. It
does not move authorization into Lisp, make the Viewer an authority, or make a
connector responsible for roles or prelude storage.

The following current implementation and contracts remain authoritative until
their own planned changes land:

- [Kernel maintainer guide](../../guides/kernel-maintainer.md) and the
  `PtcRunner.Kernel.*` module documentation
- [TraceLog contract](tracelog-contract.md)
- [Capability connectors](capability-connectors.md)

Where this document proposes a later extension, the existing contract wins for
current behavior.

## 2. Goals

The implementation must:

1. give host applications one way to identify a human, model run, or service;
2. resolve host policy into exact, bounded grants before an operation runs;
3. let different adapters call the same domain service with the same effective
   authorization;
4. keep model-visible capabilities explicit so compilation can record exact
   requirements and effects;
5. make source text, private transcripts, and promotion separately grantable;
6. preserve immutable run environments and immutable promoted prelude
   revisions;
7. make candidate updates concurrency-safe, attributable, and recoverable;
8. produce a common audit record without pretending that human UI actions are
   kernel run events; and
9. provide a clean dependency point for future HTTP, MCP, file, and database
   connector sources.

## 3. Non-goals

This plan does not introduce:

- arbitrary filesystem access;
- a generic capability that accepts a module name, URL, or resource operation;
- roles declared or selected by a model, Lisp program, bundle, or browser;
- mutation of the prelude or environment of a run already in progress;
- direct Viewer calls to kernel capabilities;
- storage of connector credentials in manifests, traces, or prelude source;
- simultaneous collaborative text editing;
- automatic promotion merely because a candidate compiles;
- a compatibility layer for the deleted evaluator-era `PreludeStore`,
  `PreludeCandidate`, or `PreludeRolePolicy`; or
- a requirement to finish prelude workspaces before a read-only connector can
  use the shared grant vocabulary.

## 4. Architecture

```text
host identity / session / run delegation
                  |
                  v
        HostAccess.Policy + grants
                  |
       +----------+-----------+
       |          |           |
       v          v           v
 TraceService  PreludeService Connector source
       |          |           |
  +----+----+  +--+---+   explicit capability
  |         |  |      |   projection + lease
Viewer   Lisp log  Viewer  Lisp prelude
adapter capability adapter capability
```

The domain service owns operation semantics. An adapter owns presentation and
transport. The policy layer knows neither HTTP nor Lisp.

This produces two intentionally parallel paths:

```text
model -> compiled explicit capability -> Dispatcher -> domain service
human -> authenticated Viewer request -> Viewer adapter -> domain service
```

Both paths pass an authorized, host-created request context. Neither path calls
the other.

## 5. Trust model and vocabulary

### 5.1 Principal

A principal identifies the actor for authorization and audit:

```elixir
defmodule PtcRunner.HostAccess.Principal do
  @enforce_keys [:kind, :id]
  defstruct [:kind, :id]

  @type kind :: :human | :model_run | :service
  @type t :: %__MODULE__{kind: kind(), id: binary()}
end
```

`id` is a stable host identifier of 1 to 256 UTF-8 bytes. It is not accepted
from Lisp input. For browser requests it comes from the authenticated host
session. For model calls it comes from the run owner and includes the run ID.

### 5.2 Resource reference

A resource reference is an exact installed resource, not a caller-controlled
path or URL:

```elixir
defmodule PtcRunner.HostAccess.ResourceRef do
  @enforce_keys [:kind, :id]
  defstruct [:kind, :id]

  @type kind ::
          :trace_source
          | :private_trace_source
          | :prelude_workspace
          | :connector_source

  @type t :: %__MODULE__{kind: kind(), id: binary()}
end
```

The installed-resource registry resolves the reference to host configuration.
The ID never resolves relative to a manifest directory and cannot contain a
filesystem traversal.

### 5.3 Action

Actions are a closed vocabulary. V1 of this plan defines:

| Resource | Action | Effect |
|---|---|---|
| trace source | `runs.list` | read |
| trace source | `run.read` | read |
| trace source | `turns.list` | read |
| trace source | `counters.read` | read |
| private trace source | `program_source.read` | sensitive read |
| private trace source | `prelude_source.read` | sensitive read |
| prelude workspace | `workspace.read` | read |
| prelude workspace | `source.read` | sensitive read |
| prelude workspace | `history.read` | read |
| prelude workspace | `candidate.read` | sensitive read |
| prelude workspace | `candidate.create` | write |
| prelude workspace | `candidate.update` | write |
| prelude workspace | `candidate.diff` | read |
| prelude workspace | `candidate.validate` | compute |
| prelude workspace | `candidate.compile` | compute |
| prelude workspace | `candidate.discard` | write |
| prelude workspace | `candidate.promote` | administrative |
| connector source | `capabilities.discover` | read |
| connector source | `capability.call` | connector-defined |

New actions require a schema, effect, bounds, audit behavior, and tests. Unknown
actions are rejected. The public capability name remains more specific than
the shared internal action; for example `prelude-candidate-update`, not
`resource-call` with an action string.

### 5.4 Bounds

```elixir
defmodule PtcRunner.HostAccess.Bounds do
  defstruct [
    :max_calls,
    :timeout_ms,
    :max_result_bytes,
    :max_source_bytes,
    :max_page_size
  ]
end
```

Every populated field is a positive integer. Resolution intersects bounds by
taking the lowest applicable value. A missing bound means “not constrained by
this layer”, not infinity; the service and Dispatcher still apply their own
installed ceilings. Callers may request lower bounds but cannot raise them.

### 5.5 Grant

```elixir
defmodule PtcRunner.HostAccess.Grant do
  @enforce_keys [:id, :resource, :actions, :bounds]
  defstruct [:id, :resource, :actions, :bounds, :expires_at]
end
```

- `id` is a host-issued audit identifier.
- `resource` is one exact `ResourceRef`.
- `actions` is a non-empty `MapSet` of the known action strings valid for that
  resource.
- `bounds` is a validated `Bounds` value.
- `expires_at` is `nil` or `:utc_datetime`.

V1 has no resource or action wildcards. A host role is configuration that
expands into exact grants; it is not itself a grant and is never serialized
into a manifest.

### 5.6 Request context and scoped grant

```elixir
defmodule PtcRunner.HostAccess.RequestContext do
  @enforce_keys [:principal, :grants, :correlation_id]
  defstruct [:principal, :grants, :correlation_id]
end

defmodule PtcRunner.HostAccess.ScopedGrant do
  @enforce_keys [
    :principal,
    :resource,
    :action,
    :bounds,
    :grant_ids,
    :correlation_id
  ]
  defstruct [
    :principal,
    :resource,
    :action,
    :bounds,
    :grant_ids,
    :correlation_id,
    :expires_at,
    :attestation
  ]
end
```

`RequestContext` is created by the host adapter. `Policy.authorize/4` validates
it for one resource and action and returns an opaque `ScopedGrant`. Domain
services accept only a scoped grant for that exact operation. Its attestation
is a host-only term and is never encoded as JSON or exposed to Lisp.

The initial implementation may keep authorization and service calls in the
same trusted application rather than use cryptographic signing. It must still
make the struct opaque outside `HostAccess` and verify the attestation on each
service entry point; accepting a caller-constructed struct is forbidden.

### 5.7 Audit record

```elixir
defmodule PtcRunner.HostAccess.AuditRecord do
  @enforce_keys [
    :timestamp,
    :principal,
    :resource,
    :action,
    :outcome,
    :correlation_id
  ]
  defstruct [
    :timestamp,
    :principal,
    :resource,
    :action,
    :outcome,
    :correlation_id,
    :grant_ids,
    :duration_ms,
    :metadata
  ]
end
```

`timestamp` is `:utc_datetime`; `duration_ms` is a non-negative integer.
Metadata contains bounded identifiers, hashes, sizes, and error codes, never
credential values or source text.

## 6. Authorization resolution

The effective model authority is the intersection of:

1. installed host policy for the principal and resource;
2. grants delegated to this run;
3. the manifest capability allowlist;
4. workflow or mission destination rules; and
5. installed and requested ceilings.

The effective human authority is the intersection of:

1. installed host policy for the authenticated principal;
2. grants attached to the authenticated session; and
3. operation-specific Viewer ceilings.

The following rules are normative:

- default is deny;
- roles are resolved by the host before `RequestContext` construction;
- a manifest may narrow model authority but cannot name a role or create a
  grant;
- the browser may request an operation but cannot provide a principal, grant,
  resource location, effect, or ceiling;
- expiration is checked both during authorization and at service entry;
- a resource identity is resolved once to an installed source instance, then
  pinned for the operation to prevent time-of-check/time-of-use substitution;
- all bounds are intersected before work starts;
- authorization denial is distinguishable from resource absence in internal
  audit, while public adapters may deliberately map both to `not_found` for
  sensitive resources; and
- no model gains private trace or prelude promotion authority merely because a
  human viewing the same run has it.

## 7. Common service result and error contract

Domain services return `{:ok, value}` or:

```elixir
{:error,
 %PtcRunner.HostAccess.ServiceError{
   code: code,
   message: bounded_message,
   details: json_value_or_nil,
   retryable: boolean
 }}
```

The initial closed codes are:

- `:access_denied`
- `:not_found`
- `:conflict`
- `:invalid_request`
- `:source_changed`
- `:limit_exceeded`
- `:timeout`
- `:unavailable`
- `:internal_error`

Adapters translate this value at their boundary:

- kernel capabilities translate it to the existing capability/provider error
  protocol;
- Viewer translates it to a stable JSON envelope and HTTP status;
- connector adapters retain connector-specific remote error details only when
  their schema allows it.

Exception text, stack traces, local paths, credentials, and arbitrary remote
response bodies do not cross either public boundary.

## 8. Trace service integration

`Kernel.TraceLog` remains the owner of canonical event validation, indexing,
pagination, and query behavior. The first shared-access slice wraps its source
selection and query entry points without duplicating query logic.

The service operations are:

| Operation | Required action |
|---|---|
| list runs | `runs.list` |
| fetch run summary | `run.read` |
| list turns with their canonical events | `turns.list` |
| fetch bounded counters | `counters.read` |
| fetch exact generated program source | `program_source.read` on private source |
| fetch exact prelude source | `prelude_source.read` on private source |

The final two operations cannot ship until private capture actually stores the
corresponding fields under an explicit private-capture policy. Their absence is
`not_found`, never an invitation to reconstruct source from sanitized events.

The existing local Viewer mode remains useful. At startup it creates a
host-owned, process-local principal and read-only scoped grants for the
configured public trace directory. Private sources require separate installed
configuration; a browser query parameter or path cannot enable them.

Human queries create host audit records. They do not append fake canonical
kernel events. Model capability calls continue to produce the canonical
capability-request/result events required by the TraceLog contract.

## 9. Prelude workspace model

A prelude workspace is a named host resource with one promoted head and zero or
more candidates. It is not a general filesystem directory.

### 9.1 Workspace

```elixir
%PreludeWorkspace{
  id: binary(),
  head_revision_id: binary() | nil,
  revision: non_neg_integer()
}
```

The workspace `revision` changes atomically whenever its head or candidate set
changes. It supports optimistic concurrency and is not a source version.

### 9.2 Promoted revision

```elixir
%PreludeRevision{
  id: binary(),
  workspace_id: binary(),
  parent_id: binary() | nil,
  source: binary(),
  source_hash: binary(),
  component_name: binary(),
  component_version: binary(),
  dependencies: [binary()],
  created_at: DateTime.t(),
  created_by: Principal.t()
}
```

Promoted revisions are immutable. `source_hash` uses the same canonical hashing
rules as compiled prelude components. `created_at` is stored with UTC timezone
semantics. A run receives a compiled frozen bundle derived from an exact
revision; moving the workspace head never changes an existing run.

### 9.3 Candidate

```elixir
%PreludeCandidate{
  id: binary(),
  workspace_id: binary(),
  base_revision_id: binary() | nil,
  revision: pos_integer(),
  source: binary(),
  source_hash: binary(),
  status: :draft | :validated | :compiled,
  validation: map() | nil,
  created_at: DateTime.t(),
  created_by: Principal.t(),
  updated_at: DateTime.t(),
  updated_by: Principal.t()
}
```

Candidate IDs are host generated. Candidate `revision` begins at 1 and is
incremented by each successful update. Updating source resets status to
`:draft` and clears prior validation or compile results.

## 10. Prelude repository and service

Storage is split from operation semantics:

```elixir
defmodule PtcRunner.PreludeWorkspace.Repository do
  @callback get_workspace(binary()) :: {:ok, PreludeWorkspace.t()} | repo_error
  @callback get_revision(binary(), binary()) ::
              {:ok, PreludeRevision.t()} | repo_error
  @callback list_revisions(binary(), map()) :: {:ok, page()} | repo_error
  @callback get_candidate(binary(), binary()) ::
              {:ok, PreludeCandidate.t()} | repo_error
  @callback transact(binary(), (state() -> transaction_result())) ::
              transaction_result()
end
```

The first implementation should provide an in-memory repository for contract
tests and one durable host-selected adapter. A filesystem adapter, if chosen,
maps validated workspace IDs to configured roots and uses atomic replace; it
never accepts paths from a principal or manifest. A database adapter performs
the same state changes in one transaction.

Owner-process repositories mutate state through one atomic operation. A
separate `Agent.get/2` followed by `Agent.update/2` is forbidden.

`PreludeService` owns schemas, authorization checks, hashing, concurrency,
compiler invocation, and audit emission. Repositories do not decide access.

## 11. Prelude operations

Every operation accepts a verified `ScopedGrant` plus validated arguments.
Responses are JSON-safe at adapter boundaries.

### 11.1 Read workspace metadata

Input:

```elixir
%{}
```

Returns workspace metadata and promoted-head metadata without source text.

### 11.2 Read promoted source

Input selects the current head or an exact promoted revision ID. The response
contains revision metadata, source, and source hash and is capped by
`max_source_bytes`. This requires `source.read`; `workspace.read` alone does not
reveal source. Private trace prelude source remains a different resource and
grant because it records what an earlier run actually received, which may not
match the workspace's current head.

### 11.3 Read history

Input:

```elixir
%{cursor: binary() | nil, limit: pos_integer()}
```

Returns immutable revision metadata in newest-first order. Limit is capped by
`max_page_size`. Cursors are opaque, source-scoped, and reject reuse against a
different workspace.

### 11.4 Read candidate

Input selects an exact candidate ID. The response contains candidate metadata
and, when requested, its bounded source. It requires `candidate.read`; history
or workspace access does not imply access to unpromoted source. A closed or
discarded candidate is visible only when installed retention policy and the
grant both allow it.

### 11.5 Create candidate

Input:

```elixir
%{
  base_revision_id: binary() | nil,
  source: binary(),
  idempotency_key: binary()
}
```

The base must be the current head unless installed policy explicitly permits a
historical branch. Source must be UTF-8, within `max_source_bytes`, and pass the
same reader-level safety limits as normal prelude compilation. Reusing an
idempotency key with identical normalized input returns the original candidate;
reusing it with different input returns `conflict`.

### 11.6 Update candidate

Input:

```elixir
%{
  candidate_id: binary(),
  expected_revision: pos_integer(),
  source: binary(),
  idempotency_key: binary()
}
```

V1 replaces the complete source. The repository compares
`expected_revision` and writes in one atomic operation. A stale revision
returns `conflict` with current candidate metadata but not its source unless
the caller also holds `candidate.read`.

### 11.7 Diff candidate

Input selects the candidate and either its base or a specific promoted
revision. Output is a bounded structured line diff plus old/new hashes. Diff
generation is charged against operation timeout and result-size ceilings.

### 11.8 Validate candidate

Validation performs, in order:

1. reader parsing and source-limit checks;
2. component header and dependency schema validation;
3. compilation through the canonical prelude compiler;
4. source-span-preserving error collection;
5. capability requirement extraction; and
6. installed-policy checks for forbidden dependencies.

The result records the candidate revision and source hash. Diagnostics are
bounded structured values containing phase, code, message, line, column, and
optional form index. A candidate changed during validation remains draft; the
stale result is returned as `source_changed` and is not stored.

### 11.9 Compile candidate

Compile repeats or verifies validation against the exact candidate revision,
then creates an internal frozen component artifact. The artifact is cacheable
by source hash but does not become a workspace revision and is not installed
into a running environment. Compiler crashes are classified as
`internal_error`; user source failures are `invalid_request` with diagnostics.

### 11.10 Discard candidate

Discard requires candidate ID and expected revision and is atomic. It removes
the candidate from the active set while retaining the bounded audit record.
Whether discarded source is retained is an installed retention policy, never a
client option.

### 11.11 Promote candidate

Input:

```elixir
%{
  candidate_id: binary(),
  expected_candidate_revision: pos_integer(),
  expected_workspace_head: binary() | nil,
  idempotency_key: binary()
}
```

Promotion requires a compiled result for the exact candidate revision and
source hash. One repository transaction:

1. verifies candidate revision and workspace head;
2. creates an immutable promoted revision;
3. advances the head;
4. closes the candidate; and
5. records the idempotency result.

No filesystem write, bundle mutation, or environment rebuild may occur between
the compare and state change. Materializing compiled caches may happen after
commit because the source revision is already authoritative and immutable.

`candidate.promote` is intentionally separate from create, update, validate,
and compile. Default model roles should not contain it.

## 12. Explicit capability projection

The model-facing surface is a set of normal kernel capabilities:

- `prelude-workspace-get`
- `prelude-source-get`
- `prelude-history`
- `prelude-candidate-get`
- `prelude-candidate-create`
- `prelude-candidate-update`
- `prelude-candidate-diff`
- `prelude-candidate-validate`
- `prelude-candidate-compile`
- `prelude-candidate-discard`
- `prelude-candidate-promote`

Each capability has its own argument/result schema and declared effect. The
compiler therefore records `tool:prelude-candidate-update`, not a generic tool
plus a runtime action string. `prelude.core` may offer ergonomic Lisp wrappers,
but wrappers cannot broaden the underlying environment.

The proposed wrapper names are `get-workspace`, `get-source`, `history`,
`get-candidate`, `create-candidate`, `update-candidate`, `diff-candidate`,
`validate-candidate`, `compile-candidate`, `discard-candidate`, and
`promote-candidate`. Arguments and returned domain maps use JSON string keys at
the Lisp boundary, matching existing Kernel capabilities.

The environment builder receives already resolved grants and installs only the
capabilities permitted for that run and destination. Dispatcher quotas,
timeouts, terminal-state checks, late-result rejection, and result-size checks
still apply. A scoped grant narrows authority; it does not replace execution
confinement.

## 13. Viewer adapter

The Viewer gains an authenticated host mode in addition to its current local
read-only trace mode. Authentication and session creation belong to the host
application. The Viewer receives an opaque session reference and asks the host
adapter for a `RequestContext`; it never accepts grants from request JSON.

Proposed routes are:

```text
GET    /api/kernel/runs
GET    /api/kernel/runs/:run_id
GET    /api/kernel/runs/:run_id/turns
GET    /api/kernel/counters
GET    /api/kernel/runs/:run_id/program-source
GET    /api/kernel/runs/:run_id/prelude-source

GET    /api/prelude-workspaces/:workspace_id
GET    /api/prelude-workspaces/:workspace_id/source
GET    /api/prelude-workspaces/:workspace_id/history
POST   /api/prelude-workspaces/:workspace_id/candidates
GET    /api/prelude-workspaces/:workspace_id/candidates/:candidate_id
PUT    /api/prelude-workspaces/:workspace_id/candidates/:candidate_id
GET    /api/prelude-workspaces/:workspace_id/candidates/:candidate_id/diff
POST   /api/prelude-workspaces/:workspace_id/candidates/:candidate_id/validate
POST   /api/prelude-workspaces/:workspace_id/candidates/:candidate_id/compile
DELETE /api/prelude-workspaces/:workspace_id/candidates/:candidate_id
POST   /api/prelude-workspaces/:workspace_id/candidates/:candidate_id/promote
```

The host adapter maps each route to one exact resource and action. CSRF
protection is required for cookie-authenticated mutations. Source responses use
`text/plain; charset=utf-8` or a JSON object with explicit size metadata and
must disable content sniffing. The editor must display candidate revision,
base/head hashes, validation status, and conflicts; it must never silently
overwrite a stale candidate.

Private program/prelude source views show a persistent sensitive-data notice.
The existing sanitized transcript view remains the default.

## 14. Connector integration

The connector plan consumes, rather than redefines, the following pieces:

- `Principal`
- `ResourceRef` with kind `:connector_source`
- resolved `Grant` and `Bounds`
- `RequestContext`/`ScopedGrant`
- audit correlation and common service errors

Connector-specific code still owns discovery, transport, credentials,
sessions, snapshots, leases, remote schemas, and effect metadata. A connector
grant selects an installed source and allowed remote capabilities; it does not
grant trace or prelude access.

An HTTP or MCP server that exposes file or database operations remains an
installed connector source. The manifest can select from host-approved
capabilities but cannot provide endpoints, paths, DSNs, or credentials. The
connector plan may implement read-only sources after the shared H0 contract; it
does not need to wait for writable prelude slices.

## 15. Audit and observability

All service attempts emit one bounded host audit record after authorization,
including denials. The audit sink is append-only from the caller’s perspective.
It must tolerate sink failure without granting access; installed policy decides
whether an unavailable mandatory audit sink fails closed.

Audit metadata includes only what is needed to investigate behavior:

- resource and operation;
- run ID, Viewer request ID, or connector call ID as correlation;
- candidate/revision/run identifiers;
- source and result hashes and byte counts;
- outcome/error code;
- duration; and
- effective ceiling identifiers or grant IDs.

It excludes source text, transcript content, prompts, results, credentials, and
session tokens. Human audit records may be displayed by a separate admin view,
but are not injected into the kernel’s canonical run trace.

## 16. Concurrency, lifecycle, and idempotency

The implementation must satisfy these invariants:

- authorization and installed-resource resolution finish before work starts;
- the installed resource instance is pinned for the operation;
- grant expiry is rechecked at service entry;
- all owner-process state changes are one atomic operation;
- candidate update, discard, and promotion use optimistic concurrency;
- promotion compares candidate revision and workspace head in the same
  transaction that creates the revision;
- idempotency records are resource-scoped and input-hash-bound;
- timed-out or canceled compiler/connector work cannot commit a late result;
- opened source handles, compiler tasks, sessions, and leases are cleaned up on
  success, error, caller death, and timeout; and
- terminal run state prevents new model capability work exactly as in the
  kernel contract.

Tests use monitors and synchronization helpers, never `Process.sleep/1`.

## 17. Security and privacy requirements

1. Exact generated programs and prelude source are sensitive even when the
   sanitized event trace is public.
2. Private trace reads use a distinct installed resource and grant.
3. Candidate write does not imply promoted-source read or promotion.
4. Candidate and promoted source reads require separate explicit actions.
5. Promotion does not imply access to connector credentials or trace sources.
6. Source text is parsed as data; it cannot select Elixir modules or call host
   functions outside compiled capabilities.
7. Filesystem repositories confine canonicalized paths beneath an installed
   root and reject symlink escape.
8. Database repositories use parameterized operations and installed DSNs.
9. Connector credentials stay inside connector instances and are redacted from
   every error and audit record.
10. Model grants are fixed for a run. A later human role change affects a later
   run, not its frozen environment.
11. Retention and deletion policies are host configuration, with separate
    treatment for sensitive source and ordinary audit metadata.

## 18. Configuration boundary

Host applications configure:

- installed resource IDs and adapters;
- role-to-exact-grant expansion;
- human-to-role/session assignments;
- model-run delegation templates;
- per-action bounds and retention;
- whether promotion requires a human principal; and
- audit sink and fail-open/fail-closed policy.

Manifests configure only a requested subset of model-visible explicit
capabilities and connector source aliases already offered by the host. They do
not configure roles, Viewer sessions, storage roots, endpoints, credentials, or
promotion policy.

Configuration parsing validates the complete installed registry at startup.
Duplicate IDs, unknown actions, invalid action/resource pairs, missing bounds,
or unavailable mandatory adapters fail startup with stable errors.

## 19. Proposed module layout

Each module lives in its own file.

```text
lib/ptc_runner/host_access/
  principal.ex
  resource_ref.ex
  bounds.ex
  grant.ex
  request_context.ex
  scoped_grant.ex
  policy.ex
  service_error.ex
  audit_record.ex
  audit_sink.ex

lib/ptc_runner/host_resources/
  trace_service.ex

lib/ptc_runner/prelude_workspace/
  workspace.ex
  revision.ex
  candidate.ex
  repository.ex
  memory_repository.ex
  service.ex

lib/ptc_runner/kernel/
  prelude_capability.ex

priv/preludes/kernel/
  prelude.core.lisp
```

Durable repositories and authenticated Viewer integration may live in the host
application or sibling project when they require dependencies inappropriate
for the core library. Their behavior must still pass the shared contracts.

## 20. Implementation slices and exit gates

### H0: host-access contract

Implement and document the exact structs, action registry, validation, bound
intersection, policy resolution, scoped-grant attestation, common errors, and
audit sink behavior.

Exit gate:

- forged principals/grants/scoped grants are rejected at public boundaries;
- unknown action/resource pairs fail validation;
- all intersections can only reduce authority and bounds;
- expiry and exact-resource matching have contract tests;
- audit redaction and mandatory-sink failure behavior are tested; and
- no Kernel, TraceLog, or Viewer behavior changes yet.

### H1: TraceLog proof of sharing

Add `TraceService`, adapt `TraceCapability` and the Viewer adapter to call it,
and preserve existing public query schemas and canonical events.

Exit gate:

- existing TraceLog, capability, CLI, and Viewer suites pass unchanged where
  behavior is unchanged;
- model and human adapters return equivalent domain results for equivalent
  grants;
- human reads produce audit records but no canonical kernel events;
- local read-only Viewer startup grants cannot access private sources; and
- source selection remains host-controlled and traversal-safe.

### H2: private source capture and viewing

Define private event/storage fields for exact generated program and prelude
source, capture them only under installed private policy, and expose the two
explicit read operations.

Exit gate:

- public/sanitized sources contain neither exact source nor recoverable private
  fields;
- each private source operation requires its own action;
- absent or expired private grants fail without leaking existence;
- Viewer shows a persistent sensitivity warning; and
- result size, pagination, retention, and audit behavior are tested.

### P0: immutable prelude repository and reads

Implement workspace/revision types, repository contract, memory repository,
one durable adapter decision, read/history service operations, and hashing.

Exit gate:

- immutable revisions cannot be changed through any repository operation;
- cursors are source-scoped and bounded;
- repository state transitions are atomic;
- source size and UTF-8 validation match compiler expectations; and
- a compiled frozen environment from a revision remains unchanged after the
  workspace head moves.

### P1: candidate authoring

Implement create, full-source update, diff, discard, optimistic concurrency,
idempotency, and retention policy.

Exit gate:

- stale updates and discards return structured conflicts;
- concurrent updates yield exactly one winner per expected revision;
- idempotency keys cannot be rebound to different input;
- write grants do not imply read or promote grants; and
- all state and audit records name the acting principal.

### P2: validation and compilation

Connect candidate validation/compile to the canonical prelude compiler and
return bounded source-located diagnostics and capability requirements.

Exit gate:

- compiler behavior matches normal prelude compilation;
- changed candidates cannot receive stale validation/compile status;
- timeout/cancellation cannot store a late result;
- component dependencies compile in canonical order; and
- user errors, limits, timeouts, and internal errors remain distinct.

### P3: promotion

Implement the atomic candidate-to-revision transition and frozen bundle
materialization.

Exit gate:

- candidate revision and workspace head are compared in the promotion
  transaction;
- repeated identical promotion is idempotent;
- stale or uncompiled candidates cannot promote;
- a promoted revision is immutable and reproducibly compiles by hash; and
- default model policy lacks promotion.

### P4: model capability and `prelude.core`

Project authorized service operations as explicit capabilities and add
ergonomic prelude wrappers.

Exit gate:

- compiler requirements name each exact tool;
- effect metadata is correct for every operation;
- workflow/mission destination and run-time ceilings are enforced;
- late provider results and terminal runs cannot mutate candidates; and
- capability events and host audit records correlate without duplicating
  private content.

### V1: authenticated Viewer workspace UI

Add authenticated request-context resolution, source/history views, candidate
editor, structured diagnostics, diff, conflicts, and separately authorized
promotion.

Exit gate:

- browser-supplied identity, grants, paths, and ceilings are ignored/rejected;
- mutation routes have authentication and CSRF coverage;
- stale candidates are never overwritten silently;
- private and promoted source displays are visibly classified; and
- browser tests cover read-only, author, reviewer/promoter, denial, conflict,
  and expired-session flows with zero console errors.

### C0+: connector adoption

Update [the connector plan](capability-connectors.md) to consume H0 types and
policy resolution while retaining connector-specific snapshots and leases.
H1 through V1 are not prerequisites for a read-only connector.

Exit gate:

- connector manifests cannot create principals or grants;
- installed source identity remains host-controlled;
- snapshot and lease behavior remain connector-owned; and
- common authorization/audit tests run against at least one local connector.

## 21. Required test matrix

The full implementation needs contract tests across these axes:

| Axis | Required cases |
|---|---|
| principal | human, model run, service, forged, expired session |
| resource | public trace, private trace, workspace, connector, wrong kind/ID |
| authorization | absent, exact, narrowed, expired, wrong action, lower requested bound |
| adapter | Lisp capability, Viewer HTTP, direct host service |
| operation | read, sensitive read, write, compute, administrative |
| lifecycle | success, validation error, timeout, cancellation, caller death, service crash |
| concurrency | competing update, stale validate, competing promote, idempotent retry |
| privacy | sanitized trace, private source, redacted error/audit, result limit |
| storage | memory and selected durable adapter |

At least one integration test must prove that a human and model with equivalent
effective read grants receive the same domain value while producing the
appropriate adapter-specific envelope and observability. At least one test
must prove that equivalent write grants do not bypass optimistic concurrency.

## 22. Definition of done

This plan is implemented only when:

- H0 through P4 pass `mix precommit` and `mix prepush`;
- V1 passes the Viewer suite and a real-browser visual/interaction pass;
- the selected durable repository survives restart and passes the repository
  contract;
- the kernel tutorial contains a runnable model-authoring example;
- the Viewer documentation contains a runnable human inspection/edit example;
- generated programs and source preludes are visible only with the required
  private grants;
- a promoted prelude is used only by later explicitly rebuilt environments;
- the connector plan uses the same grant/bounds/audit vocabulary; and
- no evaluator-era prelude store, mutable active environment, generic
  resource-call capability, or compatibility shim has been restored.

## 23. Decisions required before H0

The implementer must record these decisions in this document before code:

1. whether scoped-grant attestation is process-owned opaque state or an
   application-secret MAC;
2. the first durable prelude repository (filesystem or database);
3. whether mandatory audit-sink failure fails all writes or all operations;
4. the exact private-capture event/storage schema for program and prelude
   source;
5. whether model promotion is globally prohibited initially or merely absent
   from default policy; and
6. which host application supplies authenticated Viewer sessions.

None of these decisions changes the separation between shared access policy
and domain services.

## Appendix

Everything in this appendix is illustrative future-facing usage. Names and
configuration syntax are proposed and must be finalized by the relevant slice
before being presented as stable CLI/API behavior.

### Appendix A: human inspection and candidate review

A host administrator installs exact resources and expands roles into grants:

```elixir
config :ptc_runner, :host_resources,
  resources: [
    %{id: "prod-traces", kind: :trace_source, adapter: MyTraceSource},
    %{id: "prod-private", kind: :private_trace_source, adapter: MyPrivateTraceSource},
    %{id: "agent-prelude", kind: :prelude_workspace, adapter: MyPreludeRepository}
  ],
  roles: %{
    "trace-reviewer" => [
      {"prod-traces", ["runs.list", "run.read", "turns.list", "counters.read"]}
    ],
    "prelude-author" => [
      {"agent-prelude",
       ["workspace.read", "source.read", "history.read", "candidate.read",
        "candidate.create", "candidate.update", "candidate.diff",
        "candidate.validate", "candidate.compile"]}
    ],
    "prelude-promoter" => [
      {"agent-prelude",
       ["workspace.read", "candidate.read", "candidate.diff",
        "candidate.promote"]}
    ]
  }
```

Alice opens `ptc_viewer`. Her authenticated session expands
`trace-reviewer + prelude-author`; the Viewer does not receive the role names
from the browser. She can inspect a sanitized DeepSeek run, open the current
`agent-prelude`, create a candidate, edit it, and compile it. The UI shows:

```text
Candidate cand-01, revision 3
Base: prelude-r17 (sha256:...)
Status: compiled
Requirements: tool:file-read, tool:file-write
Promotion: not permitted for this session
```

Bob holds `prelude-promoter`. He can inspect the candidate diff and promote the
exact compiled candidate revision. If Alice edits after Bob opens the page,
promotion returns a conflict instead of promoting unreviewed source.

### Appendix B: model reads logs and proposes a prelude change

The host delegates one run read-only trace access plus prelude author access,
but no promotion. Its frozen environment contains explicit tools and wrappers:

```clojure
(require '[log.core :as log]
         '[prelude.core :as prelude])

(let [runs      (log/runs {"limit" 5})
      failed    (first (filter #(= "error" (get % "status"))
                               (get runs "items")))
      turns     (log/turns (get failed "run_id") {"limit" 100})
      workspace (prelude/get-workspace {})
      base       (prelude/get-source
                   {"revision_id" (get-in workspace ["head" "id"])})
      improved  (derive-safer-source (get base "source") turns)
      candidate (prelude/create-candidate
                  {"base_revision_id" (get-in workspace ["head" "id"])
                   "source" improved
                   "idempotency_key" "fix-from-run-42"})
      checked   (prelude/validate-candidate
                  {"candidate_id" (get candidate "candidate_id")})]
  {"failed_run" (get failed "run_id")
   "candidate" (get candidate "candidate_id")
   "validation" checked
   "next_step" "Human review and promotion required"})
```

The model receives ordinary JSON-safe values: bounded run summaries, canonical
events, candidate metadata, and structured compiler diagnostics. It does not
receive connector credentials, private prompts, exact model responses, or a
promotion tool. The human receives a candidate link and can see which run and
grant IDs caused it in audit metadata.

### Appendix C: inspecting exact generated source

A sanitized trace may show that a kernel evaluation failed without revealing
the exact generated program. A separately authorized reviewer can open
“Generated program” in the run view. The Viewer calls
`program_source.read` against `prod-private`; a `turns.list` grant against
`prod-traces` is insufficient.

The same distinction applies to a model. Giving it `log/turns` does not expose
exact programs. The host must deliberately install a private-source capability
for that run; most production model roles should omit it.

### Appendix D: connector and prelude workspace together

Suppose the host installs a read-only PostgreSQL connector and a writable
prelude workspace. The model can inspect schema metadata and propose a helper
without receiving a DSN:

```clojure
(require '[db.core :as db]
         '[prelude.core :as prelude])

(let [schema    (db/describe-table {"table" "orders"})
      workspace (prelude/get-workspace {})
      base      (prelude/get-source
                  {"revision_id" (get-in workspace ["head" "id"])})
      source    (add-order-summary-helper (get base "source") schema)
      candidate (prelude/create-candidate
                  {"base_revision_id" (get-in workspace ["head" "id"])
                   "source" source
                   "idempotency_key" "orders-summary-v1"})]
  (prelude/compile-candidate
    {"candidate_id" (get candidate "candidate_id")}))
```

The database call is governed by connector snapshot, lease, remote schema, and
connector bounds. The prelude calls are governed by workspace revisions and
optimistic concurrency. They share principal, grant intersection, correlation,
and audit conventions only.

### Appendix E: possible CLI workflow

A future authenticated CLI could use the same host adapter as Viewer:

```text
$ mix ptc.prelude show agent-prelude
$ mix ptc.prelude candidate create agent-prelude --from head --file helper.lisp
$ mix ptc.prelude candidate validate agent-prelude cand-01
$ mix ptc.prelude candidate diff agent-prelude cand-01
$ mix ptc.prelude candidate promote agent-prelude cand-01 --expected-head prelude-r17
```

The CLI must resolve identity from host authentication and must not accept raw
grant JSON. Non-interactive promotion should require an explicit installed
policy and preserve the same optimistic-concurrency fields as HTTP.

### Appendix F: deferred future ideas

These are intentionally outside the implementation slices above:

- structured edit operations or patches after full-source replacement is
  proven reliable;
- candidate branches, merge bases, three-way merge, and multiple reviewers;
- signed promoted revisions and reproducible bundle attestations;
- Git-backed import/export while retaining the workspace service as authority;
- approval policies such as two-person promotion or required test suites;
- semantic search over sanitized traces with separately authorized retrieval;
- automatic evaluation of candidates against replay fixtures before promotion;
- policy-controlled model promotion in isolated development workspaces;
- dependency impact graphs showing which manifests use a revision;
- notifications when a promoted revision produces new failures;
- retention tiers and legal holds for private source and audit metadata;
- external policy engines behind the same exact-grant resolver;
- collaborative editor transports that still commit through candidate revision
  checks; and
- MCP resources/prompts projected as typed, explicit capabilities in addition
  to MCP tools, once their authority and snapshot semantics are specified.

Each future idea must preserve immutable running environments, exact resource
grants, explicit capability names, and service-owned operation semantics.
