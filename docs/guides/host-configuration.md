# Host configuration

The host document is the operator-owned half of a PtcRunner deployment. This
strict JSON file installs provider aliases, credentials, data classes, and
outer limits separately from the application manifest:

```console
mix ptc run MANIFEST --host-config ptc-host.json
```

A manifest may select and narrow an installed alias. It cannot add a provider,
change an endpoint or executable, supply a credential, or raise a ceiling. A
provider-bearing manifest requires `--host-config`; a provider-free manifest
does not.

Loading validates bounded, path-confined JSON without reading credentials,
resolving executables, starting processes, or contacting endpoints. Those
actions happen later during preflight and acquisition.

## Start with a small document

```json
{
  "credentials": {
    "openrouter_key": {"env": "OPENROUTER_API_KEY"}
  },
  "install": {
    "deepseek": {
      "source": "llm",
      "installation_revision": "deepseek-policy-v1",
      "model": "openrouter:deepseek/deepseek-v4-flash",
      "credential": "openrouter_key",
      "cache": false
    },
    "workspace": {
      "source": "mcp",
      "installation_revision": "filesystem-sample-0.1.0",
      "transport": {
        "type": "stdio",
        "command": "node",
        "args": ["server.js"]
      },
      "tools": {
        "read_text_file": {"as": "workspace.read", "effect": "read"}
      }
    }
  }
}
```

Only `install` is required. The other top-level keys are `$schema`,
`credentials`, `limits`, and `runtime`; unknown and duplicate keys are
rejected. Use `priv/schemas/ptc-host-config.schema.json` for the complete
structural vocabulary, defaults, bounds, and editor completion. Semantic
checks remain authoritative in `PtcRunner.Kernel.HostConfig`.

Every installation needs a public, non-secret `installation_revision`. Change
it whenever installed behavior or authority changes, including model routing,
MCP mappings and effects, replay fixtures, snapshot policy, or adapter and
launcher builds.

## Declare credentials once

Credentials have exactly one source:

```json
"credentials": {
  "openrouter_key": {"env": "OPENROUTER_API_KEY"},
  "vendor_token": {"file": "secrets/vendor.token"},
  "development_key": {"literal": "not-a-real-key"}
}
```

- `env` reads a portable environment variable during acquisition.
- `file` reads at most 64 KiB. Relative paths stay beneath the host document's
  directory; absolute paths are canonicalized.
- `literal` embeds the secret. Reserve it for local development or documents
  rendered by a secret manager.

Credentials are resolved once and passed explicitly to the provider. A
missing, empty, or unreadable value fails with `credential_unavailable`; there
is no ambient provider-specific fallback. Never put credentials in a manifest,
PTC-Lisp, canonical traces, or committed files.

`mix ptc` and `bin/ptc` accept `--env-file FILE` on `run`, active `doctor`, and
manifest-backed `repl`. When a selected LLM uses an `env` credential, the
frontend loads that exact file before provider activity; it never searches for
one. Every imported value persists for the process lifetime, and an existing
process value wins. Embedded hosts load no dotenv file implicitly. See
`PtcRunner.Dotenv` for the exact contract.

## Choose a provider source

The source set and placement are closed:

| `source` | Purpose | Environment |
| --- | --- | --- |
| `llm` | Live language model | Workflow |
| `llm_replay` | Frozen model responses | Workflow |
| `mcp` | External tool server | Mission |
| `ptc_trace_snapshot` | Public canonical trace queries | Mission |
| `ptc_private_trace_snapshot` | Private-authorized canonical trace queries | Mission |
| `ptc_inspection_snapshot` | Private inspection queries | Mission |

Selecting an alias into the wrong environment fails with
`provider_destination_denied`. This keeps model authority out of
model-authored mission code.

### Live and replay models

A live installation fixes the full model selector, credential, cache policy,
optional request parameters, and request/response ceilings:

```json
"deepseek": {
  "source": "llm",
  "installation_revision": "deepseek-policy-v1",
  "model": "openrouter:deepseek/deepseek-v4-flash",
  "credential": "openrouter_key",
  "cache": false,
  "params": {"temperature": 0.2, "seed": 42, "max_tokens": 4096}
}
```

The manifest selects only `deepseek`; it cannot change any field above. When
the adapter attests that the resolved model is safe public identity, provider
snapshots and model-grouped usage include it. Endpoint-bearing or otherwise
private targets remain absent, while alias/revision usage stays attributable.

