# Manifests and capabilities

A manifest is a JSON file you write to declare one runnable PTC-Lisp
application: its code, its data, the providers it needs, the limits it wants,
its event policy, and optional trace labels. Because it declares everything a
run may use, it is also the boundary you deploy and review — nothing outside it
reaches the run. Loading it is strict and executes no workflow.

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

A library's own dependencies expand deterministically, and everything compiles
into one immutable bundle alongside your local components. Missing
dependencies, cycles, duplicate selections, undeclared cross-component calls,
and collisions between a local ID and a library ID all fail assembly.

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
signature grammar and [Components and preludes](components-and-preludes.md) for
the runtime rules. [Building agents](building-agents.md) documents the
correction protocol that renders this feedback for a live model.

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

Referenced files use portable lowercase ASCII logical names. A name is at most
1,024 bytes and 16 slash-separated segments; every segment starts with a
lowercase letter or digit and otherwise contains only lowercase letters,
digits, `.`, `_`, or `-`. Paths are resolved under the canonical manifest
directory. Absolute paths, empty or dot segments, Unicode, uppercase names,
devices, non-regular files, and symlink escapes are rejected. The same grammar
applies to component, input, contract, and trusted override candidate names.
For an in-memory application whose manifest logical name has directory
segments, those references are resolved relative to the manifest's logical
directory, exactly like the filesystem adapter. That transport prefix does not
consume the referenced name's 1,024-byte or 16-segment application limit.
When a directory-backed override descriptor and candidate are inside that
application directory, they use the same logical-document cache as manifest
references. A candidate that is also a selected component document is captured
and charged once, matching the in-memory adapter. Candidate resolution still
uses the descriptor's own directory as its confinement boundary; entering the
shared cache does not widen that authority.

