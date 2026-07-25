# MCP-first capability platform — implementation plan

> **Status:** active implementation plan, promoted from `future/` on
> 2026-07-24. Every API below remains planned unless explicitly described as
> current behavior. The protocol target is the locked `2026-07-28` release
> candidate reviewed on 2026-07-23. Implementation may target that candidate
> before final publication; reconcile any final specification or stable-SDK
> deltas as an ordinary follow-up rather than blocking the first slices.

## 1. Outcome

PtcRunner should use MCP as its general external capability protocol. A host
installs an MCP server and freezes which of its tools may become PtcRunner
capabilities. A manifest selects and narrows those installed capabilities.
PTC-Lisp preludes compose them into application behavior. Generated programs
only execute what they were granted.

The first platform target is intentionally small:

- one general external-integration source, `mcp`;
- two standard MCP transports, `stdio` and `streamable_http`;
- tools as the first model-callable MCP primitive;
- strict host-owned tool mappings, effects, credentials, and ceilings;
- modern stateless MCP `2026-07-28`, without a legacy compatibility layer;
- no host-configurable `file-read` source or second generic filesystem API;
- a non-production read-only filesystem sample server; and
- generic `mix ptc.run`, not task-specific Mix commands.

A raw HTTP/OpenAPI provider is deferred. HTTP remains relevant only as the
standard MCP Streamable HTTP transport. If direct HTTP later proves necessary,
it should get a separate plan based on demonstrated applications rather than
shape the first capability platform.

The central authoring test is:

> After PtcRunner implements MCP once, can an application author connect a new
> filesystem, Git, issue tracker, database, or test server through host JSON,
> a manifest, and PTC-Lisp without changing Elixir?

## 2. Evidence from the current repository

The current implementation already establishes useful boundaries:

| Current surface | Verified behavior | Consequence |
| --- | --- | --- |
| `PtcRunner.Kernel.Capability` | Validates a name (dots allowed), host-declared effect, bounded schemas, visibility, and a callback that returns `ProviderError` values on failure | MCP tools should become ordinary capabilities; the Kernel should not learn MCP tool semantics |
| `PtcRunner.Kernel.ProviderRegistry` | Accepts trusted builders and normalizes `{capabilities, snapshot, close}` | Host JSON should decode into existing builders, not create another provider framework |
| `PtcRunner.Kernel.MCPSource` | Implements read-only Streamable HTTP for MCP `2025-11-25`; installation requires Elixir | The adapter exists, but its session protocol and installation channel must change |
| `PtcRunner.Kernel.MCPLease` | Owns a protocol session, request IDs, expiry, active requests, and session DELETE | Most of this disappears when protocol sessions disappear |
| `PtcRunner.Kernel.FileCapability` | Freezes configured files and reads one already-known whole UTF-8 path | Keep only until the MCP filesystem replacement passes acceptance, then delete the public provider instead of extending it |
| `PtcRunner.Kernel.JSONSchema` | Compiles a bounded 2020-12 subset and currently requires object roots for inputs and outputs | Input and output compilation need distinct root rules; full remote schemas must not bypass the bounded callable profile |
| `mix ptc.run` | Uses the default registry and has no host-config option | A generic trusted installation channel is the missing CLI capability |
| Private inspection | Captures exact provider-neutral LLM and capability activity in a separate bounded artifact | MCP-specific wire evidence can extend the private plane without entering canonical traces |

No new top-level runtime or task abstraction is needed. The missing work is a
modern MCP client, stdio ownership, and data-driven installation.

## 3. Decisions

### 3.1 Preserve the authority ladder

| Layer | Verb | MCP responsibility |
| --- | --- | --- |
| Host config or Elixir builder | installs | transport, executable or endpoint, credentials, upstream tool allowlist, public names, effects, data classes, ceilings |
| Manifest | selects and narrows | installed provider name, subset of public names, model visibility, lower time/result limits |
| Prelude | composes | clean functions, pagination, retries, response shaping, task policy |
| Generated program | executes | calls granted functions and capabilities |

The manifest must never introduce a command, argument that expands server
authority, endpoint, credential, upstream tool, effect, or extension. Tool
annotations and descriptions are remote metadata, not authority. Even for a
server controlled by this project, effects remain host-declared so the same
client remains safe with third-party servers.

### 3.2 One MCP source, transport as a typed field

Do not create public `mcp_stdio` and `mcp_http` source kinds. They speak the
same protocol and produce the same capabilities; only framing, request
metadata, cancellation, and process ownership differ.

Planned stdio installation:

```json
{
  "install": {
    "workspace": {
      "source": "mcp",
      "transport": {
        "type": "stdio",
        "command": "node",
        "cwd": ".",
        "args": [
          "examples/mcp/filesystem/dist/server.js",
          "--root",
          ".",
          "--include",
          "lib/**",
          "--include",
          "priv/**",
          "--include",
          "docs/**"
        ]
      },
      "tools": {
        "list_directory": {
          "as": "workspace.list",
          "effect": "read"
        },
        "search_text": {
          "as": "workspace.search",
          "effect": "read"
        },
        "read_text_file": {
          "as": "workspace.read",
          "effect": "read"
        },
        "snapshot_info": {
          "as": "workspace.info",
          "effect": "read"
        }
      },
      "snapshot_identity": {
        "tool": "snapshot_info",
        "field": "snapshot_hash"
      },
      "ceilings": {
        "timeout_ms": 5000,
        "max_catalog_tools": 32,
        "max_result_bytes": 250000
      }
    }
  }
}
```

Planned remote installation uses the same outer grammar:

```json
{
  "$schema": "./priv/schemas/ptc-host-config.schema.json",
  "credentials": {
    "issues_token": {"env": "ISSUES_TOKEN"}
  },
  "install": {
    "issues": {
      "source": "mcp",
      "transport": {
        "type": "streamable_http",
        "endpoint": "https://mcp.example.org/mcp",
        "auth": [{"scheme": "bearer", "binding": "issues_token"}]
      },
      "tools": {
        "search_issues": {
          "as": "issues.search",
          "effect": "read"
        }
      },
      "ceilings": {
        "timeout_ms": 5000,
        "max_result_bytes": 250000
      }
    }
  }
}
```

Strict transport decoders reject inapplicable fields. Stdio does not accept
HTTP headers; Streamable HTTP does not accept a command or subprocess
environment. `source: "mcp"` is the application concept. Transport modules are
internal adapters.

### 3.3 Replace public `file-read`, not trusted artifact loading

