# Host configuration

The host document is the operator's half of a PtcRunner deployment. It is a
strict JSON file, separate from any application manifest, that decides which
providers exist, what their names mean, where their credentials come from, what
data they may touch, and how large a run may get.

A manifest may then select an installed alias and narrow it. It can never
introduce a provider, name an executable or endpoint, carry a credential, or
raise a ceiling. Pass the document explicitly:

```console
mix ptc.run MANIFEST --host-config ptc-host.json
```

A provider-bearing manifest requires `--host-config`; a provider-free manifest
runs without one.

Loading is bounded, path-confined, duplicate-key rejecting, and side-effect
free. Credential declarations are validated but not read, executables are not
resolved, no process is started, and no endpoint is contacted. Those belong to
the later preflight and acquisition phases.

## The document

```json
{
  "credentials": {
    "openrouter_key": {"env": "OPENROUTER_API_KEY"}
  },
  "install": {
    "deepseek": {
      "source": "llm",
      "model": "openrouter:deepseek/deepseek-v4-flash",
      "credential": "openrouter_key",
      "cache": false
    },
    "workspace": {
      "source": "mcp",
      "transport": {
        "type": "stdio",
        "command": "node",
        "cwd": ".",
        "args": ["../mcp/filesystem/dist/server.js", "--root", "files"],
        "inherit_environment": true,
        "env": {}
      },
      "tools": {
        "read_text_file": {"as": "workspace.read", "effect": "read"}
      },
      "installation_revision": "filesystem-sample-0.1.0",
      "ceilings": {"timeout_ms": 15000, "max_catalog_tools": 8}
    }
  }
}
```

Only `install` is required. The other top-level keys are `credentials`,
`limits`, `runtime`, and `$schema`. Unknown keys are rejected. A document is at
most 1 MB and holds at most 128 installations and 128 credentials. Every alias,
credential name, and public tool name matches `^[a-z][a-z0-9._-]{0,127}$`.
Optional properties use omission for their default; an explicit JSON `null`
does not mean omitted and fails structural validation.

`installation_revision` is a nonempty, NUL-free operator string of at most 256
UTF-8 bytes. It records which build of a server or model policy an alias
represents so that traces from different installations remain distinguishable.

The canonical structural description is shipped as
`priv/schemas/ptc-host-config.schema.json` for editor completion. Runtime
decoding stays authoritative for semantic checks such as unique public tool
names, credential references, reserved headers, and portable environment names.
Standalone command diagnostics classify duplicate properties as structural
host failures and retain only the duplicate's schema-authorized parent pointer.

## Credentials

A credential is declared once and referenced by name. There are exactly three
forms:

```json
"credentials": {
  "openrouter_key": {"env": "OPENROUTER_API_KEY"},
  "vendor_token":   {"file": "secrets/vendor.token"},
  "fixed_key":      {"literal": "sk-example-not-a-real-key"}
}
```

- `env` reads a process environment variable at acquisition time. The name must
  be a portable `^[A-Za-z_][A-Za-z0-9_]*$` identifier.
- `file` reads a path. A relative path is confined to the host document's own
  directory; an absolute path is canonicalized before reading. The value is at
  most 64 KiB.
- `literal` carries the secret inline. Use it only for local development or a
  document that a secret manager renders at deploy time.

Credentials are resolved once, at provider acquisition, and passed to the
adapter explicitly. There is no ambient provider-specific environment lookup. A
missing variable, unreadable file, or empty value fails the run with
`credential_unavailable` rather than falling back.

Credentials never belong in a manifest, in PTC-Lisp, in a canonical trace, or
in a committed project file. A safe provider snapshot records model and policy
identity, never the secret.

For local development from a repository checkout, the runtime loads the nearest
`.env` at startup, so an `env` credential can come from there:

```console
cp .env.example .env
chmod 600 .env
# Edit .env and set OPENROUTER_API_KEY to the real key.
```

An already-exported shell variable takes precedence. `.env` is Git-ignored, but
it is still a plaintext local secret; prefer the shell, `direnv`, or a secret
manager where appropriate.

## Provider sources

There are five closed source identifiers. Each one may only be installed into
one environment, and that placement is enforced at assembly:

| `source` | Purpose | Required keys | Environment |
| --- | --- | --- | --- |
| `llm` | Live language model | `model`, `credential` | Workflow only |
| `llm_replay` | Frozen model responses | `fixtures` | Workflow only |
| `mcp` | External tool server | `transport`, `tools` | Mission only |
| `ptc_trace_snapshot` | Canonical trace queries | `directory` | Mission only |
| `ptc_inspection_snapshot` | Private inspection queries | `directory` | Mission only |