Use replay when model responses must be deterministic:

```json
"frozen-model": {
  "source": "llm_replay",
  "installation_revision": "frozen-model-v1",
  "fixtures": "evaluation/replay.jsonl"
}
```

The JSON Lines fixture maps the deterministic provider-neutral request hash to
one `response` or an ordered `responses` sequence. Matching is exact; changed
messages or tools produce a different hash and fail instead of using unrelated
evidence. See `PtcRunner.Kernel.LLMReplay` for the fixture contract.

Plain `doctor` parses the selected fixture file under its installed ceilings
without starting the replay provider. A missing, empty, malformed, duplicate,
or oversized fixture set therefore fails `provider/<alias>/local` as
`fixtures_unreadable` before a run reaches acquisition.

`doctor --connect` performs a real minimal completion for each selected live
model and may incur provider cost. `--show-model-selectors` adds only safe
selectors; endpoint-bearing `openai-compat:` selectors remain hidden.

### MCP servers

An MCP installation fixes its transport and maps upstream tool names to public
capability names:

```json
"workspace": {
  "source": "mcp",
  "installation_revision": "workspace-v1",
  "transport": {"type": "stdio", "command": "node", "args": ["server.js"]},
  "tools": {
    "read_text_file": {
      "as": "workspace.read",
      "effect": "read",
      "description": "Read one UTF-8 file beneath the granted root.",
      "model_visible": true,
      "error_feedback": "closed"
    },
    "write_text_file": {
      "as": "workspace.write",
      "effect": "write",
      "model_visible": false
    }
  }
}
```

