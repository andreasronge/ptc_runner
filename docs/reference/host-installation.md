# Host-configuration reference

This is the complete contract for installed providers, credentials, transports,
data classes, and outer limits.

The strict `ptc-host.json` file keeps them
separate from the application manifest:

```console
ptc run MANIFEST --host-config ptc-host.json
```

A manifest may select an installed alias and ask for less. It cannot add a provider,
change an endpoint or executable, supply a credential, or raise a ceiling. A
provider-bearing manifest requires `--host-config`; a manifest with no providers
does not.

For a checkout used repeatedly, store the host and optional environment-file
references in the separate
[project configuration](project-files.md):

```console
ptc run ptc-project.json
ptc doctor ptc-project.json --connect
```

Loading validates bounded, path-confined JSON without reading credentials,
resolving executables, starting processes, or contacting endpoints. Those
actions happen later during preflight and acquisition.

A host schema diagnostic names the bounded rule that failed and includes a
safe JSON Pointer. Installation aliases and other caller-selected map keys are
rendered as `*`; unknown keys and rejected values are never copied into the
diagnostic. For example, an excessive installation timeout is located at
`/install/*/ceilings/timeout_ms` and classified as a `maximum` rule failure.

## Start with a small document

```json
{
  "credentials": {
    "openrouter_key": {"env": "OPENROUTER_API_KEY"}
  },
  "install": {
    "deepseek": {
      "source": "llm",
      "structured_output_mode": "unsupported",
      "usage_guarantees": {"tokens": true, "cost_currency": "USD"},
      "installation_revision": "deepseek-policy-v1",
      "model": "openrouter:deepseek/deepseek-v4-flash",
      "credential": "openrouter_key",
      "cache": false
    },
    "workspace": {
      "source": "mcp",
      "installation_revision": "workspace-v1",
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

`installation_config_digest` is computed evidence for that same declaration. It
hashes the normalized `install.<alias>` configuration after ordinary host
decoding, with a distinct TJCS domain from application identity. Set-valued
declaration fields such as `accepts_data` and OAuth `redirect_uris` are ordered
canonically before hashing, so reversing them is not configuration drift;
ordered lists such as transport `args` keep their written sequence. Matching
digests mean the same declared installation was selected. They do not prove
that a local process, remote endpoint, credential, filesystem path, or server
still grants the same effective authority.

The digest is a sibling of `application_content_digest` and
`effective_application_digest`. Host configuration stays out of those
application hashes. `ptc validate` prints `installation_config_digests` for
aliases selected by the effective application, without contacting providers.
The same selected map is recorded on `run-started`, and each connector snapshot
carries the singular digest used while loading the host document.

Documented meaning by source:

- MCP stdio: the same normalized command and configuration declaration, not
  the resolved executable, working-directory target, symlink target, ambient
  environment, or server-enforced scope.
- MCP streamable HTTP: the same declared endpoint, authentication policy, tool
  mappings, and limits; not the server implementation behind the URL.
- LLM: the same declared model, parameters, limits, and credential binding
  name; not the secret value, account permissions, or provider behavior.
- Snapshot, replay, and other file-backed sources: the same declared path and
  provider configuration; not the current file contents unless a separate
  content hash attests them.

Paths are hashed as written after ordinary configuration normalization. The
digest does not expand them against the current directory, resolve symlinks, or
bake machine-local real paths. Changing `installation_revision` alone leaves
the digest stable; changing the declaration without bumping the revision still
changes the digest. Rotating a credential value does not change it; renaming
the binding does. Compare identifiers, not confidentiality: the digest never
includes secrets.

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
PTC-Lisp, traces, or committed files.

With `doctor --connect`, an LLM endpoint that answers by rejecting the supplied
credential fails the provider's credentials check with
`authentication_rejected`. Its connectivity check passes because the HTTP
response proves the endpoint was reached. Transport failures, timeouts, and
invalid or unavailable provider responses continue to fail connectivity.

Surrounding whitespace is not part of a secret and is trimmed from every
source, so `gh auth token > vendor.token` and an editor that adds a trailing
newline both work. Interior structure is preserved: a PEM block or a JSON
service-account key is one credential, and `transport.env` hands it to the
child process whole. An HTTP header cannot carry a newline, so a credential
bound to `transport.auth` that still holds one after trimming reports
`authentication_rejected` — the same class the endpoint's own refusal
reports — rather than an internal fault.

`ptc` and `mix ptc` accept `--env-file FILE` on `run`, active `doctor`, and
manifest-backed `repl`. When any selected installation binds an `env`
credential — an LLM through `credential`, or an MCP transport through
`transport.env` or `transport.auth` — the frontend loads that exact file before
provider activity; it never searches for one. When loaded, every key assigned
in the file overrides its process value, including when the assignment is
empty; keys omitted from the file retain their process values. Embedded hosts
load no dotenv file implicitly.

## Choose a provider source

The source set and placement are closed:

| `source` | Purpose | Environment |
| --- | --- | --- |
| `llm` | Live language model | Workflow |
| `llm_replay` | Frozen model responses | Workflow |
| `mcp` | External tool server | Mission |
| `ptc_trace_snapshot` | Trace queries | Mission |
| `ptc_private_trace_snapshot` | Trace queries joined with authorized private records | Mission |
| `ptc_inspection_snapshot` | Private inspection queries | Mission |

Selecting an alias into the wrong environment fails with
`provider_destination_denied`. This keeps model authority out of
model-authored mission code.

### Live models

A live installation fixes the full model selector, credential, cache policy,
optional request parameters, and request/response ceilings. `ceilings.max_calls`
optionally caps how many times that alias may be invoked. Omitted, it defaults
to the catalog installed default for `workflow_capability_calls_per_name`
(2048), independent of the host `limits` block; a larger value could never
bind and is refused at load. The application may narrow it
with `config.max_calls`; asking above the host ceiling is refused rather than
clamped. When that selected cap is at or above the run's per-name
`llm-request` budget, the public per-name quota still binds first.

`ceilings.request_timeout_ms` is the selected installation's whole-call
deadline. Omitted, it defaults to 120000 ms, clamped by the host
`limits.llm_request_timeout_ms` ceiling (also 120000 unless the host document
widens or narrows it). The accepted range is 100 through that host ceiling.
Applications may only narrow `limits.llm_request_timeout_ms`; they cannot raise
the installation ceiling. Changing `ceilings.request_timeout_ms` requires a new
`installation_revision`. Dispatcher samples one absolute deadline immediately
before admission and enforces it through the provider worker and structured
output validation. When that LLM clock wins over the enclosing run or workflow
clocks, the public result is retryable `timeout/llm_request_timeout`. Replay
installations do not carry this deadline.

```json
"deepseek": {
  "source": "llm",
  "structured_output_mode": "unsupported",
  "usage_guarantees": {"tokens": true, "cost_currency": "USD"},
  "installation_revision": "deepseek-policy-v1",
  "model": "openrouter:deepseek/deepseek-v4-flash",
  "credential": "openrouter_key",
  "cache": false,
  "params": {
    "temperature": 0.2,
    "seed": 42,
    "max_tokens": 4096,
    "top_p": 0.9,
    "presence_penalty": 0.0,
    "frequency_penalty": 0.0,
    "reasoning_effort": "medium"
  }
}
```

`params` is a closed installation-owned map. Except for `max_tokens`, omitted
fields use the selected adapter/model default; an `llm/request` cannot add or
replace them. The Kernel always supplies its effective output-token limit as
`max_tokens`, bounded by an installed value when one is present.

| Field | Accepted value |
| --- | --- |
| `temperature` | number from 0.0 through 2.0 |
| `seed` | integer from 0 through 2147483647 |
| `max_tokens` | integer from 1 through 1000000 |
| `top_p` | number greater than 0.0 and at most 1.0 |
| `presence_penalty` | number from -2.0 through 2.0 |
| `frequency_penalty` | number from -2.0 through 2.0 |
| `reasoning_effort` | `none`, `minimal`, `low`, `medium`, or `high` |

These normalized controls are part of installation identity and the
installation configuration digest. Change `installation_revision` whenever
they change. Provider option maps, stop payloads, reasoning token budgets, and
the `xhigh` and `max` reasoning levels are not admitted.

Set `params.max_tokens` explicitly when the installation needs a narrower
output budget than the effective Kernel limit. The tutorial keeps the value
explicit so changing only its model selector retains the same request contract.

The built-in adapter prepares the selected model once before constructing its
requester. A selector absent from the bundled model catalog remains usable when
ReqLLM supports its provider unless `llm_cost_microusd` requires reservation
rates the catalog cannot supply. PtcRunner emits one `model_uncataloged` warning
for that requester or refusal. Catalog metadata such as pricing, limits, token
estimation, and capability detection may then be incomplete; the warning alone
does not mean the provider request is known to fail. Run envelopes V4 publish
the same fact in their closed `warnings` array, and canonical `run-started`
metadata retains it for trace consumers. Failed plain-doctor envelopes publish
the same locally derived warning for each affected provider check without
claiming provider activity; stderr remains the human presentation.

Preparation seals the exact controls into the target and requires the adapter
to attest the same canonical map. The built-in adapter uses ReqLLM's strict
unsupported-option policy and also refuses known lossy routes during local
preflight, before credential loading. For example, Anthropic cannot combine
`temperature` with `top_p` or accept OpenAI-style presence/frequency penalties;
several provider families translate reasoning effort to a fixed level or token
budget; and Ollama's direct route admits `temperature`, `seed`, and `top_p` but
not the two penalties or reasoning effort. The direct `openai-compat:` route
transmits the complete admitted set. OpenRouter does the same for positive
seeds; seed zero is refused because ReqLLM's current option boundary cannot
encode it. A refused combination reports
`local_preflight/model_contract_unsupported` without publishing the option
value or contacting the provider.

Every live model installation must declare `structured_output_mode` as
`json_schema`, `json_object`, or `unsupported`. `json_schema` asks the provider
to enforce the request schema with its native schema mechanism and is refused
at prepare when the adapter can only fall back to a synthetic tool.
`json_object` asks the provider only for a JSON object, then the Kernel
decodes and validates it. It is refused at prepare unless the adapter can send
that provider's actual JSON-object control: OpenAI-style `response_format`
`json_object` on OpenRouter, OpenAI, Groq, Fireworks, xAI, Azure OpenAI, and
Vertex OpenAI-compatible MaaS. Anthropic, Bedrock, Google AI Studio, Vertex
Claude/Gemini, and Azure Claude have no such control and stay `unsupported` or
`json_schema`. Direct `ollama:` and `openai-compat:` selectors are refused for
both structured modes. `unsupported` refuses a request `schema` before dispatch.
Changing the mode requires a new `installation_revision`. A schema
together with a non-empty `tools` list is invalid. Success is a
`structured_output` object; encoded `content` is not duplicated.

### Usage guarantees

Every live model installation also declares the exact closed
`usage_guarantees` object. `tokens: true` promises that every dispatched
successful call reports non-negative `input` and `output` counts;
`cost_currency: "USD"` additionally promises a total USD cost. `false` and
`null` declare those observations optional, not zero. Preparation seals and
attests the declaration, and a successful response or doctor connectivity
probe that omits promised usage fails as non-retryable
`llm_usage_unavailable`. Changing either guarantee requires a new
`installation_revision`. Token and cost guarantees are independent: a
cost-only installation retains an authoritative provider charge even when the
provider omits one or both token counts.

Provider cost numbers and decimal strings, including OpenRouter's reported
`usage.cost`, are converted immediately to
`{"currency":"USD","microunits":N}` by exact decimal parsing, with fractions
rounded upward to one millionth of a dollar. The bounded integer `N` is in
`0..9_007_199_254_740_991`; binary floating-point values are not retained as
accounting authority.

If the host enables `llm_total_tokens` or `llm_cost_microusd`, each live call
must obtain a bounded, request-specific reservation attestation from the
prepared adapter before admission, and every live installation must declare
`usage_guarantees.tokens: true`. A cost budget additionally requires
`usage_guarantees.cost_currency: "USD"` and an explicit
`reservation_tariff: {"currency":"USD","id":"..."}`. Cost reservations bind
to that prepared tariff identity, but its `id` does not supply model rates;
supported USD reservation pricing for the selected model must also be
available. Tariff details remain private. A token reservation must be at least
the request's authorized output-token ceiling.
Attestation performs no credential lookup or remote work. An absent, crashing,
timed-out, undersized, or otherwise malformed attestation refuses the call
before provider dispatch. Provider errors and
successful calls without valid promised usage conservatively charge the full
reservation and mark the affected ledger incomplete; authenticated usage above
the bound charges the actual value, marks overrun, and prevents later calls.
Replay installations are excluded from these operational ledgers. A reservation
that does not fit remains a recoverable `limit_exceeded` envelope until the
workflow aborts it; aborting the authenticated envelope reports
`execution/runtime_limit_exceeded` naming the refused reservation, distinct
from realized overspend.

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

A fixture file is JSON Lines. Every line sets `schema_version` to `1`, a
`request_hash` computed from the provider-neutral request, and exactly one of
`response` or an ordered `responses` list for a request the workflow makes
more than once. Plain `doctor` and `validate` parse the selected file under
the installed ceilings without starting the provider, so a manifest and host
document that validate cannot fail on the fixture when `run` reaches it. A
missing, empty, malformed, duplicate, or oversized fixture set fails the
local provider check as `fixtures_unreadable`; the message names the rule the
file broke and, for a line-level rejection, the line number counted with
blank lines. Nothing the line contains is published. The other local checks
(an installed model's adapter, an MCP server's executable) stay out of
`validate`.

Fixture matching is exact: changed messages, tools, schema, or provider-neutral
parameters produce another `request_hash` rather than silently consuming
unrelated evidence. A structured-output fixture uses the public
`structured_output` object rather than encoded `content`. A miss is a provider
error with `:kind :provider_error` and `:reason :not_found`, and `llm/request`
returns that envelope as a value with
`:status :error` rather than failing the evaluation, so a workflow that wants a
miss to be fatal calls `cap/unwrap!` on the raw `tool/llm-request` envelope. The
run envelope records the miss in usage: that alias's `successful_calls` stays 0
while `calls` increments, and `capability_refusals` records
`workflow/provider_error/not_found`.

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
upstream tool names to stable public capability names with host-declared
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
against the captured trace evidence.

Whole-directory trace snapshots admit filename-bound `<run-id>.jsonl` or
`<run-id>.private.jsonl` members containing exactly one matching run and trace
identity. Stable malformed, mismatched, split, or conflicting members are
isolated by connected identity component while disjoint valid runs remain
queryable. Selected namespace mutation rejects the complete capture; it never
installs a partial snapshot. Explicit single-file trace sources remain a
separate filename-agnostic aggregate contract.

Set a trace selection's manifest config to `{"expose": false}` when it exists
only as the inspection source's dependency. It still supplies the frozen trace
capture without creating a second analysis namespace. The
[TraceLog and run-analysis reference](../maintainers/trace-log-contract.md#query-contract)
defines query
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

`install` is required and may be empty. A limits-only host document raises
ceilings for an application that selects no providers:

```json
{
  "install": {},
  "limits": {
    "workflow_heap_words": 16000000
  }
}
```

Optional rows (`llm_total_tokens`, `llm_cost_microusd`,
`workflow_loop_iterations`, `evaluation_loop_iterations`) are disabled when
omitted. A positive host value enables the row, becomes the inherited manifest
default and installed ceiling, and may be narrowed by the application. The LLM
budget rows also require live-installation prerequisites; the loop-iteration
rows do not.

The four heap and concurrency rows (`workflow_heap_words`,
`evaluation_heap_words`, `provider_heap_words`, `live_provider_tasks`) and
`llm_request_timeout_ms` have no manifest headroom. Raising a heap or concurrency
row needs both the host ceiling and a matching manifest request. Raising the LLM
deadline needs three matching values: the host `llm_request_timeout_ms`, the
selected live installation's `ceilings.request_timeout_ms`, and the manifest
request. Every other application-narrowable row can be raised from the manifest
alone, up to its installed ceiling.

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

`readiness` is `not_applicable` when there are no provider check rows, `ready`
when every provider row passes, and `unverified` when any provider row is
skipped. A failed check reports `failed` and exits nonzero. The report
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