The target host grammar has no `source: "file-read"`. Model-accessible
navigation, discovery, search, and ranged reads come from a host-installed MCP
server. Do not make the current provider host-configurable and do not grow it
into a parallel filesystem API.

This does not route PtcRunner's own trusted loading through MCP. The runner
continues to open host config, manifests, PTC-Lisp components, schemas, input
artifacts, and other explicitly selected platform files through their
dedicated confined loaders. Those files establish a run; they are not ambient
filesystem capabilities granted to generated code.

The filesystem server may advertise an upstream tool named
`read_text_file`. That is an MCP tool selected and renamed by the host, not the
legacy PtcRunner source kind. The distinction keeps bootstrap simple while
leaving one extensible boundary for agent-visible filesystem access.

Removal is one breaking cutover: first make the sample MCP server pass
filesystem acceptance, then migrate current examples and tests and delete the
`file-read` builder, manifest config, and capability implementation in the
same release. Do not publish a target state in which both public filesystem
paths remain supported.

### 3.4 Target modern stateless MCP only

The first config-driven source should implement MCP `2026-07-28` and reject
legacy servers. PtcRunner is a 0.x library and the controlled sample server
will use the same version, so an `initialize` fallback would preserve the
largest obsolete lifecycle solely for compatibility.

Every request must:

1. include protocol version, client identity, and client capabilities in
   `_meta`;
2. use a new JSON-RPC request ID;
3. validate exactly one correlated response or bounded request-scoped stream;
4. classify `resultType` before interpreting the result; and
5. remain bounded by one end-to-end deadline and byte ceiling.

The client should call `server/discover` before `tools/list`. Discovery verifies
the selected version and records supported server capabilities. It is not a
security identity: server name, instructions, descriptions, icons, and
annotations are untrusted metadata. In particular, `server/discover`
instructions must not be appended to PtcRunner's system prompt.

For Streamable HTTP, every POST additionally carries the protocol,
`Mcp-Method`, and applicable `Mcp-Name` headers, and validates response status,
content type, body/header agreement, origin policy, redirects, and size while
streaming. The client must retain valid `x-mcp-header` annotations and mirror
the designated primitive argument values using the specification's exact
header-name, type-conversion, and Base64-sentinel rules. Invalid annotations
exclude that tool from the usable catalog; if the host mapped it, assembly
fails as a missing mapped tool. Stdio may ignore these HTTP-only annotations.
Silently dropping valid annotations in Streamable HTTP, as the current generic
`x-*` schema filtering would do, is non-conforming.

Transport metadata extraction happens before the bounded callable-schema
normalizer removes non-validation annotations. The normalized header paths and
names are frozen beside the compiled validator and used by the call path; the
same semantics are included in the provider snapshot hash.

The protocol has no `Mcp-Session-Id`, session expiry, sticky routing, or
session DELETE. For Streamable HTTP, immutable request configuration plus the
Kernel's existing bounded provider worker may be sufficient; retain a
dedicated owner only where it owns a real resource.

### 3.5 Stdio owns an OS process, not a protocol session

Stdio still needs a resource owner because PtcRunner launches a subprocess.
V1 supports macOS and Linux. Windows process ownership is deferred until there
is an equally strong Job Object design.

Slice 0 selects the launcher boundary; it does not add a native subsystem to
the core library. The `ptc_runner` Hex package remains native-free and declares
`ptc_runner_launcher` only as an optional dependency. Stdio normally uses that
companion package's versioned launcher. The companion publishes checksummed
precompiled port executables for supported macOS and Linux targets through
`elixir_make` and `cc_precompiler`, so supported users do not need a C
toolchain. Source compilation remains an explicit fallback for maintainers and
unsupported targets, not the normal installation path. A standalone
distribution or container bundles the same companion artifact.

The source tree keeps a test-only POSIX reference proof. It is compiled only
by the focused macOS/Linux proof tests and is not packaged as application code.
The proof demonstrates:

- a new child environment built from the versioned MCP compatibility allowlist
  plus explicit host bindings rather than Erlang Port environment extension;
- canonical executable and working-directory handling without shell command
  construction;
- a new process group with stdin, stdout, and bounded stderr wired separately;
  and
- EOF followed by bounded TERM-to-KILL escalation for the launched process
  group. Host-installed MCP servers are trusted not to escape that group with
  `setpgid` or `setsid`; V1 is not a hostile-code sandbox.

The mechanism comparison is:

| Mechanism | Decision |
| --- | --- |
| Erlang `Port` alone | Reject: explicit argv is available, but environment options overlay the ambient environment and stderr cannot be consumed as a separate bounded stream without another process boundary |
| Shell wrapper plus observed PID | Reject: shell parsing and a PID observation do not provide the required authority or containment |
| `MuonTrap` | Reject for this boundary: strong supervision is useful, but its documented interface is not intended for interactive full-duplex subprocesses |
| `ExCmd` | Reject as the complete boundary: its precompiled middleware proves the distribution model, and demand-driven I/O is attractive, but its public contract cannot expose stderr as a separate consumable bounded stream and does not document same-group descendant cleanup |
| `erlexec` | Reject for V1: it is the closest behavioral fit, including clean environment, separate streams, and process-group controls, but exposes a much broader process manager and does not provide PtcRunner's narrow framed backpressure, bounded-stderr, and close-result contract |
| Optional `ptc_runner_launcher` companion | Select: owns the narrow audited protocol and lifecycle contract, reuses the Slice 0 proof, ships checksummed precompiled artifacts without burdening HTTP-only users, and remains replaceable independently of the core library |
| Operator-supplied compatible launcher | Retain only as an explicit host override for hardened or unsupported deployments; it is not the ordinary stdio installation path |

Slice 2 must freeze the launcher protocol version, configuration locator,
framing, exit classifications, and conformance suite before integrating stdio.
It moves the reference implementation into the optional companion package,
adds precompile/release/checksum verification, and makes the core adapter
resolve the companion artifact without a host-config path. An optional
`runtime.stdio_launcher` path overrides it for a trusted custom deployment; the
core freezes the canonical executable and its SHA-256 identity before provider
acquisition. The launcher handshake must match the protocol version. The
override is operator authority, like the selected MCP server executable, not a
claim that PtcRunner certified an arbitrary binary's implementation.
Manifests and PTC-Lisp cannot select either launcher path. Do not build process
ownership directly from a shell wrapper or an observed OS PID.

The core starts the launcher by canonical path, so the trusted launcher
installation hierarchy must remain immutable from preflight through launcher
spawn. The launcher receives the preflighted server SHA-256 in its bootstrap,
hashes the executable it opens, and rejects a mismatch before starting it.
Linux verifies and executes the same held descriptor. macOS verifies and then
executes the canonical path, so its trusted server installation hierarchy must
remain immutable through that second boundary as well.

