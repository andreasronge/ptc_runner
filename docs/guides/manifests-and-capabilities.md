# Manifests and capabilities

A version 1 JSON manifest is the deployable boundary for a PTC-Lisp project. It
selects code, data, installed providers, requested limits, event policy, and
optional trace labels. Loading is strict and performs no workflow execution.

## Smallest useful manifest

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

The Kernel generates `(my.workflow/run data/input)`. The entry must be a
qualified public function that accepts the decoded input object.

Unknown keys, duplicate JSON keys, unsafe paths, malformed identifiers, and
invalid JSON-like values are rejected before a run starts.

## Components and libraries

A local component names its source and sorted, unique dependencies:

```json
{
  "id": "my.workflow",
  "path": "workflow.clj",
  "dependencies": ["my.helpers"]
}
```

An installed PTC-Lisp library is selected by ID:

```json
{"library": "agent.core"}
```

Installed dependencies expand deterministically and enter the same immutable
bundle compiler as local components. Missing dependencies, cycles, duplicate
selections, undeclared cross-component calls, and local/library ID collisions
fail assembly.

## Test a signed mission function without a model

Public PTC-Lisp functions may declare input and output contracts. This mission
function accepts one integer and promises one integer:

```clojure
(ns tutorial.signatures "Small signed mission functions." {:visibility :prompt})

(defn double
  "Double one integer."
  {:signature "(value :int) -> :int"}
  [value]
  (* value 2))
```

The complete credential-free
[`05-signature-feedback`](../../examples/kernel-tutorial/05-signature-feedback/ptc.json)
example first evaluates the invalid model-style program
`(tutorial.signatures/double "21")`. The signature rejects the string before
the function body runs. Its workflow uses the same `agent.feedback` PTC-Lisp
library as `agent.core` to render the correction, then evaluates the corrected
program `(return (tutorial.signatures/double 21))`.

Run it from the repository root:

```console
mix ptc.run examples/kernel-tutorial/05-signature-feedback/ptc.json
```

The result contains the failed evaluation, the exact feedback an agent model
would receive, and the successful correction. The important fields are:

```json
{
  "invalid_evaluation": {
    "outcome": "evaluation_error",
    "kind": "prelude_contract_error",
    "retryable?": true,
    "details": {
      "ref": "tutorial.signatures/double",
      "phase": "input",
      "path": ["value"],
      "message": "prelude_contract_error: tutorial.signatures/double input value: expected int, got string"
    }
  },
  "model_feedback": "The PTC-Lisp evaluation did not return successfully. outcome=:evaluation_error; error_code=:prelude_contract_error; message=prelude_contract_error: tutorial.signatures/double input value: expected int, got string. Send one corrected run_ptc_lisp call.",
  "corrected_evaluation": {"outcome": "returned", "value": 42}
}
```

This correction is retryable because validation failed before the function
body and before any capability activity. A signed function also validates its
successful output. The agent loop does not automatically retry a contract
failure after capability activity, because repeating external effects may be
unsafe. See [Signature syntax](../signature-syntax.md) for the complete
signature grammar and [Kernel component bundles](capability-prelude.md) for the
runtime rules.

## Input and mission data

Input is either an inline JSON object or a manifest-relative JSON object file:

```json
"input": {"value": {"task": "Summarize the report"}}
```

```json
"input": {"path": "input.json"}
```

Optional mission data is separate from workflow input:

```json
"mission": {
  "components": [],
  "data": {"mode": "summary"}
}
```

Paths are resolved under the canonical manifest directory. Absolute paths,
traversal, devices, non-regular files, and symlink escapes are rejected.

Model-accessible filesystem operations use an MCP server installed by the
host. The shipped non-production sample freezes a bounded UTF-8 snapshot at
startup and serves list, search, and ranged-read tools without later
filesystem access.

## Input and result contracts

A manifest may validate its input and successful `Result.value` against
manifest-relative JSON Schema files:

```json
"contracts": {
  "input_schema": {"path": "task.schema.json"},
  "result_schema": {"path": "candidate.schema.json"}
}
```

The input contract covers inline input, an input file, and any `--mission` or
`--private-mission` override. It is compiled and checked before provider
preflight, credential resolution, process launch, or remote discovery. The
result contract is checked after execution and evidence capture, but before
stdout or `--output`/`--private-output` publication. A mismatch returns
`input_contract_failed` or `result_contract_failed`; a rejected result value is
not attached to the error.

Ordinary contracts are closed, bounded object schemas. The supported keywords
are `type`, `title`, `description`, `properties`, `required`,
`additionalProperties`, `items`, `enum`, `const`, numeric and length bounds.
Application contracts also allow one root `oneOf` containing 2–16 closed
object branches. Every branch must require the same single string
discriminator and give it a distinct `const` value:

```json
{
  "oneOf": [
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["decision", "reason"],
      "properties": {
        "decision": {"type": "string", "const": "no-change"},
        "reason": {"type": "string", "maxLength": 1000}
      }
    },
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["decision", "content"],
      "properties": {
        "decision": {"type": "string", "const": "propose-change"},
        "content": {"type": "string", "maxLength": 32000}
      }
    }
  ]
}
```

Contracts are at most 64 KiB after normalization. References, regexes, nested
composition, union types, and general-purpose `oneOf` are rejected. This
application profile does not widen MCP capability schemas.

`--output PATH` atomically writes only the validated `Result.value`, never
clobbers an existing file, and can be passed directly to a later run with
`--mission`. Use `--private-output` for a private run; it creates a `0600`
artifact and keeps the value off stdout.