Selecting an alias into the wrong environment fails with
`provider_destination_denied`. This is what keeps model authority out of
model-authored mission code.

### Live models

```json
"deepseek": {
  "source": "llm",
  "model": "openrouter:deepseek/deepseek-v4-flash",
  "credential": "openrouter_key",
  "cache": false,
  "params": {"temperature": 0.2, "seed": 42, "max_tokens": 4096},
  "ceilings": {"max_request_bytes": 1000000, "max_response_bytes": 1000000}
}
```

The host fixes the full model identifier, so a manifest's short alias carries no
provider-resolution magic and cannot override its credential. `params` is
optional and closed: `temperature` (0–2), `seed` (a non-negative signed 32-bit
integer), and `max_tokens` (1–1,000,000). Provider support varies, so use
parameters the installed model actually implements.

`cache` is the host's fixed cache policy. A workflow may express a `cache`
preference in its request, but this setting takes precedence. Request and
response ceilings default to 1,000,000 bytes and cannot exceed 1,048,576.

### Recorded models

Evaluation needs a model whose answers do not move between a baseline run and a
candidate run, otherwise a behavioural difference cannot be attributed to the
candidate. A replay source is ordinary configuration rather than a test hook:
the same manifest selects a replay alias or a live one, and nothing about the
application changes between them.

```json
"frozen-model": {
  "source": "llm_replay",
  "fixtures": "evaluation/replay.jsonl",
  "ceilings": {"max_entries": 10000, "max_result_bytes": 1048576}
}
```

The fixture file is JSON Lines. Each entry names the `request_hash` it answers
and carries either one `response` or an ordered `responses` sequence. The
sequence form exists for a request that repeats *identically* — a retry, or a
loop that rebuilds the same prompt. An ordinary multi-turn agent loop does not
need it, because each turn carries the accumulated transcript and therefore
hashes differently.

The hash covers the deterministic encoding of the provider-neutral request the
workflow actually built, before any adapter sees it, so a fixture is not tied to
the vendor that recorded it. The match is exact by construction: a run whose
prompt, messages, or tools differ at all produces a different hash and fails
rather than replaying a response recorded for a different question.

### MCP servers

An MCP installation fixes the transport, the tool mapping, and the effect of
every mapped tool. It accepts 1 to 128 tools.

```json
"workspace": {
  "source": "mcp",
  "transport": {"type": "stdio", "command": "node", "args": ["server.js"]},
  "tools": {
    "read_text_file": {
      "as": "workspace.read",
      "effect": "read",
      "description": "Read one UTF-8 file beneath the granted root.",
      "model_visible": false,
      "error_feedback": "closed"
    },
    "snapshot_info": {
      "as": "workspace.info",
      "effect": "read",
      "model_visible": false,
      "error_feedback": "closed"
    },
    "write_text_file": {
      "as": "workspace.write",
      "effect": "write",
      "description": "Replace one UTF-8 file beneath the granted root.",
      "model_visible": true,
      "error_feedback": "closed"
    }
  },
  "snapshot_identity": {"tool": "snapshot_info", "field": "snapshot_hash"},
  "ceilings": {
    "timeout_ms": 5000,
    "max_catalog_tools": 128,
    "max_result_bytes": 1000000
  }
}
```

Only the public `as` name crosses the capability boundary; the upstream name
stays inside the installation. `effect` is the required operator declaration
`read` or `write`. MCP server annotations such as `readOnlyHint`,
`destructiveHint`, and `idempotentHint` do not change it. A manifest can select
or hide a mapping but cannot change its installed effect.

An installation containing any `write` mapping requires every selecting
manifest to provide an explicit, non-empty `allow` list, even when that
particular selection chooses reads only. This makes adding a write mapping to an
existing installation fail closed for unchanged manifests rather than silently
widening their authority. Omitted `allow` remains a convenience only for
all-read installations. Installation plus explicit selection is standing
authorization; there is no separate per-call approval prompt. `mix ptc.run
--check` reports the selected read and write counts before execution.