The owner must:

- start only a host-installed regular executable whose bytes are readable for
  frozen SHA-256 identity, with frozen arguments;
- construct an explicit minimal environment plus declared credential bindings
  rather than inherit arbitrary ambient secrets;
- resolve the executable once under host policy and run from the configured
  canonical `cwd`; Linux holds the opened executable through `fexecve`, while
  macOS executes the canonical path and therefore relies on the trusted
  installation hierarchy remaining immutable during launch;
- frame one newline-delimited UTF-8 JSON-RPC message per line;
- treat stdout as protocol-only and capture bounded stderr as diagnostics;
- correlate concurrent requests by ID;
- send `notifications/cancelled` for an abandoned request;
- close stdin, wait, then escalate termination within a fixed deadline;
- terminate the launched process group on timeout, close, and owner death;
- collect the status of every terminated descendant before reporting a clean
  shutdown, adopting orphans through `PR_SET_CHILD_SUBREAPER` on Linux; and
- redact command arguments marked sensitive, environment values, and private
  payloads from status and public observations.

Descendant reaping is a correctness requirement, not housekeeping. A process
group is probed with `kill(2)`, which still succeeds for un-reaped zombies, so
a killed group only becomes observably empty once every member's status has
been collected. Descendants orphaned by the leader's death are reparented away
from the launcher, and an init that does not reap them — the default for a
container PID 1 — leaves the group permanently non-empty. Without adoption the
launcher then charges every escalated shutdown its full final kill wait and
reports `termination_timeout` instead of `close`, downgrading an orderly
teardown into a transport failure. macOS has no subreaper interface; launchd
reaps orphans promptly, so the group empties there without launcher
involvement.

Unexpected server exit loses in-flight requests. V1 should return a bounded
transport failure rather than automatically retry a potentially effectful
tool. Restart-and-retry can be added only with an effect/idempotence policy.

### 3.6 Discover once, freeze once

Provider assembly performs `server/discover` and paginated `tools/list`,
selects only host-mapped upstream names, compiles their schemas, sorts the
public catalog, and freezes the resulting capabilities and safe snapshot for
the run.

`ttlMs` and `cacheScope` may later avoid discovery between builds:

- TTL never refreshes a catalog inside an already assembled run.
- `public` catalogs may share a cache key based on endpoint/server version and
  safe installation configuration.
- `private` catalogs may only be reused within the same authorization context.
  PtcRunner must not hash or log credential values merely to invent a cache
  key; private caching needs a host-supplied stable partition identity.
- `subscriptions/listen` is unnecessary for the first immutable run model.
  It may invalidate a long-lived host cache later, but must not mutate active
  capabilities.

The safe provider snapshot contains the selected protocol, transport kind,
public names, host effects, normalized schema hashes, hashes of effective
model-visible descriptions, hashes of mapped upstream names, normalized
`x-mcp-header` behavior, server implementation identity, an optional hash of
the host-supplied `installation_revision`, any validated content snapshot
identity, and an overall content hash. A prompt-visible
remote description is behavioral input and must affect the snapshot even when
the text itself is not published.

`installation_revision` is an optional bounded non-secret host value. Use it
only when the operator needs to distinguish behavior not otherwise captured
by safe configuration, discovery, or content identities—for example a remote
deployment, executable build, private arguments, or credential scope. When
present it affects the provider snapshot. Safe decoded fields and discovered
identities already affect that snapshot directly; ordinary installations do
not need a ceremonial `"v1"`. This deliberately does not hash private paths,
endpoints, arguments, or credentials merely to manufacture an identity.
For an immutable data server, optional `snapshot_identity` names one
host-mapped read tool and one safe SHA-256 result field. PtcRunner invokes it
once after discovery/schema validation and freezes the returned identity.
Reproducible content claims require such an identity or an equally strong
protocol-native one.

Raw executable paths, endpoints, arguments, roots, credentials, task IDs,
state handles, tool arguments, and ordinary results remain excluded. A schema
hash alone is never described as proof that two providers or datasets behave
identically.

### 3.7 Keep a bounded callable schema profile

MCP now permits full JSON Schema 2020-12, but PtcRunner should not allow an
arbitrary remote schema to weaken its callable boundary.

- Tool inputs still require an object root.
- Input and output schemas compile once during assembly.
- Unsupported composition, references, formats, patterns, depth, property
  counts, or encoded size cause a mapped tool to be rejected.
- External `$ref` targets are never fetched.
- Unmapped tools do not need to compile because they can never be called.
- Output compilation should eventually allow any JSON root, matching MCP
  `structuredContent`; this requires a separate output compiler entry point
  rather than weakening the input rule.
- The controlled sample server deliberately emits object outputs inside the
  current bounded profile, so arbitrary output roots are not a prerequisite
  for the first tutorial.

PtcRunner should validate `structuredContent` against the frozen output schema.
Text, images, embedded resources, and resource links need explicit bounded
normalization policies before exposure. Unknown content must not be silently
converted into a string.

### 3.8 Preserve useful tool errors and exact private evidence

MCP tool-execution errors are intended to help a model correct a call. The
current adapter reduces every `isError` result to `mcp_domain_error`, which is
safe but prevents recovery.

The planned result has two separate observation planes:

- Public results, canonical traces, logs, telemetry, and terminal errors keep
  stable closed classifications without remote messages or payloads.
- Agent feedback may receive a byte-bounded, validated MCP tool-error content
  value when the host mapping enables bounded feedback. The default for an
  unknown server remains closed. Feedback is untrusted data, never an
  instruction or authority grant.

Bounds and type validation cannot semantically remove a stacktrace, private
path, or secret from arbitrary prose. Enabling feedback therefore trusts the
host-installed server's error contract and data classification. The controlled
sample server guarantees path/stacktrace-free errors; third-party mappings
remain closed unless the host accepts their bounded text as data.

Private inspection should capture the exact bounded JSON-RPC request and
response bodies needed to diagnose the adapter, in addition to the existing
provider-neutral capability input/output. It must omit rendered credential
headers and subprocess environment values. Stream fragments are captured only
after bounded reassembly and strict decoding, and capture failure must not
leak partial payloads into public traces.

This is not general wire logging. It is an explicitly requested private
artifact with the existing no-clobber, `0600`, correlation, and size rules.
The current inspection format has an exact V1 record vocabulary, so MCP
exchange records require a new versioned vocabulary; they must not be emitted
as unknown records in a V1 artifact.

