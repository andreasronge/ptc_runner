# Command-line reference

This is the complete `ptc` command and process contract.

Every installation
exposes the same command grammar and runtime path.
Run `ptc help COMMAND` for the exact switches accepted by an installed version.

## Choose a command

| Command | Purpose |
| --- | --- |
| `ptc init DIRECTORY` | Publish a validated minimal application without replacing an existing target |
| `ptc init DIRECTORY --example NAME` | Publish one embedded example tree instead of the scaffold |
| `ptc docs [PAGE]` | List the documentation embedded in this executable, or print one page |
| `ptc help [COMMAND]` | Print the root command list, or the exact switches one command accepts |
| `ptc validate MANIFEST or PROJECT` | Load and compile without executing the workflow, and read the input files the declarations name |
| `ptc run MANIFEST or PROJECT` | Execute the application entry |
| `ptc run MANIFEST --env-file FILE` | Load environment-backed credentials from this exact file |
| `ptc doctor [MANIFEST or PROJECT]` | Report application and provider readiness |
| `ptc models PROJECT.json` or `--host-config HOST.json` | List public installed model-alias declarations, each with the safe selector it configured |
| `ptc transcript RUN_ID ...` | Publish one correlated private model transcript |
| `ptc repl` | Open a direct, manifest-backed, or analysis session |
| `ptc viewer PROJECT.json` | Browse a project's captured traces in a local web UI |
| `ptc viewer PROJECT.json --env-file FILE` | Use one exact dotenv file for Viewer-started workflows and missions |

Help is generated from the same declarations as the strict parser, so use
`ptc help COMMAND` as the canonical command and option reference.

A provider-bearing manifest needs a host configuration. A project document can
remember that path and its environment file. Before running it, active provider
checks can make real requests and may incur cost:

```console
ptc doctor ptc-project.json --connect
```

Plain doctor reports `readiness: "unverified"` when its local checks pass.
Missing provider commands, unreadable replay fixtures, and other attributable
local failures produce failed check rows, `readiness: "failed"`, and a nonzero
exit without activating a provider. Successful active checks report `ready`;
an attributable active failure also reports `failed` and exits nonzero. A
manifest or package rejected during application validation is likewise
reported as a failed `application` check instead of an internal command error.
Complete readiness reports, including `readiness: "failed"`, are written to
stdout. Failed reports retain their nonzero exit status; failures that cannot
produce a complete report are written to stderr. Runtime logger output,
including TLS handshake alerts, is written to stderr so stdout remains one
JSON document.
`--show-model-selectors` adds only safe selectors.

Every readiness report carries `usage`, on the LLM rows a run reports. Each
probed model alias contributes one call with the tokens and cost the provider
attributed to it, so a CI step can account for what the check spent:

```json
{"usage": {"llm_usage_state": "available",
           "llm_usage": [{"alias": "llm", "installation_revision": "v1",
                          "calls": 1, "successful_calls": 1, "usage_calls": 1,
                          "missing_usage_calls": 0,
                          "usage_overflow": false,
                          "usage": {"input": 8, "output": 1,
                                    "total_cost": {"currency": "USD", "microunits": 3}}}]}}
```

The probe asks for one output token, so this is about attribution rather than
magnitude. A command that activated no provider reports an empty list, because
it spent nothing. A failure that did activate one reports
`"llm_usage_state": "unavailable"` and a null list rather than claiming zero:
the request may have been billed with no result left to account for it. As in a
run, `total_cost` is omitted when any call could not be priced, and
`missing_usage_calls` counts calls whose usage may exist but was not observed,
including an in-flight request stopped by the run clock. It is not limited to
successful completions.

## Read the embedded documentation

Every installation carries the language specification, references, and JSON
Schemas that describe its own version. `ptc docs` lists them; `ptc docs PAGE`
prints one page verbatim to stdout:

```console
ptc docs
ptc docs agent-guide
ptc docs schema-manifest
```

Pages are embedded when the executable is built, so they need no network
access and cannot describe a different version. An unrecognized page name is
rejected as invalid arguments. `docs` publishes no envelope and reads no
application, host configuration, or project document.

Coding agents and LLMs driving the executable should start at
[Drive ptc as an agent](../guides/agent-cli-usage.md), served as
`ptc docs agent-guide`.

## Run a manifest

For normal local use, keep stable paths in a project document:

```console
ptc run ptc-project.json
ptc viewer ptc-project.json
```

The project form creates its fixed owner-only artifact layout as needed. See
[Project configuration](project-files.md). Direct manifest invocation
remains the explicit low-level form below.

To inspect one mission with the same project paths but without starting the
workflow, name it at invocation time:

```console
ptc repl --project ptc-project.json --mission review
```

The project document remains the only path/configuration file normally supplied
to a command; mission declarations continue to live only in `ptc.json`.

The trace directory must already exist:

```console
mkdir -p traces
ptc run ptc.json
ptc run ptc.json --trace-dir traces
ptc run ptc.json \
  --env-file .env \
  --host-config ptc-host.json \
  --trace-dir traces \
  --inspect traces/run.ptcins \
  --envelope results/command.json
```

Useful run switches are:

- `--input INPUT.json` replaces the manifest input with another normal object.
  Resolve the path as an application-relative document first; otherwise treat it
  as absolute or relative to the process working directory (same rule as
  `--component-override-descriptor` host paths).
- `--private-input INPUT.json` does the same and classifies the run as private.
- `--output VALUE.json` publishes a normal result value without replacing an
  existing file.
- `--private-output VALUE.json` publishes a private result at owner-only mode
  and keeps it off stdout.
- `--trace-dir DIR` writes `<run_ref>.jsonl` or
  `<run_ref>.private.jsonl` according to the run's artifact class.
- `--inspect FILE` writes sensitive execution evidence to an owner-only
  `.ptcins` file.
- `--envelope FILE` atomically publishes a convenience copy of the stable V4
  command envelope. When a project enables `artifacts.envelope`, the project's
  `.ptc/envelopes/<run_ref>.json` ledger entry is still written for that run.
  `run`, `validate`, `doctor`, `models`, and `init` all accept the flag; the
  document it publishes carries status, run reference, result or classified
  error, artifact state, and a closed `warnings` array. For `run`, an uncataloged
  installed model appears there as `model_uncataloged` with its provider alias
  and an adapter-attested public selector; the same warning is retained in
  `run-started` metadata. Non-run commands require an empty warnings
  array. In particular, `doctor --connect` retains uncataloged-model notices on
  stderr rather than claiming run metadata it does not produce. Parse the
  envelope rather than scraping stdout, which is a human
  presentation channel that may also carry application output.

The command envelope reports the run reference and artifact class, not artifact
paths. Output, trace, inspection, and envelope destinations must be distinct.
All publications are no-replace and recheck their destination at commit time.

