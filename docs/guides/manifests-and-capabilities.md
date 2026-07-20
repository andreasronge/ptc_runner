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
      {"id": "my.workflow", "path": "workflow.lisp"}
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
  "path": "workflow.lisp",
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
unsafe. See [Kernel component bundles](capability-prelude.md) for the complete
signature grammar and runtime rules.

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

The built-in `file-read` provider freezes a bounded UTF-8 file snapshot during
manifest assembly. Agent calls read that immutable snapshot and perform no
runtime filesystem access, so later file, directory, or root replacement
cannot change the granted contents.

## Providers are installed authority

The manifest selects providers by a bounded public name and JSON
configuration:

```json
"providers": {
  "workflow": [
    {"name": "llm", "config": {"model": "deepseek", "cache": false}}
  ],
  "mission": [
    {
      "name": "file-read",
      "config": {"root": "files", "max_bytes": 65536}
    }
  ]
}
```

Only builders installed by the host may be selected. A manifest cannot name an
Elixir module or callback, launch a command, include credentials, or choose an
arbitrary endpoint. Provider placement is also enforced: the built-in model
provider is workflow-only and file access is mission-only.

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