### 3.9 Tools first; do not mirror all of MCP into the Kernel

MCP Resources are application-controlled context, while Tools are
model-controlled operations. PtcRunner's current capability boundary maps
naturally to Tools. The first implementation therefore supports
`server/discover`, `tools/list`, and `tools/call`.

Do not add a generic Kernel resource abstraction merely because MCP defines
one. Resources become useful later for host-selected context, large immutable
artifacts, or links returned by tools. A later design may support
`resources/list` and `resources/read` without making every resource directly
model-callable.

New implementations should not adopt deprecated MCP Roots, Sampling, or
Logging:

- filesystem roots belong in server configuration or explicit tool/resource
  parameters;
- PtcRunner continues to call its LLM provider directly; and
- stdio uses bounded stderr while structured observability uses PtcRunner
  events and OpenTelemetry.

Prompts and MCP Apps are also outside the first capability source. PTC-Lisp
preludes remain the trusted composition and instruction layer.

### 3.10 Explicit application state

The protocol is stateless even when an application is not. A server that
creates a browser, transaction, candidate workspace, or long-lived snapshot
returns an opaque handle and accepts it as an ordinary later tool argument.

PtcRunner must never reinterpret such a handle as proof of authorization. The
server validates the caller on every use, handles have bounded lifetimes, and
expired handles return recoverable tool errors. Host-bound hidden arguments
may eventually spare models from threading installation state, but should be
added only for a demonstrated server contract rather than as part of the first
client.

The filesystem sample avoids a handle: its read-only snapshot is fixed server
configuration created at process startup, not state created by an earlier tool
call.

### 3.11 Defer MRTR and Tasks until the synchronous boundary is explicit

`resultType: "input_required"` and the Tasks extension are important but do not
belong in the first synchronous tool adapter.
The exact wire literal follows the normative draft changelog and schema:
`input_required`. An early release-candidate blog example used
`inputRequired`; that prose is not the protocol contract.

V1 behavior:

- advertise neither elicitation/MRTR handling nor the Tasks extension;
- reject unexpected `input_required` or `task` results with stable protocol
  classifications; and
- never let generated code answer a human approval on the user's behalf.

A later MRTR design must specify who supplies each input, how the original
deadline and capability budget span retries, how opaque `requestState` is
stored, and how private input is classified.

Tasks are a strong later fit for test runs, indexing, candidate evaluation,
CI, and approval gates. Support requires Kernel-owned task handles, durable
retention policy, poll accounting, `tasks/get`, `tasks/update`,
`tasks/cancel`, cancellation on run close, and a decision about whether a task
may outlive its creating run. Polling is the default; subscriptions are an
optimization.

### 3.12 Propagate trace context, not private baggage

PtcRunner should propagate W3C `traceparent` and, when safe, `tracestate`
through MCP `_meta` so a capability call can correlate with spans in the MCP
server and downstream systems. Arbitrary `baggage` is disabled by default:
paths, arguments, user data, credentials, and snapshot handles must not become
ambient telemetry.

Canonical PtcRunner events remain authoritative for run accounting. Remote
OpenTelemetry spans are correlated operational evidence, not replacements for
capability events.

## 4. The sample filesystem MCP server

The repository should ship a clearly labelled non-production sample server
for the tutorial and deterministic integration tests. It demonstrates how a
server in another language can extend PtcRunner without Elixir changes.

Use the official TypeScript SDK v2 after a stable release supporting
`2026-07-28`; before then, pin a reviewed beta only on an experimental branch.
Do not download an unpinned package at tutorial runtime.

Commit the sample's TypeScript source, exact package-manager lockfile, bundled
`dist/server.js`, and required license metadata. CI regenerates the bundle and
fails on a diff. The bundled artifact is included wherever a clean checkout or
release-installed tutorial needs it; tutorial execution never runs
`npm install` or downloads code.

The official MCP filesystem server supplies familiar naming precedent
(`read_text_file`, `list_directory`, `search_files`) but is not the sample's
safety contract: it exposes writes, observes a live filesystem, and currently
documents deprecated Roots behavior. The PtcRunner sample is narrower:

| Tool | Purpose |
| --- | --- |
| `list_directory` | Sorted, paginated relative entries under a relative prefix |
| `search_files` | Sorted, paginated path/glob discovery |
| `search_text` | Literal text search with path and line evidence |
| `read_text_file` | One bounded UTF-8 line range with stable line numbers and explicit EOF/truncation |
| `snapshot_info` | Safe content hash and bounded inventory statistics, never the host root |

Server invariants:

- one host-supplied root is captured before discovery completes;
- capture requires at least one host-supplied include pattern and defaults to
  no files; optional excludes may only narrow that set;
- every operation reads the same bounded in-memory UTF-8 representation;
- paths are relative and traversal, absolute paths, NULs, devices, aliases,
  and symlinks are rejected;
- file, entry, aggregate-byte, result-byte, match, page, and structural-depth
  bounds are fixed at startup;
- excluded paths are never opened or inventoried, so secrets, private result
  directories, dependency trees, and build output cannot become ordinary
  workspace data merely because they are below the root;
- results are deterministic structured objects inside PtcRunner's callable
  schema profile;
- every data-bearing result includes the same safe snapshot hash, so citations
  can be bound to the bytes the server actually queried;
- tool errors use bounded actionable text without stacktraces or host paths;
- the catalog is deterministic and marked `cacheScope: "private"` unless it
  is provably identical across users;
- no write, subprocess, network, Roots, Sampling, Logging, MRTR, or Tasks
  feature is advertised; and
- stdout contains protocol messages only.

These are sample-server tool names, not a second PtcRunner API. Another MCP
server may use different names and schemas; the host tool map and PTC-Lisp
prelude adapt it without changing the runtime.

The sample may read source repositories, documentation trees, exported logs,
or arbitrary folders selected by the host include rules. The server does not
know what a repository is. PTC-specific interpretation belongs in different
preludes or providers, not in the generic filesystem server.

Canonical PTC traces and private inspection remain native PtcRunner snapshot
sources because PtcRunner owns their versioned schemas, correlation rules, and
confidentiality boundary. An optional trace MCP server should not land until
it can reuse the authoritative parser or a shared conformance corpus; copying
that parser into TypeScript would create a second truth.

## 5. Host configuration and manifest grammar

The host document uses one outer installation grammar:

```json
{
  "$schema": "./priv/schemas/ptc-host-config.schema.json",
  "runtime": {
    "stdio_launcher": "<optional absolute custom-launcher path>"
  },
  "credentials": {
    "issues_token": {"env": "ISSUES_TOKEN"}
  },
  "install": {
    "<provider-name>": {
      "source": "mcp",
      "transport": {"type": "stdio | streamable_http"},
      "tools": {
        "<upstream-name>": {
          "as": "<public-name>",
          "effect": "read",
          "description": "<optional host-owned override>",
          "error_feedback": "closed | bounded"
        }
      },
      "snapshot_identity": {
        "tool": "<optional mapped read tool>",
        "field": "<safe sha256 field>"
      },
      "installation_revision": "<optional non-secret opaque-behavior revision>",
      "ceilings": {}
    }
  }
}
```

`runtime.stdio_launcher` is an optional custom-deployment override shared by
every stdio installation in the document. Without it, stdio selects the
optional `ptc_runner_launcher` companion. Pure preparation validates that
selection syntactically. A later non-secret local preflight resolves and hashes
the selected artifact before any credential is resolved or process is spawned;
it fails when neither implementation is available. The launcher protocol
version, package version when applicable, and frozen executable SHA-256 are
part of the safe provider snapshot; the deployment path is not. A programmatic
host builder may supply the equivalent trusted override directly. Manifests
and generated programs have no field for it.

PtcRunner ships two JSON Schema 2020-12 documents in its release:

```text
priv/schemas/ptc-host-config.schema.json
priv/schemas/ptc-application-manifest.schema.json
```

`$schema` is an optional editor annotation accepted in either document. The
tutorial uses a path relative to the repository root; another project may
point at the copy in its installed PtcRunner dependency or a version-matched
published copy. PtcRunner never dereferences this URI at runtime and excludes
it from provider and run identities.

Both schemas are generated by `mix ptc.gen_docs`, checked into the release,
and covered by the generated-file check in `mix precommit`. The new host
decoder uses a closed structural descriptor that also generates the host
schema. The existing manifest decoder remains explicit and
security-oriented; its schema is generated from a separate explicit schema
definition kept beside it. Do not introduce a generic configuration-schema
DSL merely to make those two implementations look alike.

The schemas use discriminated source and transport unions, reject unknown
properties, document required fields and omission defaults, and carry
descriptions and small examples so editors can provide completion, hover help,
and structural errors before `mix ptc.run`. One shared valid/invalid fixture
corpus plus every concrete documentation config must pass through both schema
validation and the corresponding runtime decoder. Abstract grammar sketches
with placeholder names are excluded. That proves structural agreement without
making JSON Schema the runtime security boundary.

JSON Schema is intentionally only the structural front door. The strict
runtime loader remains authoritative for duplicate keys, bounded loading,
path confinement, reference resolution, host-ceiling narrowing, data-class
and egress compatibility, MCP discovery, and lifecycle checks. Defaults shown
in schema annotations describe decoder behavior; validation does not mutate
the input document.

Three safe omission defaults keep ordinary read installations compact:

- a mapped tool is not model-visible unless it explicitly sets
  `"model_visible": true`;
- provider `data_class` is `"normal"` unless its closed source kind fixes a
  stricter class, and `accepts_data` is `["normal"]` unless explicitly
  widened; and
- an omitted stdio `env` is an empty binding map, while the closed transport
  still supplies its versioned compatibility environment.

These are local field defaults, not a shared defaults block or merge rule.
`as` and `effect` remain required for every mapped tool because they define
the public name and authority.

`ceilings` is a closed key set owned by each source's decoder; unknown
ceiling keys fail strict loading. An omitted key or an empty `ceilings`
object selects that source's documented safe default, never "unlimited". For
the V1 `mcp` source the keys are exactly `timeout_ms`, `max_catalog_tools`,
and `max_result_bytes`. Slice 3 documents every source's ceiling keys and
defaults in the generated schemas.

The manifest uses the same narrowing keys for every installed provider:

```json
{
  "name": "workspace",
  "config": {
    "allow": ["workspace.search", "workspace.read"],
    "timeout_ms": 3000,
    "max_result_bytes": 100000
  }
}
```

### 5.1 Credential bindings

The outer host grammar owns one credential-binding mechanism shared by closed
host-installed sources. A credential declaration has exactly one source:

- `{"env": "NAME"}` reads one environment variable;
- `{"file": "relative/or/absolute/path"}` reads one bounded secret file, with
  relative paths based at the canonical host-config directory; or
- `{"literal": "value"}` stores the secret in the host document itself and
  therefore makes that document sensitive and unsuitable for source control.

Providers and transports refer to a declared credential by binding name; they
never carry an inline secret. Unknown bindings fail strict host-config loading.
Static source, selection, and data-class/egress checks run before secret
materialization. Each referenced secret is then resolved exactly once per run
as the first acquisition step, after static authorization and non-secret
preflight but before sensitive snapshots, subprocess spawn, remote contact, or
model activity. A missing environment variable, unreadable secret file, or
otherwise invalid binding fails at that boundary. Rotation takes effect on the
next run.

Streamable HTTP and other request/response sources render the retained
per-run value through a closed `auth` entry at the moment of each exchange:

| Scheme | Required fields | Rendered header |
| --- | --- | --- |
| `bearer` | `binding` | `Authorization: Bearer <secret>` |
| `basic` | `binding` | `Authorization: Basic <secret>` |
| `api_key` | `binding`, `header` | `<header>: <secret>` |

Header names are strictly validated. An `api_key` entry cannot override
framing, routing, MCP protocol, proxy, or other reserved headers. The provider
retains the value only inside a private header-producing closure, never a
rendered header or secret-bearing map. This keeps credentials structurally
absent from capabilities, snapshots, inspection records, serialized errors,
telemetry, and owner status. Rendering per exchange avoids long-lived rendered
headers; it does not re-read or refresh the credential during a run.

Closed sources may expose a narrower source-specific reference when the
adapter already owns the wire convention. In particular, an `llm`
installation uses `"credential": "<binding>"`; the selected model adapter
decides whether that binding becomes a bearer token, API-key header, or another
fixed supported form. This keeps a known LLM configuration compact without
letting the manifest choose headers. Generic MCP HTTP endpoints still use the
explicit closed `auth` scheme because their wire convention is not implied by
the source.

Stdio has no request header channel. Its transport maps an allowlisted
subprocess variable to a binding:

```json
{
  "credentials": {
    "github_token": {"env": "GITHUB_TOKEN"}
  },
  "transport": {
    "type": "stdio",
    "env": {
      "GITHUB_TOKEN": {"binding": "github_token"}
    }
  }
}
```

