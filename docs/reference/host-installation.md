# Host-configuration reference

> **Audience:** operators who need the complete installed-provider, credential,
> transport, data-class, and outer-policy contract.

The host document is the operator-owned half of a PtcRunner deployment. This
strict JSON file installs provider aliases, credentials, data classes, and
outer limits separately from the application manifest:

```console
ptc run MANIFEST --host-config ptc-host.json
```

A manifest may select and narrow an installed alias. It cannot add a provider,
change an endpoint or executable, supply a credential, or raise a ceiling. A
provider-bearing manifest requires `--host-config`; a provider-free manifest
does not.

For a checkout used repeatedly, store the host and optional environment-file
references in the separate operator-owned
[project configuration](project-files.md):

```console
ptc run ptc-project.json
ptc doctor ptc-project.json --connect
```

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
      "installation_revision": "filesystem-sample-0.2.0",
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
rejected. Use `ptc docs schema-host`
(`priv/schemas/ptc-host-config.schema.json` in the repository) for the complete
structural vocabulary, defaults, bounds, and editor completion. Runtime
validation remains authoritative for semantic checks.

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

`ptc` and `mix ptc` accept `--env-file FILE` on `run`, active `doctor`, and
manifest-backed `repl`. When a selected LLM uses an `env` credential, the
frontend loads that exact file before provider activity; it never searches for
one. Every imported value persists for the process lifetime, and an existing
process value wins. Embedded hosts load no dotenv file implicitly.

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

### Live models

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

Set `params.max_tokens` explicitly when the installation needs a particular
output budget. For catalog-backed models that omit it, PtcRunner's built-in
ReqLLM adapter caps the default at 4096 tokens, the cataloged model output
limit, and a conservative remainder of the context window after the request.
This avoids turning a model's full context-window ceiling into an impossible
output request once the prompt is included. The tutorial keeps the value
explicit so changing only its model selector retains a bounded request.

The built-in adapter prepares the selected model once before constructing its
requester. A selector absent from the bundled model catalog remains usable when
ReqLLM supports its provider, but PtcRunner emits one `model_uncataloged`
warning for that requester. Catalog metadata such as pricing, limits, token
estimation, and capability detection may then be incomplete; the warning does
not mean the provider request itself is known to fail.

Model selectors are provider-qualified strings. These are the provider paths
PtcRunner configures and exercises directly:

| Prefix | Example selector | Credential binding normally backed by |
| --- | --- | --- |
| `openrouter:` | `openrouter:deepseek/deepseek-v4-flash` | `OPENROUTER_API_KEY` |
| `anthropic:` | `anthropic:claude-sonnet-4-6` | `ANTHROPIC_API_KEY` |
| `openai:` | `openai:gpt-5-mini` | `OPENAI_API_KEY` |
| `google:` | `google:gemini-2.5-flash` | `GOOGLE_API_KEY` |
| `groq:` | `groq:openai/gpt-oss-20b` | `GROQ_API_KEY` |
| `amazon_bedrock:` | `amazon_bedrock:anthropic.claude-sonnet-4-5-20250929-v1:0` | AWS credentials |

The examples are release-catalog examples, not promises that a provider still
serves an alias. A requester emits `model_uncataloged` when its selector misses
the bundled catalog; `ptc doctor PROJECT --connect --show-model-selectors`
tests the selected provider and includes selectors that are safe to disclose.
Direct Anthropic selectors, Anthropic models through OpenRouter, and Claude
models on Bedrock support the adapter's prompt-cache policy when the
installation sets `"cache": true`.

Agent loops and other requests that give the model callable tools require a
model endpoint with tool-calling support. A model may work for an ordinary
completion while refusing that tool-bearing request; the run then reports
`llm_tool_calling_unsupported` rather than claiming the configured model is
missing.

The manifest selects only `deepseek`; it cannot change any field above. When
the adapter attests that the resolved model is safe public identity, provider
snapshots and model-grouped usage include it. Endpoint-bearing or otherwise
private targets remain absent, while alias/revision usage stays attributable.

Use `source: "llm_replay"` when responses must be deterministic. The
[replay evaluation guide](../guides/evaluating-with-replay.md) owns fixture authoring, the
network-free example, candidate materialization, and component overrides.

`doctor --connect` performs a real minimal completion for each selected live
model and may incur provider cost; the readiness report's `usage` field
attributes what each probe spent, on the rows a run reports. `--show-model-selectors` adds only safe
selectors; endpoint-bearing `openai-compat:` selectors remain hidden. `ptc
models` reports the same `model_selector` field under the same rule, without a
flag and without reading the application.

### Resolve local transport paths

Stdio `cwd` and relative command arguments resolve from the host document, not
from PtcRunner's source checkout and not from the shell's current directory.
For an application in a separate repository, keep its MCP server bundle in
that repository (for example `tools/files/server.js`) and use a host-relative
path, or install the server executable at a stable absolute location. A
cross-repository `../ptc_runner/examples/...` path is useful for local
experimentation but does not make the application independently cloneable.

The self-contained PtcRunner release does not include the repository's example
MCP bundles. Copy or package any selected example server with the application,
including any runtime that server requires.

### MCP servers

An MCP installation fixes its stdio or streamable-HTTP transport and maps
upstream tool names to stable public capability names with operator-declared
read/write effects. A manifest selects and narrows that mapping but cannot
change its executable, endpoint, credentials, or effect declarations.

[Connecting tools with MCP](mcp.md) owns the complete
task-shaped setup, including tool mapping, prompt-visible facades, transport
bindings, OAuth authorization, immutable snapshot identity, and the runnable
filesystem example.

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
shapes and bounds; [Kernel REPL](repl.md) shows them in use.

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

The generated [Kernel limits reference](../kernel-limits-reference.md) is the
complete table of names, meanings, units, scopes, defaults, accepted ranges,
and identity participation. The host schema is generated from the same
catalog.

## Verify selected providers

Run active local, credential, authorization, and connectivity checks without
invoking the workflow:

```console
ptc init kernel-tutorial --example kernel-tutorial
ptc doctor kernel-tutorial/02-deepseek-extract.ptc-project.json --connect
```

`readiness` is `ready` only after successful active checks. Plain doctor is
`unverified`; a failed active check is `failed` and exits nonzero. The report
does not expose endpoints, commands, paths, credentials, or OAuth authority.

## Next steps

- [Manifests and capabilities](application-manifest.md) selects and
  narrows these aliases.
- [Building agents](../guides/building-agents.md) uses the installed model and mission
  capabilities.
- [Running and debugging](cli.md) runs and inspects the
  application.
- [Connecting tools with MCP](mcp.md) installs external
  tools without putting transport authority in a manifest.
- [Evaluating with replay](../guides/evaluating-with-replay.md) fixes model responses for
  deterministic comparisons.