The declared effect also controls failure safety. A read transport failure keeps
its provider retry policy. A write failure after dispatch may have begun is
non-retryable and reports `mutation_state: indeterminate` independently from its
specific timeout, protocol, domain, validation, or transport cause.
See [Building agents](building-agents.md#handle-failures-as-policy) for the
retry table.

`model_visible` decides whether the capability appears in model context. It
grants nothing: a granted hidden capability stays callable by exact name, and an
ungranted one stays denied. A manifest may narrow the visible set but never
extend it beyond what the installation marked visible.

`error_feedback` defaults to `closed`. Setting it to `bounded` exposes at most
1,024 bytes of validated text from an MCP `isError` result as untrusted
recoverable error detail, with terminal control characters replaced. Enabling
it trusts the installed server not to place secrets, paths, or stack traces in
that text. Public canonical events stay closed either way.

`snapshot_identity` names one mapped read-only tool and a field in that tool's
result. PtcRunner calls it once during assembly with an empty argument object,
so the tool must require no arguments. The field must hold a lowercase
`sha256:` digest, published as `content_snapshot_hash`. The identity tool need
not be selected into the mission environment; failing to obtain a valid identity
closes provider assembly.

Install it when the server serves content that cannot change during a run, so
the digest identifies exactly the bytes the run could have read. Only the
digest's shape is checked here; nothing verifies that the server is genuinely
immutable. The
[filesystem sample](../../examples/mcp/filesystem/README.md#publishing-the-content-identity)
explains when the field is worth installing, and `repo-analyst.host.json` in the
repository root is a working installation of it.

Ceilings default to a 5,000 ms end-to-end timeout (maximum 300,000), 128
catalog tools, and 1,000,000 result bytes (maximum 1,048,576).

#### Transports

A `stdio` transport launches a local executable:

```json
"transport": {
  "type": "stdio",
  "command": "node",
  "cwd": ".",
  "args": ["../mcp/filesystem/dist/server.js", "--root", "files"],
  "inherit_environment": true,
  "env": {"VENDOR_TOKEN": {"binding": "vendor_token"}},
  "start_timeout_ms": 5000,
  "grace_ms": 250,
  "stderr_bytes": 65536
}
```

`command` is required. A relative `cwd` resolves against the host document.
`env` injects credentials by binding name rather than value, so the secret never
appears in the document. Environment names must be portable identifiers and may
not shadow the compatibility set `HOME`, `LOGNAME`, `PATH`, `SHELL`, `TERM`, or
`USER`. Startup, shutdown grace, and captured stderr are all bounded.

A `streamable_http` transport reaches a remote server:

```json
"transport": {
  "type": "streamable_http",
  "endpoint": "https://mcp.example.com/v1",
  "auth": [
    {"scheme": "bearer", "binding": "vendor_token"},
    {"scheme": "api_key", "binding": "vendor_token", "header": "X-Api-Key"}
  ]
}
```

`auth` accepts at most eight entries. `bearer` and `basic` need only a binding;
`api_key` also names its header. Protocol-owned headers are reserved and
rejected, including `authorization`, `content-type`, `host`,
`content-length`, `connection`, `transfer-encoding`, `proxy-authorization`, and
the `mcp-*` family.

#### OAuth-protected MCP servers

An OAuth installation replaces static `auth` with a host-owned `oauth` block:

```json
"transport": {
  "type": "streamable_http",
  "endpoint": "https://mcp.example.com/v1",
  "oauth": {
    "installation_id": "primary-account",
    "issuer": "https://accounts.example.com",
    "scope_ceiling": ["documents.read", "offline_access"],
    "default_scopes": ["documents.read"],
    "refresh_access": "when_supported",
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
}
```

Authorize a named installation explicitly before provider acquisition:

```console
mix ptc.run ptc.json --host-config ptc-host.json \
  --authorize-mcp workspace
```

The command binds an operating-system-selected loopback port, prints one
authorization URL for you to open, waits for the exact callback, and only then
builds the provider. It never launches a browser. The option composes with
`--check`; the check performs authorization first and reports only the closed
mode `oauth`, never account, issuer, client, scope, redirect, or token details.
Repeat `--authorize-mcp` to authorize multiple named installations.
The CLI store is process-local: the grant and any later `403` scope requirement
exist only for that command invocation, so another invocation must authorize
again. Embeddings may retain state across runs only by supplying their own
secure persistent `MCPOAuth.Store` adapter; PtcRunner does not ship one.

The CLI supports public clients with `token_endpoint_auth_method: "none"` and
an exact `127.0.0.1` or `::1` loopback redirect. `localhost`, fixed callback
ports, confidential clients, and HTTPS callbacks require an embedding
application using `PtcRunner.Kernel.MCPOAuth.Authorization` and an explicit
principal-scoped `PtcRunner.Kernel.MCPOAuth.Context`.

The host pins the exact resource, issuer, client, maximum scopes, refresh
policy, redirect authority, and permitted network origins. The manifest and
MCP server cannot widen them. Pre-registered clients support `none` and
`client_secret_basic`; a confidential secret is resolved just in time and is
not part of the ordinary provider credential barrier. Client ID Metadata
Documents are supported for public clients when the authorization server
advertises them. Dynamic Client Registration (DCR) is deliberately unsupported:
the final MCP profile deprecates it, and providers such as Google use
console-managed pre-registration instead.

PtcRunner requires an explicit, non-empty authorization scope. Challenge
scopes take priority, then Protected Resource Metadata scopes, then installed
`default_scopes`; the result must stay within `scope_ceiling`. If every source
is empty, authorization stops before interaction. This
**MCP-OAUTH-EXPLICIT-SCOPE** policy deliberately tightens MCP's omit-scope
fallback so a stored grant never has unreported authority.

Resource metadata that requires DPoP or contains `signed_metadata` is rejected.
The signed-metadata rejection is a PtcRunner interoperability restriction:
PtcRunner does not verify signed metadata and therefore refuses to consume
unsigned fields beside it. Authorization-server or client metadata requiring
PAR or DPoP is likewise unsupported.

Normal execution never opens an authorization interaction. An absent,
rejected, expired-without-refresh, or indeterminate grant returns
`mcp_authorization_required`. A `401` rejects only the bearer generation
actually sent. A valid `403 insufficient_scope` challenge stores a private
scope requirement for the next explicit authorization in the same store
lifetime. That server response overrides the sent generation's nominal token
scope report. A delayed response is discarded only when a strictly newer token
generation reports every required scope; otherwise the requirement remains.
If either response-driven store transition fails, the current provider reports
a transport failure and retains an equivalent runtime-shared local fence rather
than issuing that authority again. A replacement provider using the same local
store and grant key remains fenced. Retry provider shutdown after the store is
healthy, or install a strictly newer grant containing the complete requirement;
do not treat a failed close as permission to discard the old provider.
These response-driven transitions use a separate bounded cleanup budget, so a
response arriving at the HTTP deadline cannot skip its local fence. The scope
requirement or token rejection persists in a bounded non-owner worker started
with that fence, so a provider-task timeout cannot skip the durable transition
either. A definitive `401` status line stops immediately, even when the
remaining header block is oversized, malformed, or stalled. A `403` stops
after its complete bounded challenge headers, before the body. The HTTP
response callback installs the manager fence before handing a result back
to the bounded provider task, so cancellation cannot open a gap between parsing
the response and fencing its bearer generation. Closing the manager drains
those bounded persistence workers before discarding its local state. A
failed persistence is retained and retried during close; if the retry still
fails, provider shutdown reports a transport error and the runtime keeps the
shared fence. If provider acquisition fails before returning a provider close
handle, a supervised cleanup owner retains the manager and retries bounded
shutdown until persistence succeeds or the manager exits.
An ordinary `403`, or a malformed or unsupported Bearer challenge, is a
non-retryable authentication or authorization result. Only failure to persist
one valid, satisfiable `insufficient_scope` challenge is reported as a
retryable transport failure.
PtcRunner does not
retry the original MCP request in either case. This is
**MCP-AUTH-DEV-001**, a deliberate safety deviation from MCP's recommended
step-up-and-retry behavior: a `tools/call` may be a write and must not be
replayed automatically.

Stdio containment is provided by the optional
[launcher companion](../../ptc_runner_launcher/README.md), which pins a frozen
SHA-256 identity of the executable, separates streams, and bounds cleanup.
Override its location when needed:

```json
"runtime": {"stdio_launcher": "/opt/ptc/bin/ptc-runner-launcher"}
```

The path must be absolute.

### Trace and inspection snapshots

These serve PtcRunner's own evidence back to a mission as query capabilities,
reading an immutable capture rather than live files.

```json
"history": {
  "source": "ptc_trace_snapshot",
  "directory": "traces",
  "ceilings": {"max_source_bytes": 8000000, "max_result_bytes": 1048576}
},
"private-history": {
  "source": "ptc_inspection_snapshot",
  "directory": "inspection",
  "ceilings": {
    "max_files": 1024,
    "max_source_bytes": 64000000,
    "max_result_bytes": 1048576
  }
}
```

Directories resolve against the host document. Acquisition reads and validates
once; later queries use the frozen capture even if the path contents change.
Result ceilings have a floor of 158 bytes, which is the smallest response that
can carry the reserved content hash plus an empty page.

Selecting an inspection snapshot also requires exactly one trace snapshot: the
canonical capture is taken first, and every private artifact is validated
against it. [Manifests and capabilities](manifests-and-capabilities.md#providers-come-from-the-host-not-the-manifest)
lists the derived capability names,
[TraceLog contract](../trace-log-contract.md#query-contract) is normative for
the query contract, and [Running and debugging](running-and-debugging.md) covers
producing the artifacts in the first place.

## Data classes

Every installation carries a data class and a set of classes it accepts:

```json
"vendor": {
  "source": "mcp",
  "data_class": "normal",
  "accepts_data": ["normal"],
  "transport": {"type": "streamable_http", "endpoint": "https://example.com"},
  "tools": {"search": {"as": "vendor.search", "effect": "read"}}
}
```

`data_class` is what the provider *contributes* and defaults to `normal`.
`accepts_data` is what it is *willing to be run alongside* and defaults to
`["normal"]`. Assembly computes the strictest class across every selected
provider and then requires that every one of them accepts it; otherwise the run
fails with `provider_data_class_denied` before anything opens.

The effect is a fail-closed contamination rule. A vendor connector left at the
defaults can never be selected into a run that also touches private inspection
data, because it does not accept `private_inspection`. Two source kinds fix
their class rather than declaring it: `ptc_trace_snapshot` is always `normal`,
and `ptc_inspection_snapshot` is always `private_inspection` while accepting
both. A run whose effective class is `private_inspection` is forced onto the
private event policy.

## Installed ceilings

An optional `limits` block replaces the compiled installed ceilings. The
compiled defaults suit one bounded run; an agent that must work for hours needs
more turns, model calls, and trace events than they allow:

```json
"limits": {
  "run_duration_ms": 86400000,
  "workflow_timeout_ms": 86400000,
  "subordinate_evaluations": 500,
  "workflow_capability_calls": 1000,
  "workflow_capability_calls_per_name": 1000,
  "mission_capability_calls": 8000,
  "mission_capability_calls_per_name": 8000,
  "normal_event_count": 20000,
  "normal_event_bytes": 2000000000
}
```

Every limit name is accepted, each value is a positive integer of at most
2,592,000,000 — thirty days in milliseconds, high enough for a run measured in
days and low enough that a mistyped value fails loading instead of scheduling a
timer nobody will outlive. Any omitted name keeps its compiled default.

Raising a ceiling here does not by itself lengthen any run. The manifest rule is
unchanged: an application may still only request values at or below what is
installed, so a manifest that needs the larger budget must ask for it. Both
documents stay explicit — the host decides the maximum an operator permits, and
the manifest declares what its application needs. See
[Manifests and capabilities](manifests-and-capabilities.md#requested-limits-narrow-host-ceilings)
for the application side and the full limit vocabulary.

The most common reasons a long agent loop stops early are
`subordinate_evaluations` (its turn count), the workflow total and per-name
capability ceilings (its model calls), the mission total and per-name ceilings
(its tool calls), and both the count and byte ceilings for normal events (its
retained trace evidence). Raising `run_duration_ms` alone does not help, because
the binding deadline for one workflow entry is `workflow_timeout_ms`.

## Verify an installation

`--check` assembles and discovers the providers a manifest selects, prints a
safe resolved view, and closes every resource without invoking the workflow or
calling a model:

```console
mix ptc.run examples/kernel-tutorial/02-deepseek-extract/ptc.json \
  --host-config examples/kernel-tutorial/ptc-host.json \
  --check
```

```text
workflow  deepseek  llm  model openrouter:deepseek/deepseek-v4-flash  accepts: normal  snapshot 7a768b7771c97e4975c9b9943acdeb87b725dd325b55e397ed343b6a54ea9de7
```

Each line reports the environment, alias, source, resolved non-secret policy,
accepted data classes, and the provider snapshot hash. That bare-hex
`snapshot_hash` attests the provider-specific non-secret identity projection,
including the effective ceilings present in that projection. It does not
automatically cover the alias, data-class policy, or fields the provider
deliberately excludes. A frozen-content provider also publishes an
algorithm-qualified `content_snapshot_hash` covering only the captured bytes;
the two have deliberately different scopes and are never equal.

Use `--check` in deployment pipelines to catch a missing credential, an
unreachable endpoint, a renamed upstream tool, or a changed server build before
a real run spends model tokens.

## Next steps

- [Manifests and capabilities](manifests-and-capabilities.md) — the application
  half: selecting installed aliases, narrowing them, and requesting limits.
- [Building agents](building-agents.md) — how workflow policy uses the model
  capability these aliases install.
- [Running and debugging](running-and-debugging.md) — running a manifest
  against this document and reading what came out.

Exact field and failure contracts live in the `PtcRunner.Kernel.HostConfig` and
`PtcRunner.Kernel.HostInstallation` module documentation. The
[Kernel maintainer guide](kernel-maintainer.md) describes provider ownership and
lifecycle.
