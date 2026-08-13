# Manifests and capabilities

A manifest declares one runnable PTC-Lisp application: code, input, provider
selections, limits, events, and optional trace labels. Loading is strict,
path-confined, and inert; it executes no workflow or provider callback.

The checked-in `priv/schemas/ptc-application-manifest.schema.json` is the
complete structural reference. `PtcRunner.Kernel.Manifest` remains
authoritative for semantic checks and referenced-file handling.

## Start with one workflow

```json
{
  "version": 1,
  "workflow": {
    "components": [
      {"id": "my.workflow", "path": "workflow.clj"}
    ],
    "entry": "my.workflow/run"
  },
  "input": {"value": {"question": "What should I process?"}}
}
```

The Kernel evaluates `(my.workflow/run data/input)`. The entry must be a
qualified public function that accepts the decoded input object. Unknown or
duplicate keys, unsafe paths, malformed identifiers, and invalid JSON values
are rejected before execution.

## Compose components and libraries

A local component declares its source and sorted, unique dependencies:

```json
{
  "id": "my.workflow",
  "path": "workflow.clj",
  "dependencies": ["my.helpers"]
}
```

Select an installed PTC-Lisp library by ID:

```json
{"library": "agent.core"}
```

Library dependencies expand deterministically. Local and installed components
compile into one immutable bundle. Missing dependencies, cycles, duplicate
selections, undeclared cross-component calls, and ID collisions fail before
the workflow runs. See [Components and preludes](components-and-preludes.md)
for bundle rules.

Public PTC-Lisp functions may declare input and output signatures:

```clojure
(ns tutorial.signatures "Small signed mission functions." {:visibility :prompt})

(defn double
  "Double one integer."
  {:signature "(value :int) -> :int"}
  [value]
  (* value 2))
```

The runtime validates inputs before the body and successful outputs afterward.
A pre-body contract failure is safe to correct; a failure after capability
activity is not automatically retried because repeating external effects may
be unsafe. Run the credential-free
[`05-signature-feedback`](../../examples/kernel-tutorial/05-signature-feedback/ptc.json)
example to see the correction flow. [Signature syntax](../signature-syntax.md)
defines the grammar.

## Supply input and named missions

Input is either an inline JSON object or a manifest-relative JSON object file:

```json
"input": {"value": {"task": "Summarize the report"}}
```

```json
"input": {"path": "input.json"}
```

Named missions isolate subordinate code, data, provider grants, inventory,
model context, and continuation state:

```json
"missions": {
  "reader": {
    "components": [{"id": "app.reader", "path": "reader.clj"}],
    "data": {"mode": "source"},
    "providers": ["reader_workspace"]
  },
  "writer": {
    "components": [{"id": "app.writer", "path": "writer.clj"}],
    "data": {"mode": "destination"},
    "providers": ["writer_workspace"]
  }
}
```

Mission provider names refer to unique occurrences already selected under
`providers.mission`; a mission can narrow authority but cannot introduce it.
`"default"` is an ordinary declared name, not an implicit fallback.
Definitions and `*1`/`*2`/`*3` history never cross between missions.

Workflow code selects the mission explicitly with the `kernel/eval*`,
`kernel/check-source`, or mission-introspection functions. The shipped
`agent.core` loop uses `"default"` only when its own mission option is omitted,
and that mission must exist. The
[`named-mission-reader-writer`](../../examples/named-mission-reader-writer/README.md)
example demonstrates distinct read and write grants.

All manifest references use portable, lowercase logical names and resolve
beneath the canonical manifest directory. Absolute paths, traversal, devices,
non-regular files, and symlink escape are rejected. These rules cover files
the host loads. Model-visible files require a separately installed and selected
provider such as the
[filesystem sample](../../examples/mcp/filesystem/README.md).

## Validate inputs and results

Use bounded manifest-relative JSON Schema contracts:

```json
"contracts": {
  "input_schema": {"path": "task.schema.json"},
  "result_schema": {"path": "candidate.schema.json"}
}
```

The input contract covers manifest input and command-line input overrides. It
is checked before preflight, credentials, processes, or discovery. The result
contract is checked after execution and evidence capture, but before stdout or
artifact publication. A mismatch returns `input_contract_failed` or
`result_contract_failed`; non-object input returns `input_invalid`.

The `agent.main/run` entry also gives a model-authored terminal candidate one
ordinary correction turn when budget remains. Feedback is schema-derived and
bounded: it may identify a safe declared path, missing required names, allowed
names, and an undeclared-name count, but never an undeclared submitted name or
value.