Atomic publication may reserve owner-only sibling paths named
`.ptc-private-*` or `.ptc-private-result-*`. They normally disappear at commit
or cleanup, but an abruptly terminated process can leave one behind. Because a
completed reservation can contain private prompts, responses, source, or a
result, ignore both patterns as well as the configured artifact root. New
projects created by `ptc init` include all three patterns in `.gitignore`.

`ptc init` requires a `DIRECTORY` that does not already exist. It assembles the
complete scaffold or selected example tree and publishes it atomically without
replacing anything. To add PtcRunner to an existing repository, initialize a
new sibling or subdirectory, then deliberately copy or move the generated
files the repository wants.

`ptc init DIRECTORY --example NAME` publishes one of the walkthrough projects
this executable embeds instead of the scaffold, under the same no-replace
commit. Run `ptc init` with an unknown example name to have the embedded
names listed. The trees are byte-identical to the repository's, so the commands the
guides print work from wherever the copy was created rather than from one
checkout directory.

For runs that produce a validated terminal event batch, `execution.usage`
includes the required authoritative `llm_budget`, aggregate observational
`llm_spend`, and `llm_usage` grouped by
alias and installation revision,
`llm_usage_by_model` grouped by an attested public resolved model, and
`unattributed_model_calls`. `llm_spend` is byte-equivalent to the value in the
canonical `run-stopped` usage: `empty` and `incomplete` contain only `state`,
`unpriced` also contains non-negative `input` and `output`, `available`
adds a fixed-point USD `total_cost`, and `overflow` contains only `state`.
Only `available` can report a measured zero
cost; the other states never substitute zero for absent pricing. Rows report call counts, usage-presence counts, and
summed token and `total_cost` values plus required `usage_overflow`. Values
saturate at `9_007_199_254_740_991`; a true row flag means at least one value
is only a lower bound, while any aggregate overflow makes `llm_spend` exactly
`{"state":"overflow"}`. Terminal accounting pairs each
`llm-request` `capability-started` with its `capability-stopped` by
`capability_id`. An unmatched start is one observed call with unknown usage:
`calls` increments, `successful_calls` does not, and `missing_usage_calls`
increments. A matched error that may have dispatched likewise increments
`missing_usage_calls` when no usage was observed and makes `llm_spend`
`incomplete`. When that error retains valid provider-reported usage, the call
instead increments `usage_calls`, contributes its tokens and cost, and can make
`llm_spend` `available` even though `successful_calls` remains zero. Trusted
`not_dispatched` errors are excluded because no provider request could have
been billed. A row includes `total_cost` only when every call that could carry
usage has valid priced usage; an unmatched or unpriced call leaves the
aggregate cost unknown and omitted, not reported as zero, while measured
input/output totals are retained. `llm_usage_state: "available"` means the
terminal batch could be reconstructed, not that every call supplied usage.
`llm_usage_state: "unavailable"` pairs all three
aggregate fields with `null` when terminal evidence cannot be validated,
including dropped `capability-started` or `capability-stopped` events, while
preserving other known usage. Non-empty `events_dropped` for other event types
means an available detailed summary covers retained evidence and may not be
complete. `llm_usage_state` describes reconstruction of those detailed rows;
it does not replace the independently sealed five-state `llm_spend` value.

`llm_budget` always has the exact outer keys `total_tokens` and `cost`; either
is `null` when its optional host limit is disabled. An enabled token ledger
reports `state`, `limit`, `reserved`, `charged`, `remaining`, and `refused`.
The cost ledger uses the corresponding `_microusd` field names plus fixed
`currency: "USD"`. Terminal `reserved` values are zero after automatic
cleanup. `incomplete` means an acknowledged call was conservatively
full-charged without exact usage; `overrun` clamps remaining to zero and
refuses future calls. Unlike the event-derived detail rows, this projection is
sealed directly from RunState and remains authoritative when events are
dropped.

Artifact publication currently requires a Unix host with POSIX-compatible
`mkdir` and `id`; trace append also needs `sh` and either `lockf` or `flock`.
Private artifacts and newly created traces require trusted ancestry, safe
ownership, and restrictive modes. Preflight refuses unsafe or unwritable
destinations before provider acquisition, while descriptor-based publication
checks close later filesystem races.

`--inspect` is an explicit host development authority. It may contain prompts,
model responses, generated source, capability arguments and results, MCP
payloads, prints, and detailed failures. Do not publish it with normal traces.

### Evaluate replacement component source