## Providers are installed authority

The manifest selects providers by a bounded public name and JSON
configuration:

```json
"providers": {
  "workflow": [
    {"name": "deepseek"}
  ],
  "mission": [
    {
      "name": "workspace"
    }
  ]
}
```

Only builders installed by the host may be selected; no provider names are
implicit. The separate host JSON fixes models, commands, credentials,
endpoints, tool mappings, native PtcRunner sources, data classes, and outer
ceilings. A manifest cannot name an Elixir module or callback, launch a
command, include credentials, or choose an arbitrary endpoint. Placement is
enforced: LLM sources are workflow-only; MCP and native snapshot sources are
mission-only.

Canonical PtcRunner traces use a native immutable source rather than MCP:

```json
"history": {
  "source": "ptc_trace_snapshot",
  "directory": "traces",
  "ceilings": {
    "max_source_bytes": 8000000,
    "max_result_bytes": 250000
  }
}
```

The manifest selects `{"name": "history"}` in its mission providers. The
installed alias derives four fixed capabilities:
`history.list-runs`, `history.get-run`, `history.list-turns`, and
`history.counters`. Acquisition reads and validates the directory once;
subsequent queries use the frozen capture even if path contents change. The
safe provider snapshot includes counts, byte ceilings, and content identity,
but no path.

Private inspection artifacts use a separate paired native source:

```json
"private-history": {
  "source": "ptc_inspection_snapshot",
  "directory": "inspection",
  "ceilings": {
    "max_files": 100,
    "max_source_bytes": 64000000,
    "max_result_bytes": 500000
  }
}
```

A manifest selecting `private-history` must also select exactly one
`ptc_trace_snapshot` provider. Provider acquisition captures that canonical
trace first, then loads each regular `.inspection.jsonl` artifact once through
the authoritative inspection parser and validates every identity and
correlation against the captured trace. An orphan, duplicate run, malformed or
replaced artifact, incomplete input/output pair, ambiguous trace source, or
limit violation rejects the whole private snapshot. No partial catalog is
exposed.

The installed alias derives `list-runs`, `model-exchanges`,
`capability-calls`, `generated-sources`, `effective-preludes`, and
`provider-exchanges`. Collection results pair related records by their
correlation IDs and use deterministic bounded pages with source-bound opaque
cursors. V1 and V2 artifacts may share a directory: a V1 run has an empty
provider-exchange page, while V2 exposes each paired MCP request and response.
The source classifies the run as `private_inspection`, so every selected
provider must accept private data before either snapshot directory is opened.
Safe connector metadata contains only counts, byte ceilings, trace/content
identities, and hashes—not paths or private payloads.

`model_visible` controls whether a capability appears in model context. It
does not grant or remove execution authority.

## Requested limits narrow host ceilings

All limits are positive hard ceilings. A manifest may request lower values:

```json
"limits": {
  "run_duration_ms": 30000,
  "workflow_capability_calls": 16,
  "workflow_capability_calls_per_name": 8,
  "mission_capability_calls": 32,
  "subordinate_evaluations": 8,
  "terminal_result_bytes": 250000
}
```

The installation controls the maximum allowed values. A manifest cannot raise
them. Omitted values use normal runtime defaults capped by any lower installed
ceiling.

Limits cover the complete run, workflow and mission evaluations, process heap,
source, retained continuation memory, provider concurrency and calls,
capability arguments/results, terminal results, and canonical events.

## Events and inspection

Normal canonical events are sanitized and bounded:

```json
"events": {"policy": "normal"}
```

A private canonical event policy changes sink and discovery behavior but does
not turn events into a prompt/response transcript:

```json
"events": {"policy": "private"}
```

Exact model exchanges, generated programs, and connector payloads require the
separate host-selected inspection artifact. The manifest cannot enable or
choose that destination.

## Optional labels for trace queries

Labels do not affect execution, authority, prompts, results, or provider
selection. Most small manifests should omit them. Add labels when one trace
directory contains many runs and you need to group or filter those runs in the
log-analysis REPL or Viewer.

Labels are supplied by the manifest author; they are not inferred from the
selected providers and the Kernel does not treat them as authoritative. Use
the actual provider configuration and canonical capability events for runtime
accounting or security decisions.

Labels live at the manifest's top level. The loader validates them once and
copies their normalized form into the canonical `run-started` event:

```json
"labels": {
  "name": "report-agent",
  "model": "deepseek",
  "provider": "openrouter",
  "tags": {"mode": "summary"}
}
```

The fields have different purposes:

- `tags` are readable, queryable categories from a fixed vocabulary, such as
  `mode=agent`, `mode=deterministic`, or `environment=staging`;
- `name`, `model`, and `provider` let trusted tooling correlate equal
  identifiers without publishing them as plain text. The trace stores only
  their SHA-256 fingerprints.

For example, this query selects deterministic runs by their readable tag:

```clojure
(log/runs {"tags" {"mode" "deterministic"}})
```

Use labels when operational trace classification is useful; omit them when it
is not. They are deliberately not a general metadata map: keys and tag values
come from a finite vocabulary, identifier strings are bounded and
fingerprinted, and prompts, results, credentials, paths, and arbitrary user
text do not belong there.

Exact field and failure contracts live in the
`PtcRunner.Kernel.Manifest` module documentation. The
[Kernel maintainer guide](kernel-maintainer.md) describes provider installation
and ownership.
