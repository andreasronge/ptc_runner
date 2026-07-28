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

`installation_revision` is a free-form operator string, at most 256 characters.
It records which build of a server or model policy an alias represents so that
traces from different installations remain distinguishable.

The canonical structural description is shipped as
`priv/schemas/ptc-host-config.schema.json` for editor completion. Runtime
decoding stays authoritative for semantic checks such as unique public tool
names, credential references, reserved headers, and portable environment names.

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
    }
  },
  "snapshot_identity": {"tool": "snapshot_hash", "field": "digest"},
  "ceilings": {
    "timeout_ms": 5000,
    "max_catalog_tools": 128,
    "max_result_bytes": 1000000
  }
}
```

Only the public `as` name crosses the capability boundary; the upstream name
stays inside the installation. `effect` is currently always `read`. Declaring it
is what lets the agent loop retry after a resource kill that followed a
capability call; an undeclared or writing effect is treated as unsafe to repeat.
See [Building agents](building-agents.md#handle-failures-as-policy) for the
retry table.

`model_visible` decides whether the capability appears in model context. It
grants nothing: a granted hidden capability stays callable by exact name, and an
ungranted one stays denied. A manifest may narrow the visible set but never
extend it beyond what the installation marked visible.

`error_feedback` defaults to `closed`. Setting it to `bounded` exposes at most
1,024 bytes of exact validated text from an MCP `isError` result as untrusted
recoverable error detail. Enabling it trusts the installed server not to place
secrets, paths, or stack traces in that text. Public canonical events stay
closed either way.

`snapshot_identity` names one mapped read-only tool and a result field.
PtcRunner calls it once during assembly with an empty argument object, validates
the field as a lowercase `sha256:` digest, and publishes it as
`content_snapshot_hash`. The identity tool need not be selected into the mission
environment; failing to obtain a valid identity closes provider assembly.

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
against it. [Manifests and capabilities](manifests-and-capabilities.md#providers-are-installed-authority)
documents the derived capability names and the query contract, and
[Running and debugging](running-and-debugging.md) covers producing the
artifacts in the first place.

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
`snapshot_hash` attests the complete installed provider identity, including its
policy and ceilings. A frozen-content provider also publishes an
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
