# Application-manifest reference

This is the complete contract for `ptc.json`.

A manifest declares one runnable
PTC-Lisp application: code, input, provider
selections, limits, events, and optional trace labels. Loading is strict,
path-confined, and inert; it executes no workflow or provider callback.

The JSON Schema served as `ptc docs schema-manifest`
(`priv/schemas/ptc-application-manifest.schema.json` in the repository) is the
complete structural reference. Runtime loading additionally performs semantic
checks and path-confined referenced-file handling. Manifest
schema diagnostics include a safe JSON Pointer when one is available; a
missing-required diagnostic points to the absent schema-declared property.
The message also names the bounded JSON Schema rule (`type`, `pattern`,
`maximum`, `required`, or another supported rule) without copying the rejected
value or an unknown caller-authored key. Paths through named maps use `*` for
the caller-selected name, and an unknown property stops at its schema-owned
parent.

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
the workflow runs. See [Components and preludes](component-contracts.md)
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
[`05-signature-feedback`](https://github.com/andreasronge/ptc_runner/blob/main/examples/kernel-tutorial/05-signature-feedback/ptc.json)
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
[`named-mission-reader-writer`](https://github.com/andreasronge/ptc_runner/tree/main/examples/named-mission-reader-writer)
example demonstrates distinct read and write grants.

All manifest references use portable, lowercase logical names and resolve
beneath the canonical manifest directory. Absolute paths, traversal, devices,
non-regular files, and symlink escape are rejected. These rules cover files
the host loads. The manifest path itself is selected by the caller and its
basename does not have to use the logical-name grammar. Model-visible files
require a separately installed and selected provider such as
[ptc-fs-mcp](mcp.md#run-the-checked-in-file-agent).

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
`result_contract_failed`; non-object input returns `input_invalid`. When the
safe failure projection identifies a non-root declared path, the command
envelope and terminal diagnostic include its JSON Pointer. Terminal rendering
escapes unusual contract-authored property names rather than emitting their
control bytes. Missing-required failures name the first missing schema-declared
property, including when the absent property is at the contract root.

Terminal agent helpers also give a model-authored candidate one ordinary
correction turn when budget remains. `agent.core/run` validates the exact
final value it returns — the standard success envelope by default, or the
raw object when `result_envelope` is false. `agent.main/run` and
`agent.core/run-result-value` validate the raw model-authored value, which is
the right contract when that raw value is itself the application result.
Feedback is schema-derived and bounded: it may identify a safe declared path,
missing required names, allowed names, and an undeclared-name count, but never
an undeclared submitted name or value.

Applications may additionally declare up to 16 named non-final handoff
contracts under `contracts.phase_return_schemas`, using the same
`{"path": "..."}` reference shape. A non-final agent phase selects one with
`return_contract`. The active contract is rendered in that phase's prompt and
requires an explicit contract-valid return before transition. Final phases
cannot select a phase-return contract; they continue to use `result_schema`.

Each renderer-neutral prompt projection is limited to 262,144 encoded bytes.
The result projection and every declared phase-return projection are charged,
once per declaration, to a 1,048,576-byte application aggregate. Overflow is
rejected during inert acquisition as
`application/contract_projection_limit_exceeded`.

Contracts are closed object schemas by default. The profile supports common
object, array, scalar, enum, const, and bound keywords, plus the asserted
`sha256` string format. It also supports one root discriminated `oneOf` for
closed object branches. References, regexes, nested composition, union types,
and general-purpose `oneOf` are rejected.

Two edges are worth knowing before you write one. `enum` and `const` must carry
a sibling `type`, so `{"enum": ["a", "b"]}` is rejected and
`{"type": "string", "enum": ["a", "b"]}` is accepted. The accepted bounds are
`minimum`, `maximum`, `minLength`, `maxLength`, `minItems`, and `maxItems`;
`exclusiveMinimum` and `exclusiveMaximum` are not in the profile.

The supported keyword profile above is deliberately closed. Unsupported schema
composition is rejected during inert application loading rather than being
partially interpreted at runtime. A `contract_invalid` rejection names the rule
it broke and the JSON Pointer of the offending node inside the schema document
— for example `contract schema declares an unsupported "type" at
/properties/sum/type in result.schema.json` — so a misspelled type, a keyword
outside the profile, and an unsatisfiable bound are told apart without
bisecting the schema. Every reported segment is a key or index the submitted
document carries, and the same pointer appears in the envelope's `path`.

`--output PATH` atomically publishes only the validated result value without
replacing an existing file. Use `--private-output` for a private run; it
publishes an owner-only artifact and keeps the value off stdout. See
[Running and debugging](cli.md#run-a-manifest) for destination
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
falls back implicitly. Each selected alias may set `config.max_calls` to cap
requests to that model; the host install's `ceilings.max_calls` is the outer
ceiling (catalog default 2048 when omitted). An alias cap binds only when it is
stricter than the public `llm-request` per-name budget.

For MCP, `allow` selects installed public names without changing their
effects declared in `ptc-host.json`. It may be omitted only when every installed mapping
is read-only. If any mapping is a write, an explicit non-empty list is
required. `model_visible` may name any subset of the authorized `allow` names,
including mappings whose host `model_visible` flag is false. Omitted, it
defaults to the authorized names the host already marked visible. Visibility
never grants or denies call authority.

Native trace and inspection aliases derive four navigation capabilities:
`runs`, `open`, `read`, and `counters`. `open` advertises the named collections
and their filters; `read` returns one native bounded page; `counters` returns
the captured trace aggregate, including adapter-attested model usage. Public
trace sources provide the `activity` collection and return
`evidence_unavailable` for private collections. An inspection alias composes
its required trace snapshot with authorized private records. Set the
trace dependency's config to `{"expose": false}` when only the aggregate
inspection namespace should be callable.

Trace-directory acquisition is immutable: stable malformed, duplicate, or
identity-conflicting trace files isolate their connected component while
disjoint valid runs remain available. Namespace mutation and whole-source
limits reject the capture rather than installing a partial generation.
Inspection snapshots remain fail closed for malformed, duplicate, orphaned, or
oversized private inspection records. Private inspection also requires every
selected provider to accept the `private_inspection` data class before any
directory opens.

Treat the workflow bundle and manifest as application code. Treat
model-generated source, mission input, file content, and provider output as
untrusted data. [Host configuration](host-installation.md) documents the
installed side of every provider source.

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
source, capability values, and trace events.

Optional rows such as `llm_total_tokens`, `llm_cost_microusd`,
`workflow_loop_iterations`, and `evaluation_loop_iterations` stay disabled
until the host enables them. A manifest cannot turn a host-disabled optional
limit on; it may only inherit or narrow an enabled host value.

Installed-only operational timeouts cannot appear in a manifest. The generated
[Kernel limits reference](../kernel-limits-reference.md) lists every name,
meaning, unit, default, range, and scope.

## Choose event privacy and labels

Trace events are sanitized and bounded:

```json
"events": {"policy": "normal"}
```

`"private"` changes trace discovery and sink requirements. It does
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

- [Host configuration](host-installation.md) defines the selected aliases.
- [Building agents](../guides/building-agents.md) puts model policy behind the grants.
- [Running and debugging](cli.md) validates, runs, and
  inspects the manifest.
- [Components and preludes](component-contracts.md) explains bundle
  composition.

The generated application-manifest schema is the exact field reference; this
guide documents the additional semantic and authority rules applied at load.