The child environment starts from a closed compatibility profile modeled on
the official TypeScript and Python SDKs' sudo-inspired policy. On macOS and
Linux its inherited names are exactly `HOME`, `LOGNAME`, `PATH`, `SHELL`,
`TERM`, and `USER`; missing names stay absent and shell-function values are
rejected. These six names are reserved and cannot appear in the stdio
credential-binding map. Explicit bindings for other names then extend that
base. No other ambient variable reaches the child. A stdio transport may set
`"inherit_environment": false` to request a genuinely empty base when its
canonical command and arguments need no wrapper/runtime discovery.

The profile name/version and inherited variable names are safe snapshot
metadata. Values are never recorded: paths and user names may be private, and
credential-like values must never enter this allowlist. Operators use
`installation_revision` when a behavior-defining ambient value changes without
another safe identity. Windows gets its own revalidated profile only with the
deferred Job Object design; do not copy today's SDK list into V1.

`command`, `args`, and `cwd` deliberately match common MCP client
configuration, so those fields paste directly. Existing literal `env` entries
must be promoted into host credential declarations and binding references
rather than creating a second inline-secret grammar.

A bare command such as `node` is resolved during the same non-secret local
preflight through the closed, unoverlaid compatibility `PATH`. The resulting
canonical executable must be a readable regular file; its SHA-256, not the
unresolved name, is frozen before acquisition. An absolute command bypasses
`PATH` lookup but has the same readability and identity requirement.

The effective environment is redacted from logs and process status. Binding
values are rendered at spawn from the once-resolved per-run values, not re-read
by the child owner. The owner-monitored transport terminates and observes the
subprocess before run cleanup completes. Manifests and PTC-Lisp can neither
name bindings nor read, replace, or render
credentials.

### 5.2 Prepare before acquire

Provider installation needs an internal preparation barrier:

1. **Prepare** is pure. It decodes closed source configuration, resolves
   aliases and manifest narrowing, validates ceilings, effects, placement, and
   data-flow compatibility, and returns an inert prepared provider
   description.
2. **Preflight** runs only after every selected provider has prepared
   successfully. It performs bounded non-secret local checks needed to freeze
   installation identity, including launcher/server executable resolution and
   hashing. It does not resolve credentials, spawn, open sensitive snapshots,
   or contact remote endpoints.
3. **Acquire** runs only after every selected provider has passed preflight. It
   resolves the already-authorized credential bindings, captures sensitive
   snapshots, starts owned processes, contacts remote endpoints, performs
   discovery, and returns the frozen capabilities, snapshots, and cleanup
   ownership.

If preparation or preflight fails, no credential is read and no provider
performs remote or process I/O. If acquisition later fails, the run builder
closes every resource already acquired. This is a small internal boundary in
`ProviderRegistry` and `RunBuilder`, not a public provider framework.

`allow` defaults to all host-installed public names. That is not escalation:
the host's `tools` map is the authority allowlist. Mapped tools are
model-invisible by default; an explicit host `model_visible: true` adds one to
the maximum model-visible set. Visibility is prompt-catalog discovery only,
never authority: a selected but model-invisible capability remains callable
by prelude and generated code that names it directly, matching the Kernel's
current `model_visible` semantics. The invisible default is applied by the
host tool-map decoder; the `Capability` struct keeps its current
`model_visible: true` default for other builders. The host may also replace
an untrusted remote description with host-owned text. Manifest `model_visible` may only reduce
that installed set. The manifest may lower ceilings but cannot change
transport, upstream names, effects, descriptions, error visibility,
credentials, or data classes.

For manifest/CLI execution through `mix ptc.run`, host installation is the
complete provider registry for a provider-bearing run, not an overlay on the
current implicit `llm` and `file-read` built-ins. Slice 3 defines the closed
host schema without a `file-read` source; Slice 5 activates the host-only
registry while deleting legacy manifest-owned provider construction and its
inline config shapes (`model` and `cache` for `llm`; `root`, `max_bytes`, and
`model_visible` for `file-read`). Provider-free manifests may still
run without a host document. This keeps one authority path: a provider alias
exists only because the operator installed it.

Trusted direct Elixir embedding remains able to construct and pass an explicit
`ProviderRegistry`, including custom builders. That programmatic host API is
not part of the no-Elixir manifest contract and is not removed by the CLI
cutover.

For generic external integrations, the only source identifier in this plan is
`mcp`. In particular, `source: "file-read"` is an unknown source and fails
strict decoding. The application direction separately defines the closed
host-owned `llm`, replay, trace, and private-inspection sources; none is a
second generic filesystem provider.

The V1 host schema and decoder accept only `effect: "read"`. The wider internal
capability effect enum is a future contract, not accepted host grammar.
`write` and `unknown` remain structurally invalid until guarded-write policy
lands.

V1 placement is restricted the same way: an installed `mcp` provider may be
selected only into the mission environment. Selecting an MCP alias into
`providers.workflow` fails prepare-phase placement validation. Workflow-side
MCP remains an explicit open decision in the application plan.

For an installed provider that accepts private inspection data, assembly
conservatively treats every selected remote or write capability as a possible
egress sink. The host, not the manifest, declares accepted classes.

Static source, selection, and data-class compatibility checks must finish
before credentials are resolved, sensitive snapshots are opened, a stdio
process is spawned, or a remote endpoint is contacted. MCP discovery validates
the already-authorized installation in a later dynamic phase.

## 6. Implementation sequence

Slices 0–3 are the shared protocol and installation foundation. After they
land, Slice 4 (feedback/private inspection) and Slice 5 (the filesystem sample
and `file-read` cutover) are independent and may land in either order. The
application plan deliberately uses the filesystem slice first; the complete
private-inspection tutorial requires both.

### Slice 0 — Behavior-preserving seams and launcher proof

- Extract pure MCP request/result envelope handling, `resultType`
  classification, catalog pagination and normalization, and
  tool/result/schema/snapshot normalization from HTTP framing and session
  lifecycle.
- Preserve current `2025-11-25` behavior and fixtures exactly while moving
  code; do not modernize protocol semantics in this slice.
- Do not generalize `MCPLease`: Slice 1 removes the obsolete session lifecycle
  rather than refactoring it into a new abstraction.
- Complete the macOS/Linux stdio launcher proof from §3.5 and select the
  launcher boundary before Slice 2 implementation. Keep the proof outside the
  Hex application and compile it only in focused tests.

**Gate:** current MCP tests pass unchanged through the extracted pure seams,
the Hex package has no native build requirement, and the test-only reference
proves the closed compatibility environment and strict-empty override,
separate streams, process-group ownership, and same-group descendant
termination on both supported platforms.

