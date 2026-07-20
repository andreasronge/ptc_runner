# Manifests and capabilities

A version 1 JSON manifest is the deployable boundary for a PTC-Lisp project. It
selects code, data, installed providers, requested limits, event policy, and
safe labels. Loading is strict and performs no workflow execution.

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

## Safe labels

Labels are restricted to a closed metadata shape:

```json
"labels": {
  "name": "report-agent",
  "model": "deepseek",
  "provider": "openrouter",
  "tags": {"mode": "summary"}
}
```

Identifier fields are fingerprinted and tags use finite values before entering
canonical events. Do not use labels for prompts, results, credentials, or
arbitrary user text.

Exact field and failure contracts live in the
`PtcRunner.Kernel.Manifest` module documentation. The
[Kernel maintainer guide](kernel-maintainer.md) describes provider installation
and ownership.