Contracts are closed object schemas by default. The profile supports common
object, array, scalar, enum, const, and bound keywords, plus the asserted
`sha256` string format. It also supports one root discriminated `oneOf` for
closed object branches. References, regexes, nested composition, union types,
and general-purpose `oneOf` are rejected.

See `PtcRunner.Kernel.ValueContract` for the exact schema profile and safe
failure projection. That module contract, rather than this guide, is the
canonical keyword and bound reference.

`--output PATH` atomically publishes only the validated result value without
replacing an existing file. Use `--private-output` for a private run; it
publishes an owner-only artifact and keeps the value off stdout. See
[Running and debugging](running-and-debugging.md#run-a-manifest) for destination
requirements.

## Select host-installed providers

A manifest selects public aliases; all credentials, endpoints, commands,
mappings, effects, and outer ceilings stay in the host document:

```json
"providers": {
  "workflow": [
    {"name": "deepseek", "config": {"default": true}},
    {"name": "frozen-model"}
  ],
  "mission": [
    {
      "name": "workspace",
      "config": {
        "allow": ["workspace.read", "workspace.write"],
        "model_visible": ["workspace.read"]
      }
    }
  ]
}
```

Multiple live or replay LLM aliases may be selected. At most one may be the
default. A request selects an alias with its `model` field; omitting it works
only when one alias is selected or a default is declared. Selection never
falls back implicitly.

For MCP, `allow` selects installed public names without changing their
operator-declared effects. It may be omitted only when every installed mapping
is read-only. If any mapping is a write, an explicit non-empty list is
required. `model_visible` may narrow discovery within the authorized names;
visibility never grants or denies call authority.

Native trace and inspection aliases derive six question-shaped capabilities:
`runs`, `overview`, `activity`, `conversation`, `failure`, and `source`.
Public trace sources provide public evidence and return
`evidence_unavailable` for private questions. An inspection alias composes its
required canonical trace snapshot with authorized private records. Set the
trace dependency's config to `{"expose": false}` when only the aggregate
inspection namespace should be callable.

Snapshot acquisition is fail closed and immutable: malformed, duplicate,
orphaned, or oversized evidence rejects the capture rather than exposing a
partial catalog. Private inspection also requires every selected provider to
accept the `private_inspection` data class before any directory opens.

Treat the workflow bundle and manifest as application code. Treat
model-generated source, mission input, file content, and provider output as
untrusted data. [Host configuration](host-configuration.md) documents the
operator side of every provider source.

## Narrow installed limits

Manifest limits are positive hard ceilings:

```json
"limits": {
  "run_duration_ms": 30000,
  "workflow_capability_calls": 16,
  "workflow_capability_calls_per_name": 8,
  "mission_capability_calls": 32,
  "subordinate_evaluations": 8,
  "subordinate_source_checks": 8,
  "terminal_result_bytes": 250000
}
```

The host installs maximums. A manifest may request a lower or equal value;
omission uses the normal runtime default capped by a lower installed ceiling.
Limits also bound time, heaps, concurrency, retained definitions/history,
source, capability values, and canonical events.

Installed-only operational timeouts cannot appear in a manifest. Consult
`PtcRunner.Kernel.LimitCatalog` for the complete names, defaults, ranges, and
scopes, and `PtcRunner.Kernel.Limits` for what each one bounds.

## Choose event privacy and labels

Normal canonical events are sanitized and bounded:

```json
"events": {"policy": "normal"}
```

`"private"` changes canonical trace discovery and sink requirements. It does
not create a prompt/response transcript. Exact model exchanges, generated
programs, connector payloads, and prints require the separate host-selected
inspection artifact; a manifest cannot enable or choose that destination.

Optional labels support trace grouping:

```json
"labels": {
  "name": "report-agent",
  "model": "deepseek",
  "provider": "openrouter",
  "tags": {"mode": "agent", "environment": "staging"}
}
```

Labels do not affect execution, authority, prompts, results, or provider
selection. `name`, `model`, and `provider` are fingerprinted in traces; tag
keys and values come from a small fixed vocabulary. Labels are application
claims, not authoritative provider identity. Use the provider snapshot and
canonical usage for accounting, and never put prompts, results, credentials,
paths, or arbitrary user text in labels.

## Next steps

- [Host configuration](host-configuration.md) defines the selected aliases.
- [Building agents](building-agents.md) puts model policy behind the grants.
- [Running and debugging](running-and-debugging.md) validates, runs, and
  inspects the manifest.
- [Components and preludes](components-and-preludes.md) explains bundle
  composition.

Exact manifest fields and failure contracts live in
`PtcRunner.Kernel.Manifest`.