### Slice 1 — Modern stateless Streamable HTTP

- Implement against the locked `2026-07-28` release candidate now and keep
  protocol constants and parsing seams localized.
- After final publication, reconcile any specification, conformance-fixture,
  or stable-SDK delta without treating publication as a prerequisite.
- Replace initialization/session behavior with per-request `_meta` and
  `server/discover`.
- remove `Mcp-Session-Id`, expiry, session DELETE, and old task-support fields;
- implement required HTTP request headers, result types, cache hints, and
  strict response handling;
- validate and mirror `x-mcp-header` parameters with the required primitive
  conversion and Base64-sentinel encoding;
- preserve current deadlines, byte bounds, duplicate-key rejection,
  redaction, and deterministic snapshots; and
- update the live MCP E2E target to a server supporting the pinned version.

**Gate:** the HTTP adapter has no protocol-session state and interoperates with
one real modern server.

### Slice 2 — One protocol client and stdio transport

- Reuse the Slice 0 protocol parsing and normalization seams.
- Add the owner-monitored stdio subprocess transport.
- Define and version the narrow external-launcher framing and termination
  contract, plus a conformance suite reusable by alternative implementations.
- Move the proven launcher into the optional `ptc_runner_launcher` package.
- Publish mandatory checksums and precompiled macOS/Linux artifacts with
  release CI; test artifact download, checksum verification, source fallback,
  and the packaged executable on each supported target.
- Resolve the companion by default and permit only a trusted host-level custom
  launcher override; freeze its binary identity and do not expose the choice
  to manifests or PTC-Lisp.
- Use one `source: "mcp"` builder with typed transport configuration.
- Prove cancellation, timeout, owner death, stderr bounds, malformed framing,
  launched-process-group termination, and exact-once close behavior.
- Include regressions for an `npx`-shaped wrapper plus nested descendants,
  repeated connect/disconnect without Port or pipe growth, junk on protocol
  stdout, and startup with every compatibility-environment name independently
  absent.
- Fail unsupported platforms deterministically before spawning.

**Gate:** the same tool fixture passes through stdio and Streamable HTTP and
emits equivalent capabilities and safe snapshots, and the packaged Hex library
contains no native artifact or native build hook. Installing the companion on
a supported target downloads and verifies a precompiled launcher without
requiring a compiler.

### Slice 3 — Generic host-config installation

- Add `mix ptc.run --host-config PATH`.
- Strictly decode bounded JSON with duplicate-key rejection.
- Build the new host decoder from a canonical closed structural descriptor and
  generate the host JSON Schema 2020-12 document from it.
- Keep the existing explicit manifest decoder and add its explicit schema
  definition alongside it; generate the manifest JSON Schema from that
  definition without introducing a generic decoder DSL.
- Accept optional non-semantic `$schema` annotations without fetching them,
  and exclude them from effective identities.
- Extend `mix ptc.gen_docs` and the precommit generated-file check so schema
  artifacts cannot drift from the runtime vocabulary.
- Resolve paths relative to the canonical host-config directory.
- Accept an optional bounded non-secret `installation_revision` and include it
  in the provider snapshot when present.
- Resolve credential bindings without storing values in snapshots.
- Add the prepare/preflight/acquire provider barrier from §5.2 and resolve each
  referenced credential exactly once per run only after every provider passes
  non-secret local preflight.
- Decode only closed built-in source and transport identifiers.
- Do not add a `file-read` host source or accept its legacy `root`,
  `max_bytes`, or `model_visible` config.
- Prepare the run registry to contain exclusively host-installed aliases at
  the filesystem cutover in Slice 5.
- Check selected data classes and possible egress sinks before resolving
  credentials or opening any provider.
- Add `--check` to assemble, discover, hash, and close without invoking the
  workflow or model.
- Print a bounded resolved view ordered by environment and alias, including
  source/transport, selected tool counts, accepted data classes, and safe
  snapshot identities rather than echoing heterogeneous raw config.

**Gate:** an ordinary manifest selects a configured MCP server without any
Elixir registration change; every concrete plan/tutorial configuration
validates against the shipped schema, and a shared valid/invalid fixture
corpus agrees between schema validation and the structural runtime decoder.

### Slice 4 — Useful feedback and private MCP inspection

- Separate public closed errors from bounded model feedback.
- Add correlated private MCP request/response records without credentials.
- Propagate safe trace context.
- Test malicious error text, oversized frames, malformed SSE, cancellation,
  and inspection persistence failures.

**Gate:** an agent can correct a safe server-reported argument error, while a
private reviewer can reconstruct the full exchange and public artifacts reveal
neither payload nor credentials.

### Slice 5 — Sample server and filesystem acceptance

- Pin one RC-compatible official TypeScript SDK generation for initial work,
  then move to the stable generation after publication.
- Commit source, an exact lockfile, the reproducible bundled server, and
  required license metadata; make CI fail when regeneration changes the
  bundle.
- Implement the immutable read-only filesystem sample.
- Require an explicit default-deny include set and prove excluded files are
  never opened or listed.
- Freeze its `snapshot_info` identity during provider assembly.
- Add protocol and deterministic filesystem fixtures.
- Run it through the generic host-config and manifest path.
- Migrate every current `file-read` example and test to the mapped MCP tools.
- Delete the implicit `file-read` builder, manifest config, and
  `FileCapability` only after the MCP filesystem acceptance suite passes.
- Activate the host-only provider registry in the same breaking cutover, so
  no released target supports both filesystem authority paths.
- Keep application behavior in PTC-Lisp and the generic runner.

**Gate:** the repository-analysis tutorial can navigate unknown nested files,
search text, and read bounded ranges with no application-specific Elixir.

### Later slices

- arbitrary JSON output roots;
- safe cross-build catalog caching;
- host-selected MCP Resources;
- MRTR for explicit interactive input;
- Tasks for long-running operations;
- write-capable mappings and approval policy; and
- remote OAuth following the final authorization specification.

Each later feature must negotiate its extension/capability explicitly. Do not
advertise what PtcRunner cannot honor.

## 7. Acceptance matrix