Use `--component-override-descriptor` to evaluate one already-selected
component without installing it. A trusted build step creates the owner-only
candidate and descriptor from model-authored source. The
[replay evaluation guide](../guides/evaluating-with-replay.md) owns the workflow
for holding model responses fixed and comparing a baseline with that candidate.
The [component reference](component-contracts.md#evaluate-one-replacement-component)
defines every descriptor field. Candidate creation is not currently a
standalone command; a source checkout provides `mix ptc.materialize` as
documented in the repository's maintainer guide on embedding.

## Read results and failures

A successful normal run prints the compact JSON result value. A private run
does not print its value. The V4 envelope records the result class, artifact
states, bounded usage, retained-memory counts, and the closed diagnostic when
one exists.

Capability failures normally enter PTC-Lisp as recoverable envelopes so the
workflow can correct, retry, degrade, or fail. Parser, compiler, timeout, heap,
source, result, quota, provider, and event failures retain bounded Kernel
classifications.

One-shot public diagnostics come from a closed catalog. They never render an
arbitrary exception, rejected value, provider response, credential, or private
payload. A provider subject appears as `provider/<alias>/<operation>` with its
workflow or mission occurrence when known.

Host, project, and application schema diagnostics distinguish a closed set of
violated rules and carry only schema-authorized JSON Pointers. A missing
required field may name that schema-declared field; an unknown caller-authored
key is omitted and the pointer stops at its declared parent. Caller-selected
map members such as installation aliases and mission names render as `*`.

`validate` also reads the files a declaration owns rather than the environment
it will run in. A replay installation names a fixture file, so `validate` parses
it under the installed ceilings and reports the rule a rejected file broke —
with the line number for a line-level rejection. It still acquires nothing: an
installed model's adapter and an MCP server's executable are environment
dependencies and belong to `doctor`.

On success, the validate result includes `mission_grants`: for each named
mission, the sorted parseable `data/<name>` grants, every public export ref,
and selected mission provider names. This is the static grant declaration;
validate does not acquire providers, so capability tool names remain unresolved.
`kernel/mission-inventory` lists model-visible capabilities once a run or REPL
session has built the frozen inventory.

Environment files fail before provider acquisition with a cause-specific code:
`environment_file_not_found`, `environment_file_not_regular`,
`environment_file_unreadable`, `environment_file_too_large`, or
`environment_file_invalid_utf8`. The code identifies whether to create the
named `--env-file`/project file, change its permissions, or repair its bytes;
the public envelope still does not publish a host filesystem path.

When an agent turns a provider failure into workflow failure, the command
retains one bounded class when the adapter can prove it:
`llm_authentication_failed`, `llm_payment_required`, `llm_rate_limited`,
`llm_model_not_found`, `llm_tool_calling_unsupported`, `llm_request_invalid`,
`llm_access_denied`,
`llm_usage_unavailable`, `llm_timeout`, `llm_provider_unavailable`, or the non-retryable fallback
`llm_provider_failed`. No response body is retained.
The failing model alias remains attributable through usage/provider evidence;
run `ptc doctor PROJECT --connect` for a minimal provider check and use private
inspection only when authorized detail is necessary.

Component compile failures with a provable location print the logical component
name and the envelope's half-open byte range, for example `at main.clj bytes
[45,58)`. The same canonical offsets remain available in `error.span` when
`--envelope` is requested. An unknown namespace is a separate closed diagnostic:
the compiler carries the rejected namespace and canonical sorted namespace list
as structured detail, and the command boundary rebuilds the public list and JSON
hint after validating that detail. It never forwards the compiler-rendered
string. For a shipped namespace such as `kernel/`, select its library and add
the component dependency as described in
[Select a shipped prelude](component-contracts.md#select-a-shipped-prelude).

### Use the standalone process contract

For machine integration, name an envelope file instead of parsing stdout:

```console
ptc run ptc.json --envelope command-envelope.json
```

The standalone streams are human presentation channels and may also contain
output from applications or children. The envelope is an atomic, no-replace
file whose JSON Schema this executable serves as `ptc docs schema-envelope`
(`priv/schemas/ptc-command-envelope-v4.schema.json` in the repository). Its
status and exit-code relationship is sealed by the same command contract.

After arguments parse, an ordinary or caught command outcome publishes one
requested envelope. This includes a recognized `run`, `validate`, `doctor`, or
`models` invocation whose named project fails schema validation: project
diagnostics terminate before command bootstrap or project references are
opened, but after the envelope destination is admitted. Malformed command
syntax, conflicting arguments, invalid envelope destinations, and VM/OS
termination can produce no envelope.
Publication is no-replace, so a destination that already exists is refused
during argument admission with `arguments/envelope_destination_exists` and exit
`2`, before any provider work: a repeated CI step is told to remove the file
rather than paying for a run whose result it cannot receive. If envelope
publication itself fails, the standalone command exits `74` and cannot report
that failure through the missing envelope. Success exits `0`; classified
failures use their diagnostic catalog status; caught internal failures use
`70`.

`run`, `validate`, `doctor`, `models`, and `init` accept `--envelope`.
`repl`, `transcript`, `viewer`, `docs`, help, and version do not. A private run
envelope omits the result value. Installation, packaging, and container
commands live in the [installation documentation](../installation/standalone.md),
not in this process-contract reference.

### Branch on the exit status

An exit status is a class, not an identity: several diagnostics share one.
`runtime_limit_exceeded`, `run_timeout`, `turn_limit_exceeded`,
`capability_quota_exceeded`, and `model_output_truncated` all exit `6`. Branch
on the status to decide whether to retry, and read `error.code` from the
envelope when the branch needs to know which failure it was.

A recoverable capability error does not change the exit status. Exhausting
`workflow_capability_calls_per_name` returns
`{"status":"error","kind":"limit_exceeded","reason":"capability_quota","details":{"limit":"workflow_capability_calls_per_name","name":"llm-request","limit_value":2}}` as a
value into PTC-Lisp; a workflow that reads past it can still `return` and the
command exits `0`. Refusing an aggregate `llm_total_tokens` or
`llm_cost_microusd` reservation is the same class of recoverable value, with
`reason` naming the budget. Aborting that exact envelope reports
`execution/runtime_limit_exceeded` (exit 6) and names the refused reservation;
it is not `workflow_failed`. `execution.usage.capability_refusals` counts those errors
from environment capability callbacks and the implicit runtime routes the
Kernel grants with them (`workflow/limit_exceeded/capability_quota`,
`workflow/limit_exceeded/llm_total_tokens`,
`workflow/limit_exceeded/llm_cost_microusd`).
Runner-added routes such as `kernel-eval` are not counted. At most 2 distinct
classes are named; further classes increment `$overflow`. Assert
`capability_refusals` is `{}` when a CI job requires that every counted
capability call succeeded, or have the workflow `fail`, when a quota must end
the run.

The tables below are generated from the diagnostic catalog the command
dispatches on, so they list every status a command can exit with and every
diagnostic behind it.

<!-- BEGIN GENERATED: exit-status catalog (mix ptc.gen_docs) -->

| Status | Meaning | Phases |
| ---: | --- | --- |
| 0 | the command succeeded | — |
| 2 | the arguments were rejected before any document was read | `arguments` |
| 3 | a declaration document was unavailable, invalid, or rejected | `project`, `host`, `application`, `bundle`, `provider_declaration` |
| 4 | a selected provider could not be checked or acquired | `local_preflight`, `active_preflight`, `provider_acquisition` |
| 5 | the workflow ran and failed | `execution` |
| 6 | the run exceeded a limit or its duration | `execution` |
| 7 | the run produced no usable artifact: a destination, result, or publication failure | `destination`, `execution`, `result_cleanup`, `publication` |
| 70 | the command failed internally | `internal` |
| 74 | the requested envelope could not be published, so no envelope describes this failure | — |

Every classified diagnostic and the status it exits with:

| Status | Phase | Code | Retryable | Message |
| ---: | --- | --- | --- | --- |
| 2 | `arguments` | `conflicting_arguments` | no | choose only one option from the conflicting argument group |
| 2 | `arguments` | `docs_page_unknown` | no | no documentation page is served under that name |
| 2 | `arguments` | `envelope_destination_exists` | no | the envelope destination already exists |
| 2 | `arguments` | `example_unknown` | no | no example is embedded under that name |
| 2 | `arguments` | `invalid_arguments` | no | use the documented arguments for this command |
| 2 | `arguments` | `invalid_command` | no | use one of the supported commands |
| 2 | `arguments` | `project_host_undeclared` | no | the project document declares no host block; add one to use this command |
| 3 | `application` | `application_not_found` | no | the application manifest does not exist |
| 3 | `application` | `application_unavailable` | no | the application is unavailable |
| 3 | `application` | `contract_invalid` | no | an application value contract is invalid |
| 3 | `application` | `contract_projection_limit_exceeded` | no | application contract prompt projections exceed their bounded admission limit |
| 3 | `application` | `document_limit_exceeded` | no | the application document closure exceeds its limit |
| 3 | `application` | `duplicate_property` | no | an application document contains a duplicate property |
| 3 | `application` | `event_identity_conflict` | no | the command event identity conflicts with the application |
| 3 | `application` | `input_contract_failed` | no | the selected input does not satisfy the input contract |
| 3 | `application` | `input_invalid` | no | the selected input is not an admissible JSON object |
| 3 | `application` | `installed_limit_exceeded` | no | an application limit exceeds the installed ceiling; lower it or raise the host-configured ceiling |
| 3 | `application` | `invalid_json` | no | an application document is not valid JSON |
| 3 | `application` | `limit_capacity_invalid` | no | event_payload_bytes effective limit 8211 is below the required 12000 bytes for this application's resolved terminal usage; raise limits.event_payload_bytes, and its installed host ceiling if it is lower, or declare fewer capabilities or missions |
| 3 | `application` | `limit_configuration_invalid` | no | normal_event_bytes effective limit 4000000 is below the required 12003450 bytes for event_payload_bytes 4000000; raise limits.normal_event_bytes, and its installed host ceiling if it is lower, or lower limits.event_payload_bytes |
| 3 | `application` | `limit_unavailable` | no | an optional application limit is unavailable because the host has not enabled it |
| 3 | `application` | `override_invalid` | no | the component override is invalid |
| 3 | `application` | `reference_missing` | no | a referenced document is unavailable; for --input/--private-input try an application-relative name or an absolute/working-directory path |
| 3 | `application` | `required_property_missing` | no | the application manifest is missing a required property |
| 3 | `application` | `schema_validation_unavailable` | yes | application schema validation timed out or exceeded its resource bound; retry the command |
| 3 | `application` | `schema_violation` | no | the application manifest does not satisfy its schema |
| 3 | `bundle` | `bundle_invalid` | no | the component bundle is invalid |
| 3 | `bundle` | `bundle_limit_exceeded` | no | the component bundle exceeds a compile limit |
| 3 | `bundle` | `compile_failed` | no | the component bundle could not be compiled |
| 3 | `bundle` | `duplicate_definition` | no | the component bundle defines the same name more than once |
| 3 | `bundle` | `entry_invalid` | no | the workflow entry is not a public bundle export |
| 3 | `bundle` | `mission_undeclared` | no | the workflow entry evaluates into a mission and the manifest declares none |
| 3 | `bundle` | `syntax_invalid` | no | the component source is not valid PTC-Lisp |
| 3 | `bundle` | `undefined_variable` | no | the component source contains an undefined variable reference |
| 3 | `bundle` | `unknown_namespace` | no | the component source references an unavailable namespace |
| 3 | `host` | `host_invalid` | no | the host configuration is invalid |
| 3 | `host` | `host_schema_invalid` | no | the host configuration does not satisfy its schema |
| 3 | `host` | `host_unavailable` | no | the host configuration is unavailable |
| 3 | `host` | `installation_endpoint_credentials_require_https` | no | configured MCP credentials require an https endpoint |
| 3 | `host` | `installation_endpoint_insecure_loopback_forbidden` | no | allow_insecure_loopback is not permitted on an https endpoint; remove it |
| 3 | `host` | `installation_endpoint_insecure_loopback_required` | no | a plain-http MCP endpoint requires allow_insecure_loopback |
| 3 | `host` | `installation_endpoint_invalid` | no | an installed MCP endpoint is not admissible; streamable_http requires an https URL, or allow_insecure_loopback with a credential-free plain-http loopback address |
| 3 | `host` | `installation_endpoint_literal_loopback_required` | no | allow_insecure_loopback requires a literal 127.0.0.1 or [::1] address |
| 3 | `host` | `installation_revision_missing` | no | an installed provider is missing its behavior revision |
| 3 | `host` | `installed_limit_invalid` | no | an installed limit is invalid |
| 3 | `host` | `schema_validation_unavailable` | yes | host schema validation timed out or exceeded its resource bound; retry the command |
| 3 | `project` | `project_schema_invalid` | no | the project configuration does not satisfy its schema |
| 3 | `project` | `schema_validation_unavailable` | yes | project schema validation timed out or exceeded its resource bound; retry the command |
| 3 | `provider_declaration` | `data_policy_denied` | no | the selected providers do not admit the effective data class |
| 3 | `provider_declaration` | `dependency_invalid` | no | the selected provider dependency graph is invalid |
| 3 | `provider_declaration` | `placement_denied` | no | the provider is not allowed in this destination |
| 3 | `provider_declaration` | `provider_unknown` | no | the selected provider is not installed |
| 3 | `provider_declaration` | `selection_invalid` | no | the provider selection is invalid |
| 3 | `provider_declaration` | `selection_unverifiable` | no | the provider selection cannot be verified declaratively |
| 4 | `active_preflight` | `authentication_rejected` | no | provider authentication was rejected |
| 4 | `active_preflight` | `authorization_rejected` | no | explicit provider authorization was rejected |
| 4 | `active_preflight` | `authorization_required` | no | explicit provider authorization is required |
| 4 | `active_preflight` | `authorization_unavailable` | yes | the authorization service is temporarily unavailable |
| 4 | `active_preflight` | `connectivity_outcome_unknown` | no | the connectivity outcome could not be committed safely |
| 4 | `active_preflight` | `connectivity_protocol_error` | no | the provider returned an invalid connectivity response |
| 4 | `active_preflight` | `connectivity_rate_limited` | yes | the provider connectivity operation is rate limited |
| 4 | `active_preflight` | `connectivity_rejected` | no | the provider rejected the connectivity operation |
| 4 | `active_preflight` | `connectivity_timeout` | no | the connectivity operation exceeded its budget |
| 4 | `active_preflight` | `connectivity_unavailable` | yes | the provider connectivity operation is temporarily unavailable |
| 4 | `active_preflight` | `connectivity_unsupported` | no | the provider does not implement the declared connectivity check |
| 4 | `active_preflight` | `credential_unavailable` | no | a required provider credential is unavailable |
| 4 | `active_preflight` | `provider_application_unavailable` | no | a required provider application is unavailable |
| 4 | `active_preflight` | `selection_rejected` | no | the provider rejected the normalized selection |
| 4 | `active_preflight` | `selection_validation_failed` | no | active provider selection validation failed |
| 4 | `active_preflight` | `selection_validation_timeout` | no | active provider selection validation timed out |
| 4 | `local_preflight` | `adapter_unavailable` | no | a required provider adapter is unavailable |
| 4 | `local_preflight` | `authorization_not_applicable` | no | --authorize-mcp applies only to an installation that declares OAuth |
| 4 | `local_preflight` | `authorization_target_unknown` | no | --authorize-mcp must name an installed provider the application selects |
| 4 | `local_preflight` | `command_not_found` | no | a required provider command could not be found |
| 4 | `local_preflight` | `environment_file_invalid_utf8` | no | the named environment file is not valid UTF-8 |
| 4 | `local_preflight` | `environment_file_not_found` | no | the named environment file does not exist |
| 4 | `local_preflight` | `environment_file_not_regular` | no | the named environment file is not a regular file |
| 4 | `local_preflight` | `environment_file_too_large` | no | the named environment file exceeds the 1 MB limit |
| 4 | `local_preflight` | `environment_file_unreadable` | no | the named environment file cannot be read safely |
| 4 | `local_preflight` | `environment_unavailable` | no | a required local environment is unavailable |
| 4 | `local_preflight` | `executable_unavailable` | no | a required provider executable is unusable |
| 4 | `local_preflight` | `fixtures_unreadable` | no | provider fixtures could not be read |
| 4 | `local_preflight` | `launcher_unavailable` | no | a required provider launcher is unavailable |
| 4 | `local_preflight` | `local_check_timeout` | no | a local provider check timed out |
| 4 | `local_preflight` | `model_contract_unsupported` | no | the selected model cannot honor its installed model contract |
| 4 | `provider_acquisition` | `capability_requirement_missing` | no | a component requires a capability that the selected providers did not supply |
| 4 | `provider_acquisition` | `provider_acquisition_timeout` | yes | the selected provider exceeded its acquisition timeout budget |
| 4 | `provider_acquisition` | `provider_endpoint_connection_refused` | yes | the installed endpoint refused the connection |
| 4 | `provider_acquisition` | `provider_endpoint_name_unresolved` | no | the installed endpoint hostname could not be resolved |
| 4 | `provider_acquisition` | `provider_endpoint_tls_failed` | no | the installed endpoint did not complete a TLS handshake |
| 4 | `provider_acquisition` | `provider_policy_changed` | no | the selected provider policy changed during acquisition |
| 4 | `provider_acquisition` | `provider_protocol_error` | no | the selected provider returned an invalid acquisition response |
| 4 | `provider_acquisition` | `provider_protocol_version_unsupported` | no | the endpoint did not advertise support for MCP protocol 2026-07-28 |
| 4 | `provider_acquisition` | `provider_tool_missing` | no | the installed endpoint does not expose a declared tool |
| 4 | `provider_acquisition` | `provider_unavailable` | no | the selected provider could not be acquired |
| 5 | `execution` | `evaluation_failed` | no | the evaluation failed |
| 5 | `execution` | `explicit_failure` | no | the workflow signalled an explicit failure |
| 5 | `execution` | `invalid_agent_config` | no | an agent configuration option is outside its supported range |
| 5 | `execution` | `llm_access_denied` | no | the LLM provider denied access to the configured model |
| 5 | `execution` | `llm_authentication_failed` | no | the LLM provider rejected authentication; check the installed credential |
| 5 | `execution` | `llm_model_not_found` | no | the LLM provider could not find the configured model |
| 5 | `execution` | `llm_payment_required` | no | the LLM provider rejected the request for billing or credit reasons |
| 5 | `execution` | `llm_provider_failed` | no | the LLM provider request failed |
| 5 | `execution` | `llm_provider_unavailable` | yes | the LLM provider is unavailable |
| 5 | `execution` | `llm_rate_limited` | yes | the LLM provider rate limited the request |
| 5 | `execution` | `llm_request_invalid` | no | the LLM provider rejected the configured request |
| 5 | `execution` | `llm_timeout` | yes | the LLM provider request timed out |
| 5 | `execution` | `llm_tool_calling_unsupported` | no | the configured model does not support tool calling |
| 5 | `execution` | `llm_usage_unavailable` | no | the LLM provider did not return the promised usage or cost metadata |
| 5 | `execution` | `mission_failed` | no | a subordinate mission failed |
| 5 | `execution` | `provider_failed` | no | a provider failed during execution |
| 5 | `execution` | `replay_fixture_missing` | no | no replay fixture matches the workflow request |
| 5 | `execution` | `workflow_failed` | no | the workflow failed |
| 6 | `execution` | `capability_quota_exceeded` | no | a capability quota was exceeded |
| 6 | `execution` | `model_output_truncated` | no | model output was truncated before producing a usable agent action |
| 6 | `execution` | `run_timeout` | no | the run duration limit was exceeded |
| 6 | `execution` | `runtime_limit_exceeded` | no | a runtime limit was exceeded |
| 6 | `execution` | `turn_limit_exceeded` | no | the agent turn limit was exceeded |
| 7 | `destination` | `destination_exists` | no | an artifact destination already exists |
| 7 | `destination` | `inspection_destination_unavailable` | no | the inspection destination is unavailable |
| 7 | `destination` | `inspection_destination_unsafe` | no | the inspection destination is unsafe |
| 7 | `destination` | `inspection_directory_missing` | no | --inspect must name a file in an existing directory |
| 7 | `destination` | `invalid_destination` | no | an artifact destination is invalid |
| 7 | `destination` | `invalid_inspection_destination` | no | --inspect must name a valid destination ending in .ptcins |
| 7 | `destination` | `invalid_result_destination` | no | the result destination is invalid |
| 7 | `destination` | `invalid_trace_destination` | no | the trace destination is invalid |
| 7 | `destination` | `private_destination_required` | no | the run requires an authorized private destination |
| 7 | `destination` | `recovery_reservation_failed` | no | the private result recovery reservation failed |
| 7 | `destination` | `result_destination_unavailable` | no | the result destination is unavailable |
| 7 | `destination` | `result_destination_unsafe` | no | the result destination is unsafe |
| 7 | `destination` | `result_directory_missing` | no | --output and --private-output must name a file in an existing directory |
| 7 | `destination` | `trace_destination_unavailable` | no | the trace destination is unavailable |
| 7 | `destination` | `trace_destination_unsafe` | no | the trace destination is unsafe |
| 7 | `destination` | `trace_directory_missing` | no | --trace-dir must be an existing normal directory |
| 7 | `execution` | `event_capture_limit_exceeded` | no | the trace event capture limit was exceeded |
| 7 | `execution` | `event_sink_unavailable` | no | the trace event sink is unavailable |
| 7 | `execution` | `inspection_capture_limit_exceeded` | no | the private inspection capture limit was exceeded |
| 7 | `execution` | `inspection_sink_unavailable` | no | the private inspection sink is unavailable |
| 7 | `publication` | `destination_collision` | no | an artifact destination appeared before publication |
| 7 | `publication` | `initialization_failed` | no | project initialization failed |
| 7 | `publication` | `initialization_parent_missing` | no | the initialization target's parent directory does not exist |
| 7 | `publication` | `initialization_parent_unusable` | no | the initialization target's parent directory is unusable |
| 7 | `publication` | `initialization_target_exists` | no | ptc init publishes only to a new directory; choose a target that does not already exist |
| 7 | `publication` | `inspection_publication_failed` | no | inspection publication failed |
| 7 | `publication` | `recovery_cleanup_failed` | no | private result recovery cleanup failed |
| 7 | `publication` | `result_publication_failed` | no | result publication failed |
| 7 | `publication` | `trace_publication_failed` | no | trace publication failed |
| 7 | `result_cleanup` | `provider_cleanup_failed` | no | provider cleanup failed |
| 7 | `result_cleanup` | `provider_cleanup_timeout` | no | provider cleanup timed out |
| 7 | `result_cleanup` | `result_contract_failed` | no | the workflow result does not satisfy its contract |
| 7 | `result_cleanup` | `result_invalid` | no | the workflow result is invalid |
| 7 | `result_cleanup` | `result_limit_exceeded` | no | the workflow result exceeds its limit |
| 70 | `internal` | `internal_error` | no | the command failed internally |
<!-- END GENERATED: exit-status catalog -->

### Profile frontend diagnostics

Profile commands exit `1` for frontend setup, source capture, selection, or
evaluation refusals. Selection, immutable source-capture, and classified
evaluation refusals carry a stable `code` from the table below in the terminal
JSONL `command-error` record; stderr uses the same identity as `repl/CODE`.
Other frontend setup and persistence failures retain `repl/command_failed`.
Shared argument-parser refusals still use their existing `arguments/CODE`
diagnostic and exit `2`. Catalog messages never include a resource path,
selected run reference, or private payload. Any internal reason classified at
this boundary but outside the closed vocabulary becomes `profile_setup_failed`.

The table is generated from the catalog the REPL frontend dispatches on:

<!-- BEGIN GENERATED: profile diagnostic catalog (mix ptc.gen_docs) -->

| Code | Refusal | Public message |
| --- | --- | --- |
| `ambiguous_selected_trace` | Both sanitized and private trace candidates exist. | selected run has ambiguous trace candidates |
| `catalog_limit_exceeded` | Catalog entry, file, retained-memory, heap, or listing bounds were exceeded. | private run catalog exceeded its capture limits |
| `duplicate_inspection_run` | More than one selected artifact claims the same inspection run identity. | selected inspection set contains a duplicate run identity |
| `duplicate_selected_run` | The same run reference was supplied more than once. | selected run set contains a duplicate reference |
| `inspection_correlation_missing` | The selected trace and sealed evidence do not prove one correlation. | selected trace and inspection artifacts do not correlate |
| `invalid_run_reference` | A --run value is not a canonical PTC command run reference. | selected run reference is invalid |
| `malformed_source` | Selected metadata or sealed evidence failed structural validation. | analysis source is malformed |
| `profile_evaluation_failed` | A profile form failed for a reason outside the source-capture vocabulary. | profile evaluation failed |
| `profile_setup_failed` | An unclassified internal setup failure was closed at the frontend boundary. | private analysis profile setup failed |
| `result_limit_exceeded` | A catalog page or selected-analysis result could not fit its result bound. | profile evaluation result exceeded its byte limit |
| `selected_inspection_missing` | No sealed inspection artifact exists for a selected run. | selected inspection artifact is missing |
| `selected_inspection_not_regular` | The exact selected inspection candidate is not a regular file. | selected inspection artifact is not a regular file |
| `selected_run_mismatch` | Embedded run or trace identity disagrees with the selected candidate. | selected source identity does not match its run reference |
| `selected_set_limit_exceeded` | More than sixteen run references were selected for one session. | selected run set exceeds the 16-run limit |
| `selected_trace_missing` | No trace candidate exists for a selected run. | selected trace is missing |
| `selected_trace_not_regular` | The exact selected trace candidate is not a regular file. | selected trace is not a regular file |
| `source_changed` | A selected source or cursor identity changed while it was being verified. | analysis source changed during immutable capture |
| `source_limit_exceeded` | Aggregate bytes, per-artifact records, index entries, or heap were exceeded. | selected analysis source exceeded its admission limits |
| `source_retained_limit_exceeded` | The immutable trace projection or inspection index retained too much memory. | selected analysis source exceeded its retained-memory limit |
| `source_unavailable` | A source root became unavailable or its bounded capture deadline elapsed. | analysis source is unavailable or capture timed out |
| `unsupported_schema` | A selected trace or inspection artifact uses an unsupported version. | analysis source uses an unsupported schema version |
<!-- END GENERATED: profile diagnostic catalog -->

### Diagnose a failed run

The command reports a closed phase/code pair. If a workflow deliberately calls
`fail`, its value is not copied into the command diagnostic. The Kernel API and
canonical `run-stopped` event retain only a safe taxonomy:

- a map whose `kind` is recognized retains that readable kind;
- an authenticated `agent.core` turn-limit failure additionally retains the
  fixed `agent_turns` name, the effective integer ceiling from 1 through 128,
  and the closed reason the loop stopped (`turn_limit_exceeded`,
  `intermediate_result`, `evaluation_error`, or `protocol_error`);
- an unknown map kind retains only a one-way fingerprint;
- a string or other non-map retains no detail.

Prefer a framework classification such as:

```clojure
(fail {:kind "assertion-failed" :detail "private explanation"})
```

The public evidence retains `assertion-failed`, not the private explanation.
The Runner adds the fixed `agent_turns` fields only after the shipped agent's
private runtime route has authenticated the exhaustion failure.

For exact authorized detail, capture inspection evidence:

```console
ptc run ptc.json \
  --trace-dir traces \
  --inspect private/run.ptcins
```

Each inspection artifact includes the frozen component sources. It adds
execution prints and any provider-backed private activity that occurred. A
failure can add detailed `execution-error` evidence. A raised capability
callback additionally records its bounded exception class, message, and
formatted stacktrace while the trace retains only the closed
`provider_error / exception` category. Exception text and stacktrace paths can
contain sensitive data and are not reliably redactable; read the artifact only
through an authorized private sink.

To debug compilation with the manifest bundle, use manifest mode:

```console
ptc repl -m ptc.json
```

`-l` dynamically evaluates setup code and does not accept component-only forms
such as `ns` or `defn-`.

## Use workflow REPL sessions

Start a scratch session or attach the manifest's frozen workflow environment:

```console
ptc repl
ptc repl -e '(def x 40)' -e '(+ x 2)' -e '(+ *1 1)'
ptc repl --manifest ptc.json --host-config ptc-host.json
ptc repl --manifest ptc.json --trace traces/repl.jsonl
```

Successful definitions and three-value history persist for one session; failed
forms preserve prior state. Manifest providers are acquired once and reused.
Private manifest sessions require an attached terminal and
`--private-terminal`. The [Kernel REPL guide](repl.md) covers all modes,
input forms, privacy gates, JSON Lines, bounds, and cleanup.

An interactive session on a terminal runs under the Erlang line editor, so the
usual editing keys work — `Ctrl+A`/`Ctrl+E`, word motion, `Ctrl+K`/`Ctrl+U`
and yank, arrow-key history, and `Ctrl+R` reverse search. Two keys behave
differently there than in a plain terminal reader:

- `:quit` leaves the session. `Ctrl+D` deletes the character under the cursor
  instead of ending input, because the editor binds it that way and offers no
  end-of-input binding to rebind it to.
- `Ctrl+C` opens the BEAM break menu, as it does in `iex`. Press `c` to return
  to the prompt or `a` to abort the command.

A direct session keeps its submitted lines between runs, under
`ptc/repl-history` in the user cache directory, so the previous session's
expressions are one arrow key away. A manifest session can carry a private
event policy, so it edits and recalls within the session but writes nothing to
disk.

Analysis profile sessions (`--profile`) read under the source limit that mode
enforces, which the line editor cannot drive. They keep the plain reader, and
with it `Ctrl+D` as end of input; `:quit` works there too. Every
non-interactive form — `-e`, a script argument, `-`, or redirected input —
reads exactly as before.

## Query traces

Traces contain bounded operational events, not prompts, model
responses, capability payloads, or generated source. Query one immutable
directory capture through the fixed public profile:

```console
ptc repl \
  --profile run-analysis-v1 \
  --resource traces=traces \
  -e '(analysis/runs {})' \
  -e '(analysis/open "run-id")'
```

Public analysis supports `runs`, `open`, `read`, and `counters`; the public
`activity` collection contains trace events. `open` advertises the private
collections
but they require a correlated inspection snapshot and private authority.
`analysis/runs` defaults to a compact projection containing run ID, status,
duration, LLM calls, evaluations, terminal reason, and completeness flags. Pass
`{"view" "full"}` when selecting by the complete metadata record:

```clojure
(analysis/runs {"status" "error"})
(analysis/runs {"status" "error" "view" "full"})
```

When a project already declares its artifact root, reuse it instead of
repeating resource paths:

```console
ptc repl --project ptc-project.json \
  --profile run-analysis-v1 \
  -e '(analysis/runs {})'
```

The public profile derives `traces`; both private profiles derive `traces` and
`inspection` when those artifact classes are enabled. An explicit `--resource
NAME=DIR` overrides only that derived resource. Use
`private-run-catalog-v1` with `(analysis/catalog QUERY)` for bounded safe
metadata discovery before opening private evidence; the complete query contract
is in the [Kernel REPL guide](repl.md#discover-a-private-run-catalog).

The complete discovery-to-selection command flow is two invocations. Replace
the example references in the second command with `run_id` values from
admissible rows in the first command's JSONL evaluation record:

```console
ptc repl --profile private-run-catalog-v1 \
  --resource traces=.ptc/traces \
  --resource inspection=.ptc/inspection \
  --private-unattended --format jsonl \
  -e '(analysis/catalog {"state" "admissible" "limit" 20})'

ptc repl --profile private-run-analysis-v2 \
  --run cmd-00000000000000000000000001 \
  --run cmd-00000000000000000000000002 \
  --resource traces=.ptc/traces \
  --resource inspection=.ptc/inspection \
  --private-unattended --format jsonl \
  -e '(analysis/runs {})'
```

Each selected session accepts one through sixteen distinct canonical command
run references. It re-verifies the exact candidates and carries no catalog
cursor, digest, or dynamic source-acquisition authority. Start another command
with a later batch rather than trying to add runs to an open session.

The [TraceLog and run-analysis reference](../maintainers/trace-log-contract.md) defines
event schemas,
sanitization, filtering, pagination, and source classes. The
[Kernel REPL guide](repl.md) covers longer investigations.

## Inspect a private model conversation

Capture canonical and inspection artifacts in separate trusted locations. The
credential-free
[Kernel inspection lab](https://github.com/andreasronge/ptc_runner/tree/main/examples/kernel-inspection-lab)
creates a correlated pair without a live model.

For one transcript, avoid a REPL:

```console
mkdir -p tmp/transcript
ptc transcript RUN_ID \
  --traces tmp/traces \
  --inspection tmp/inspection \
  --private-unattended \
  --private-output tmp/transcript/conversation.private.json
```

Each selected model turn carries the provider-neutral `request_hash` used by
`llm_replay` fixtures. The underlying owner-only inspection artifact carries
the same value as `payload.request_hash` on the `llm-request`
`capability-input` record. A private replay miss keeps that hash out of its
public message while retaining the `replay_fixture_missing` code; copy the
transcript field into the fixture and rerun.

The command reserves an owner-only destination before capture. `RUN_ID` must be
a canonical PTC command run reference (`cmd-` followed by 26 Crockford
characters). Capture then opens only these exact candidates, without listing
either directory:

```text
TRACE_DIRECTORY/RUN_ID.jsonl
TRACE_DIRECTORY/RUN_ID.private.jsonl
INSPECTION_DIRECTORY/RUN_ID.ptcins
```

Exactly one of the two trace candidates must exist as a regular file; both
present is an ambiguous selected source. The inspection candidate must exist as
a regular file. Filenames are routing hints: embedded run and trace identities
remain authoritative, and unrelated directory members are not listed, opened,
sized, decoded, or counted toward directory or aggregate source limits. The
selected files still keep their individual source, record, retained-memory,
heap, deadline, and result ceilings. Whole-directory snapshots used by
`private-run-analysis-v2` stay a distinct source variant: they admit only
filename-bound one-run files, isolate a stable damaged connected component,
and keep disjoint healthy runs queryable. Namespace or selected-file mutation
still rejects the whole capture.

The parent of `--private-output` must already exist and be reached without a
symbolic link — on macOS `/tmp` is a symlink, so `/tmp/out.json` is refused.
Trace, inspection, and output directories must be pairwise physically separate:
no directory may equal, contain, or be contained by either of the others. A
file in the current directory fails when that directory contains `--traces`;
create a sibling directory instead, as above. A rejection names the two
conflicting switches and their physical relationship, and discloses no path.
A noncanonical or traversal-shaped `RUN_ID`, a missing or non-regular selected
candidate, a selected identity or correlation mismatch, and ambiguous,
incomplete, changed, unsupported, or oversized selected evidence fail without a
partial output.

Use `private-run-analysis-v2` when you need several correlated questions or
custom PTC-Lisp analysis. Its results can include exact messages, generated
source, effective components, capability payloads, prints, diagnostics, and
terminal values. The attached-terminal and unattended switches are accident
guards, not access control; treat every downstream sink as private.

To walk the same capture from an ordinary application rather than a session,
[Debug a failed run](debug-navigation.md) installs it as a snapshot
provider and follows typed evidence links with the shipped `debug.nav` prelude.

## Browse traces in the Viewer

```console
ptc viewer ptc-project.json --env-file .env
```

The project document supplies the trace root and optional inspection root, plus
the port, browser-opening preference, REPL setting, and private-data grant. The
Viewer pins the selected data and can open a bounded analysis REPL over an
immutable capture. `--port` overrides the project's port; `0` asks the
operating system for a free one and is the project default. Startup prints the
selected address. If an explicitly selected port is occupied, the command
probes loopback: another PTC Viewer is reported with its exact project document
path, while any other listener is reported as an occupied service. The command
runs in the foreground until `Ctrl+C`, and opens a browser only when the project
asks for it *and* a terminal is attached.

Directory discovery expects producer-owned `<run-id>.jsonl` and
`<run-id>.private.jsonl` names, each containing exactly that one run and one
trace identity. The run list reports bounded damaged-source evidence when a
stable malformed, mismatched, split, or conflicting component is isolated;
unrelated valid runs remain available. A selected namespace change during
capture fails the refresh rather than installing a partial generation.

The Viewer does not search the invocation directory or its parents for a
`.env` file. Environment-backed provider credentials come from the inherited
process environment, the project's `host.env_file`, or an explicit
`--env-file FILE`. The command-line file is resolved when the Viewer starts
and overrides the project's environment-file reference for every workflow or
mission launched from its Live tab. It is read only when the selected provider
actually requires an environment credential.

The Viewer ships inside the standalone release and the container image. It is
not part of the published Hex package, where `ptc doctor` reports it as an
unavailable optional companion and `ptc viewer` says so rather than failing
obscurely. See the
[Viewer documentation](https://github.com/andreasronge/ptc_runner/tree/main/ptc_viewer)
for its complete HTTP API.

### Expose it deliberately, or not at all

The Viewer has no authentication and can display private inspection records
when the project grants them, so it binds `127.0.0.1` and reaches nothing else.
`--listen 0.0.0.0` is the only way to change that, it accepts no other address,
and it prints a warning when used. Authenticated remote Viewer hosting is not a
goal of this command.

A container is the one place the wildcard is routine, because it is not an
exposure decision there. Inside a container `127.0.0.1` is the container's own
loopback, while a published port forwards to the container's external
interface, so a loopback bind refuses every connection a `-p` mapping delivers.
Binding `0.0.0.0` *inside the container's network namespace* is what makes the
mapping reachable, and the host-side exposure decision moves to the publish
rule:

```console
image=ghcr.io/andreasronge/ptc_runner:VERSION
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  -p 127.0.0.1:4123:4123 \
  -v "$PWD:/work" \
  "$image" viewer /work/ptc-project.json --listen 0.0.0.0 --port 4123
```

The `127.0.0.1:` prefix on `-p` is what keeps this equivalent to a loopback
bind. Writing `-p 4123:4123` instead publishes an unauthenticated trace browser
to every host that can reach the machine. The command cannot enforce that
prefix; you must write it. The user mapping preserves access to the
mounted project's owner-only artifacts; do not run this form from a root shell.

### Watch and launch live runs

A Kernel run reports to the Live tab when `PTC_VIEWER_URL` names the Viewer:

```console
PTC_VIEWER_URL=http://127.0.0.1:4123 ptc run ptc.json
```

The reporter is best-effort and does not alter the run result. Frames are
correlated to their owning run, and the terminal frame is published only after
provider cleanup and trace-event finalization establish the actual
outcome. A timeout failure names the binding limit, its configured duration,
and the manifest key that raises it, in both the launch diagnostic and the
ended Live card; for example, `parallel_timeout_ms limit 60000 ms was exceeded
during execution; raise limits.parallel_timeout_ms in the manifest, and the
installed host ceiling if it is lower`. Mission
sessions currently show their bounded command-output tail in the launch panel
instead of streaming frames.

An ended workflow card offers **View result**. That action captures a fresh,
internally consistent trace snapshot, confirms that the matching run exists,
and then opens its detail view in the Runs tab. The Viewer therefore does not
need to be restarted after a run it launched.

The ordinary project command also configures the Live project details and one
fixed launch target from that same project document. The browser may edit
workflow input or choose one declared mission, but it cannot choose a project,
manifest, working directory, or command:

```console
ptc viewer ptc-project.json --env-file .env
```

Viewer-launched workflow cards use the manifest label and workflow entry as
their human-facing title, while retaining the `cmd-...` value as the stable run
identifier. The Live tab and `GET /api/live/runs` list newest first, and each
card shows when the Viewer first saw that run, so an edited ceiling cannot be
read off an older card as a stale enforcement.

The command is already a long-running PtcRunner host, so Viewer-started work
runs inside that BEAM instance under the ordinary execution-session owner. A
host-injected adapter receives a semantic workflow or mission request and a
direct live-frame sink; no `mix` or `ptc` child process is started. The adapter
dispatches the named project through the same command engine, so its host,
environment, and artifact defaults remain authoritative.

Live browser reads require a page opened at `localhost`, `127.0.0.1`, or
`::1`; mutations additionally require the page's same-origin nonce. A reporter
connecting from a non-loopback address must send the configured token through
`PTC_VIEWER_TOKEN`. Generate a new value for each Viewer process, for example
with `openssl rand -hex 32`.

When a host-published port makes the browser's network peer non-loopback, open
the Live tab once with the same token:

```text
http://localhost:4123/?live_token=THE_TOKEN#/live
```

The page removes the query parameter after bootstrapping and authenticates all
Live API reads and mutations with the token. The SSE stream carries it in its
own encoded query because the browser EventSource API cannot set headers.

For Docker, keep the Viewer bound to `0.0.0.0` *inside* the container and keep
the published host port on loopback. Viewer-started runs report directly inside
the container process. A separately started run in the same container can
report over container loopback. A host-side run can use
`PTC_VIEWER_URL=http://127.0.0.1:4123`; another container must instead use the
Viewer container's service name on a shared Docker network (for example,
`PTC_VIEWER_URL=http://viewer:4123`) or an explicitly configured host-gateway
address. Both must set the matching `PTC_VIEWER_TOKEN`. This protects live
ingestion and browser mutations; it does not turn the trace browser into an
authenticated remote service, so `-p 4123:4123` remains unsafe.

## Test a workflow

Use deterministic fixtures for normal tests. Assert the business value and
semantic error classification, not timestamps, run references, or remaining
milliseconds.

One shell-level check can use the stable envelope:

```console
ptc init kernel-tutorial --example kernel-tutorial
artifact_dir="$(mktemp -d)"
envelope="$artifact_dir/command-envelope.json"
ptc run kernel-tutorial/01-orders/ptc.json --envelope "$envelope"
actual="$(jq -c '.result.value' "$envelope")"
test "$actual" = \
  '{"order_count":3,"paid_count":2,"paid_total":335.75,"pending_ids":["A-101"]}'
```

Test scripted model responses before a small live-provider boundary. The
[replay evaluation guide](../guides/evaluating-with-replay.md) shows the deterministic
path; the [Quickstart](../guides/quickstart.md) keeps one deliberately small live check.

## Next steps

- [Kernel REPL](repl.md) covers session and analysis modes.
- [Manifests and capabilities](application-manifest.md) defines the
  application boundary these commands enforce.
- [Host configuration](host-installation.md) defines provider installation.
- [Building agents](../guides/building-agents.md) explains the agent policy producing
  the runs.