Those rules govern files the host reads while loading the manifest. Files the
*model* can reach are separate and never come from the manifest: they come from
an MCP server the host installs. The
[filesystem sample server](../../examples/mcp/filesystem/README.md) is a
non-production example of one, used by the tutorials and integration tests.
[Host configuration](host-configuration.md#mcp-servers) covers installing it.

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
stdout or `--output`/`--private-output` publication. The shipped
`agent.main/run` entry also checks each model-authored terminal candidate while
the bounded agent loop is still live. When turns remain, it returns the same
structural classification to the model for one ordinary correction turn; the
rejected value itself is withheld. Other workflow entries retain only the
final fail-closed check. A mismatch returns `input_contract_failed` or
`result_contract_failed`. A selected input that is not an admissible JSON
object instead returns `input_invalid`, even when no input contract is
declared.

A rejection does carry a bounded classification, so a mismatch is diagnosable
without repeating the run under private inspection. The command reports it as:

```text
{:error,
 {:result_contract_failed,
  %{value_kind: :object, discriminator: "decision", matched_branch: "no-change",
    missing_required: [], undeclared_key_count: 0,
    violations: [
      %{segments: [{:property, "rationale"}], kind: :maxLength},
      %{segments: [{:property, "evidence"}, {:index, 0}], kind: :required}
    ]}}}
```

One common failure has nothing to do with your schema. Before any schema
keyword runs, the value must be JSON-like, and a PTC-Lisp map with keyword keys
is not — so a workflow returning `{:decision "no-change"}` instead of
`{"decision" "no-change"}` fails this guard. That rejection produces no
violations at all, which is how you recognize it: `json_value: false` with an
empty `violations` list means keyword keys, not a schema mismatch.

`violations` locates each failure by schema keyword and a typed property/index
segment list within the branch the discriminator selected; branches it did not
select are omitted, since they fail on keys they were never given. Segments are
retained only while the exact local schema node declares that property or array
index. At the first undeclared or structurally inconsistent segment,
classification stops at the safe parent, so caller-authored property names
never enter the report.

Every other name comes from the compiled schema too: the discriminator, the
branch whose `const` the value carried, and that branch's unmet `required` keys
as `missing_required`. The value contributes only its JSON kind and
`undeclared_key_count`, a number. The rejected value and its field values stay
out of the error entirely.

Ordinary contracts are closed, bounded object schemas. The supported keywords
are `type`, `title`, `description`, `properties`, `required`,
`additionalProperties`, `items`, `enum`, `const`, numeric and length bounds.
String schemas may additionally use the single asserted
`"format": "sha256"` for an algorithm-qualified lowercase digest; arbitrary
formats and regexes remain outside the profile.
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
composition, union types, and general-purpose `oneOf` are rejected. Apart from
the shared bounded `sha256` format, this application profile does not widen
MCP capability schemas.

`--output PATH` atomically writes only the validated `Result.value`, never
clobbers an existing file, and can be passed directly to a later run with
`--mission`. Use `--private-output` for a private run; it creates a `0600`
artifact and keeps the value off stdout. Destination conflicts and
normal/private class mismatches are rejected before provider acquisition, while
exclusive creation remains authoritative if the path appears during the run.
Artifact publication currently requires a Unix host and POSIX-compatible
`mkdir` and `id` executables on `PATH`. It fails closed if those authority and
mode-at-create primitives are unavailable, rather than briefly exposing
content through a wider default mode.

## Providers come from the host, not the manifest

A manifest cannot create a provider. It can only select one the operator
already installed, by its public name plus JSON configuration:

```json
"providers": {
  "workflow": [
    {"name": "deepseek"}
  ],
  "mission": [
    {
      "name": "workspace",
      "config": {
        "allow": ["workspace.read", "workspace.write"]
      }
    }
  ]
}
```

A name is all a manifest gets. The credentials, endpoints, commands, and tool
mappings behind that name live in the host JSON, so a manifest cannot reach past
its selection to launch a command, supply a credential, or point a provider
somewhere else. Placement is fixed too: LLM providers are workflow-only, MCP and
native snapshot providers mission-only.

For MCP, `allow` selects installed public names without changing their
operator-declared effects. An all-read installation may omit `allow` to select
every mapping. But if the installation contains even one write mapping, `allow`
becomes mandatory and non-empty — so adding a write mapping breaks an unchanged
manifest that relied on implicit selection instead of silently widening its
authority.

The optional `model_visible` list may only narrow the names the host already
marked visible. Visibility is not authority in either direction: a granted
capability the model cannot see stays callable by exact name, and an ungranted
one stays denied no matter how visible it is.

[Host configuration](host-configuration.md) is the operator reference for the
host JSON itself: credentials, all five provider sources, transports, tool
mappings, data classes, and installed ceilings.

Two providers are native rather than MCP, and both serve PtcRunner's own
evidence back to a mission. A `ptc_trace_snapshot` alias named `history` derives
`history.list-runs`, `history.get-run`, `history.list-turns`, and
`history.counters`. A `ptc_inspection_snapshot` alias derives `list-runs`,
`model-exchanges`, `capability-calls`, `generated-sources`,
`effective-preludes`, and `provider-exchanges`.
[Kernel REPL](kernel-repl.md#private-inspection-mission-sessions) shows the
queries in use, and the
[TraceLog contract](../trace-log-contract.md#query-contract) is normative for
paging and bounds.

Four properties matter when selecting them. Each reads its directory once, so an
agent querying the trace of its own run sees a stable catalog instead of its own
writes. An inspection snapshot never stands alone: it requires exactly one trace
snapshot to validate against, and one orphaned, duplicated, malformed, or
oversized artifact rejects the whole private catalog rather than exposing part of
it. Because inspection data classifies the run as `private_inspection`, every
other selected provider must accept private data before either directory is
opened. And neither provider's safe snapshot contains its directory path — only
counts, ceilings, and content identity — so publishing a snapshot does not
disclose where the evidence lives.

That yields a simple trust boundary. Treat the workflow bundle and the manifest
as application code. Treat model-generated source, mission input, file content,
and provider output as untrusted data.

## Requested limits narrow host ceilings

All limits are positive hard ceilings. A manifest may request lower values:

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

The installation sets the maximum for each one, and a manifest can only request
that value or less. An omitted limit takes the normal runtime default, capped by
any lower installed ceiling.

Limits reach further than those shown above: they also bound process heap,
source size, retained continuation memory, provider concurrency, capability
arguments and results, and canonical events.
`subordinate_source_checks` is independent of `subordinate_evaluations` and
mission capability quotas because a check compiles but never executes source.

The host-only `provider_cleanup_timeout_ms`, `local_preflight_timeout_ms`,
`selection_validation_timeout_ms`, and `doctor_connectivity_timeout_ms` names
are deliberately absent from the application schema. A manifest that declares
one is rejected rather than narrowing host-owned operational policy.

The compiled ceilings suit one bounded run. An agent that must work for hours
needs more turns, model calls, and trace events than they allow, and only the
operator can raise that — requesting more here than the host installed is
rejected. Even after the operator raises a ceiling, a manifest that wants the
larger budget must still ask for it.
[Host configuration](host-configuration.md#installed-ceilings) lists every
installable name.

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

Labels are one optional block at the manifest's top level. The loader validates
them once and copies their normalized form into the canonical `run-started`
event:

```json
"labels": {
  "name": "report-agent",
  "model": "deepseek",
  "provider": "openrouter",
  "tags": {"mode": "summary"}
}
```

They exist for one job: grouping and filtering runs when a single trace
directory holds many of them, in the log-analysis REPL or the Viewer. They
affect nothing else — not execution, authority, prompts, results, or provider
selection — so most small manifests should omit them entirely.

Because the manifest author supplies labels, the Kernel does not treat them as
authoritative. They are never inferred from the providers actually selected, so
a label claiming `"model": "deepseek"` proves nothing about which model ran. For
runtime accounting or security decisions, read the real provider configuration
and the canonical capability events instead.

The fields serve different purposes:

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

## Next steps

- [Host configuration](host-configuration.md) is the operator half — what the
  aliases selected here actually resolve to.
- [Building agents](building-agents.md) puts model policy behind these grants.
- [Running and debugging](running-and-debugging.md) runs a manifest and reads
  the traces, results, and inspection artifacts it declares.
- [Components and preludes](components-and-preludes.md) covers the bundle
  rules behind the `components` key.

Exact field and failure contracts live in the
`PtcRunner.Kernel.Manifest` module documentation. The
[Kernel maintainer guide](kernel-maintainer.md) describes provider installation
and ownership.