| Case | Expected result |
| --- | --- |
| Legacy sessionful server | Deterministic unsupported-protocol failure; no fallback |
| Provider-bearing manifest has no host config | Strict missing-installation failure; no implicit built-in registry |
| Manifest supplies legacy inline `llm` or `file-read` provider config | Strict load failure before provider activity |
| Editor validates a host config or manifest | Shipped schema supplies completion and structural errors without running PtcRunner |
| `$schema` is omitted or names a local/version-matched copy | Runtime behavior and effective identity are unchanged |
| Structurally valid config violates a cross-file or runtime rule | `--check` reports the bounded semantic error; schema success is not treated as assembly success |
| Host config declares `source: "file-read"` | Strict unknown-source failure; filesystem capabilities use `source: "mcp"` |
| Host mapping declares an effect other than `read` | Structural host-config failure; guarded writes are not V1 grammar |
| PtcRunner loads its host config, manifest, component, schema, or input | Dedicated confined loader is used; no MCP bootstrap dependency |
| Any selected provider fails pure preparation | No credential, sensitive snapshot, subprocess, network endpoint, or model is touched |
| Credential changes while a run is active | Active run keeps its once-resolved private value; the next run observes the change |
| Server catalog contains an unmapped tool | Tool is not exposed and does not need a callable schema |
| Mapped tool is absent or its schema is unsupported | Provider assembly fails before model activity |
| Manifest names an unmapped tool or changes an effect | Strict selection failure |
| Mapping omits `model_visible`, ordinary provider omits normal data fields, or stdio omits `env` | Tool is model-invisible, provider is normal-only, and no child credential binding is added |
| Stdio credential map names a reserved compatibility variable | Strict host-config failure before preflight |
| Generated code calls a selected model-invisible mapped tool by name | Call succeeds; visibility filters the prompt catalog, not authority |
| Manifest selects an MCP alias into workflow | Strict unsupported-environment failure; workflow-side MCP is deferred |
| Tool list changes after assembly | Active run keeps its frozen catalog |
| Stdio is requested on an unsupported platform | Deterministic pre-spawn configuration failure |
| Stdio is installed without the companion or a trusted custom override | Non-secret local preflight failure before credentials are resolved or a process is spawned |
| Custom launcher bytes change | The next run freezes a different launcher identity in its provider snapshot; changing only the non-recorded deployment path to identical bytes does not |
| Launcher protocol handshake does not match | Deterministic pre-server-spawn compatibility failure after the launcher starts |
| Stdio server writes non-protocol stdout | Closed protocol failure; process is terminated |
| Stdio server or same-group descendant survives close deadline | Escalated launched-process-group termination and closed cleanup result; `setpgid`/`setsid` escape is outside V1 |
| HTTP headers disagree with the body | Closed protocol failure |
| Valid mapped `x-mcp-header` parameter is present | Required `Mcp-Param-*` header mirrors the body using specified encoding |
| `x-mcp-header` definition is invalid | Tool is excluded; a host mapping to it fails assembly |
| `resultType` is unknown, `input_required`, or `task` without support | Stable unsupported-result failure |
| Tool returns an oversized or schema-invalid value | Closed invalid-result failure before Lisp receives it |
| Tool returns bounded actionable `isError` content | Public error stays closed; model receives it only under installed bounded-feedback policy |
| Private inspection is not requested | No MCP payload-bearing diagnostic artifact is retained |
| Private inspection is requested | Correlated bounded bodies are captured; credentials and rendered auth headers are absent |
| Filesystem changes after sample-server capture | All calls continue to observe the frozen snapshot |
| Installation revision is omitted | Provider snapshot uses its other safe identities; no synthetic revision is added |
| Present installation revision or frozen content identity changes | Effective provider snapshot hash changes |
| Secret, private-output, dependency, or build path is outside the include set | It is neither opened nor visible through inventory/search/read |
| Generated code requests traversal or a write tool | Server rejects traversal; no write tool was installed or advertised |
| Run terminates with an MCP call in flight | Request/process work is cancelled and observed before resources close |

## 8. Explicit non-goals

- a raw HTTP or OpenAPI provider;
- a universal shell capability;
- arbitrary executable/module names in a manifest;
- automatic effect inference from MCP annotations;
- Windows stdio process ownership in V1;
- legacy MCP compatibility;
- live mutable tool catalogs inside a run;
- full MCP Resources, Prompts, Apps, MRTR, or Tasks in the first slice;
- importing MCP server instructions into the system prompt;
- treating an opaque state/task handle as authorization;
- production certification of the sample filesystem server; or
- duplicating PTC trace/inspection parsing in another language.

## 9. References reviewed

- [2026-07-28 MCP release candidate](https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/)
- [MCP draft changelog](https://modelcontextprotocol.io/specification/draft/changelog)
- [Versioning and compatibility](https://modelcontextprotocol.io/specification/draft/basic/versioning)
- [`server/discover`](https://modelcontextprotocol.io/specification/draft/server/discover)
- [MCP tools](https://modelcontextprotocol.io/specification/draft/server/tools)
- [Stdio transport](https://modelcontextprotocol.io/specification/draft/basic/transports/stdio)
- [Streamable HTTP transport](https://modelcontextprotocol.io/specification/draft/basic/transports/streamable-http)
- [Caching](https://modelcontextprotocol.io/specification/draft/server/utilities/caching)
- [MCP Tasks](https://modelcontextprotocol.io/extensions/tasks/overview)
- [Deprecated Roots](https://modelcontextprotocol.io/specification/draft/client/roots)
- [Official filesystem server](https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem)
- [Official TypeScript SDK stdio client](https://github.com/modelcontextprotocol/typescript-sdk/blob/v1.x/src/client/stdio.ts)
- [Official Python SDK stdio client](https://github.com/modelcontextprotocol/python-sdk/blob/main/src/mcp/client/stdio.py)
- [TypeScript SDK process-tree cleanup issue](https://github.com/modelcontextprotocol/typescript-sdk/issues/2023)
- [Python SDK process-tree cleanup change](https://github.com/modelcontextprotocol/python-sdk/pull/850)
- [Codex MCP descriptor/orphan regression](https://github.com/openai/codex/issues/26984)
- [Codex inherited-environment compatibility regression](https://github.com/openai/codex/issues/4180)
- [Erlang ports](https://www.erlang.org/doc/apps/erts/erlang.html#open_port/2)
- [Erlang Ecosystem Foundation external-executable hardening](https://security.erlef.org/secure_coding_and_deployment_hardening/external_executables.html)
- [`erlexec`](https://hexdocs.pm/erlexec/readme.html)
- [`ExCmd.Process`](https://hexdocs.pm/ex_cmd/ExCmd.Process.html)
- [`MuonTrap`](https://hexdocs.pm/muontrap/readme.html)
- [`elixir_make` precompilation guide](https://elixir-make.hexdocs.pm/precompilation_guide.html)
- [`cc_precompiler` checksum guide](https://cc-precompiler.hexdocs.pm/precompilation_guide.html#generate-checksum-file)