The required `effect` is the operator's `read` or `write` declaration. Server
annotations do not change it. If any installed mapping is a write, every
selecting manifest must provide a non-empty `allow` list, even when it selects
only reads. This makes authority changes fail closed. A dispatched write that
fails is not retried automatically and may report
`mutation_state: indeterminate`; see
[Building agents](building-agents.md#handle-failures-without-repeating-effects).

`model_visible` controls discovery, not authority. `error_feedback: "bounded"`
may expose up to 1,024 bytes of validated MCP error text as untrusted feedback;
enable it only when the server will not return secrets, paths, or stack traces.
Canonical events remain closed.

For immutable content, `snapshot_identity` may name an installed read tool and
a result field containing a lowercase `sha256:` digest. PtcRunner calls that
tool once with an empty object during assembly and publishes the digest as
`content_snapshot_hash`. PtcRunner checks the shape, not whether the server is
truly immutable. The
[filesystem sample](../../examples/mcp/filesystem/README.md#publishing-the-content-identity)
shows a working installation.

#### Transports

Stdio launches one local process:

```json
"transport": {
  "type": "stdio",
  "command": "node",
  "cwd": ".",
  "args": ["server.js"],
  "inherit_environment": true,
  "env": {"VENDOR_TOKEN": {"binding": "vendor_token"}}
}
```

Relative `cwd` resolves against the host document. Credential values enter
through bindings rather than JSON. The child always receives
`LC_ALL=C.UTF-8`; credential bindings cannot shadow runtime compatibility
variables. Startup, shutdown grace, stderr capture, and results are bounded.
Plain `doctor` resolves the selected command without launching it; an absent
executable fails `provider/<alias>/local` as `command_not_found` while the rest
of the readiness report remains available. A path that exists but is not a
regular executable, is unreadable, or exceeds the executable ceiling instead
fails that row as `executable_unavailable`.
The optional [launcher companion](../../ptc_runner_launcher/README.md) adds
executable identity and stronger stdio containment; select it with an absolute
`runtime.stdio_launcher` path.

Streamable HTTP names a remote endpoint and optional static authentication:

```json
"transport": {
  "type": "streamable_http",
  "endpoint": "https://mcp.example.com/v1",
  "auth": [{"scheme": "bearer", "binding": "vendor_token"}]
}
```

Supported schemes are `bearer`, `basic`, and header-named `api_key`. Protocol
headers, including `authorization`, `content-type`, `host`, and `mcp-*`, cannot
be supplied as API-key headers. The schema contains the complete transport
shape and bounds.

#### OAuth-protected HTTP

OAuth replaces static `auth` with a host-owned `oauth` policy that pins the
resource, issuer, client, scope ceiling, refresh policy, loopback authority,
and permitted network origins. The manifest and server cannot widen them.

First authorization is interactive and Mix-only:

```console
mix ptc run ptc.json --host-config ptc-host.json \
  --authorize-mcp workspace
```

The command prints a URL and waits on an operating-system-selected loopback
port; it does not open a browser. Authorization applies only to that command.
The shipped CLI store is process-local, so a later invocation must authorize
again. Embeddings may provide a secure principal-scoped store.

Normal execution never starts an authorization interaction. Missing or
insufficient authority fails closed. PtcRunner also never retries the original
MCP request after a `401` or `403`, because `tools/call` may have performed a
write. The CLI accepts public pre-registered clients using loopback
`127.0.0.1` or `::1`; confidential clients and other redirect policies require
an embedding. Dynamic Client Registration, DPoP, and signed authorization
metadata are unsupported.

See `PtcRunner.Kernel.MCPOAuth.Authority` for the exact host shape and
`PtcRunner.Kernel.MCPOAuth.Authorization` for scope selection, challenge, and
token lifecycle rules.

### Trace and inspection snapshots

Native snapshot installations expose bounded run-evidence navigation over
immutable captures:

```json
"history": {
  "source": "ptc_private_trace_snapshot",
  "installation_revision": "history-v1",
  "directory": "traces"
},
"private-history": {
  "source": "ptc_inspection_snapshot",
  "installation_revision": "private-history-v1",
  "directory": "inspection"
}
```

Directories resolve against the host document and are captured once.
`ptc_trace_snapshot` reads ordinary traces.
`ptc_private_trace_snapshot` reads ordinary and `.private.jsonl` traces and
classifies the run as `private_inspection`. An inspection snapshot requires
exactly one of those trace sources so it can validate every private artifact
against the captured canonical evidence.

Set a trace selection's manifest config to `{"expose": false}` when it exists
only as the inspection source's dependency. It still supplies the frozen trace
capture without creating a second analysis namespace. The
[TraceLog contract](../trace-log-contract.md#query-contract) defines query
shapes and bounds; [Kernel REPL](kernel-repl.md) shows them in use.

## Keep data classes compatible

`data_class` says what an installation contributes; `accepts_data` says which
effective classes it may run beside. Both default to `normal` and
`["normal"]`:

```json
"data_class": "normal",
"accepts_data": ["normal"]
```

Assembly computes the strictest selected class and requires every provider to
accept it before any provider opens. Private trace and inspection sources fix
their class to `private_inspection`, and such a run is forced onto the private
event policy. This prevents a normal vendor connector from silently receiving
or running beside private inspection data.

## Set installed ceilings

The optional `limits` object sets maximums the manifest may narrow:

```json
"limits": {
  "run_duration_ms": 86400000,
  "workflow_timeout_ms": 86400000,
  "subordinate_evaluations": 500,
  "workflow_capability_calls": 1000,
  "mission_capability_calls": 8000,
  "normal_event_count": 20000
}
```

Raising `run_duration_ms` alone rarely lengthens an agent loop. Check the
workflow timeout, model-call and mission-call quotas, subordinate evaluations,
parallel timeout, and event count/byte ceilings too. Source checks have their
own quota and do not execute code.

Four timeouts are host-only: `provider_cleanup_timeout_ms`,
`local_preflight_timeout_ms`, `selection_validation_timeout_ms`, and
`doctor_connectivity_timeout_ms`. A manifest cannot declare them.

`PtcRunner.Kernel.LimitCatalog` is the complete canonical table of names,
scopes, defaults, accepted ranges, and identity participation.
`PtcRunner.Kernel.Limits` explains what each limit bounds. The host schema is
generated from that catalog.

## Verify selected providers

Run active local, credential, authorization, and connectivity checks without
invoking the workflow:

```console
mix ptc doctor examples/kernel-tutorial/02-deepseek-extract/ptc.json \
  --host-config examples/kernel-tutorial/ptc-host.json \
  --connect
```

`readiness` is `ready` only after successful active checks. Plain doctor is
`unverified`; a failed active check is `failed` and exits nonzero. The report
does not expose endpoints, commands, paths, credentials, or OAuth authority.

## Next steps

- [Manifests and capabilities](manifests-and-capabilities.md) selects and
  narrows these aliases.
- [Building agents](building-agents.md) uses the installed model and mission
  capabilities.
- [Running and debugging](running-and-debugging.md) runs and inspects the
  application.

Exact host field and acquisition contracts live in
`PtcRunner.Kernel.HostConfig` and `PtcRunner.Kernel.HostInstallation`.
