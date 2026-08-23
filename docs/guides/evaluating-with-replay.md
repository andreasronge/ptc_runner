# Evaluate changes with replay

Compare an agent prompt or prelude change against fixed model responses before
deciding whether to promote it.

Live model output drifts between runs, while
the `llm_replay` provider holds model
responses fixed so a difference between a baseline and candidate run can be
attributed to the candidate component rather than another model sample.

Replay changes neither the manifest grammar nor the application's model alias.
Replace the installed provider behind that alias in `ptc-host.json`.

## Run the network-free example

The checked-in example needs no credential or network access:

<!-- ptc-guide-e2e: id=guide-replay-frozen-answer frontend=mix scratch=replay-example -->
```console
ptc init replay-example --example llm-replay
ptc run replay-example/ptc-project.json
```

```json
{"content":"Frozen answer","model":"frozen-model"}
```

The project records private inspection and grants it to the Viewer:

```console
ptc viewer replay-example/ptc-project.json
```

## Install a replay model

The host document names a JSON Lines fixture:

```json
"frozen-model": {
  "source": "llm_replay",
  "installation_revision": "frozen-model-v1",
  "fixtures": "evaluation/replay.jsonl"
}
```

Every fixture line has `schema_version` 1, a deterministic hash of the
provider-neutral request, and exactly one `response` or ordered `responses`
field:

```json
{"schema_version":1,"request_hash":"sha256:0000000000000000000000000000000000000000000000000000000000000000","response":{"content":"frozen"}}
```

Plain doctor parses the selected fixture under installed ceilings without
starting the provider:

```console
ptc doctor replay-example/ptc-project.json
```

A missing, empty, malformed, duplicate, or oversized fixture set fails its
local provider check as `fixtures_unreadable`, and the message names the rule
the file broke. A line-level rejection names the line as well:

```text
replay fixture line 3 must set schema_version to 1
```

The line number is the number in the file, counting blank lines. Nothing the
line contains is published — only which rule it broke.

`ptc validate` reads the same file under the same ceilings, so a manifest and
host document that validate cannot fail on the fixture when `run` reaches it.
The remaining local checks — an installed model's adapter, an MCP server's
executable — stay out of `validate`: whether they are present says nothing
about whether the documents are well formed.

## Author fixtures from exact requests

Start with any schema-valid placeholder hash and the response shape the
workflow expects. A normal-data miss reports:

```text
no replay fixture matches this request (request_hash: sha256:...)
```

Copy that hash into the fixture and rerun. For private-data requests, publish an
owner-only inspection artifact and read the hash from its capability record;
the public diagnostic intentionally omits the unsalted value.

Matching is exact, so an edited request misses rather than quietly reusing the
wrong response. A miss is a provider error returned as a value, not a failed
evaluation — the shipped `llm-replay` example calls `cap/unwrap!` so a miss
still exits non-zero. The [host-configuration
reference](../reference/host-installation.md#choose-a-provider-source) states
what a miss records.

An ordered `responses` sequence supports workflows that make the same request
more than once.

## Evaluate the candidate without installing it

`--component-override-descriptor` replaces one component already selected by
the manifest. A transitively selected component is also eligible, so selecting
`agent.core` makes its `agent.prompt` dependency available as a workflow
override target.

The descriptor binds the candidate to the installed source it replaces and to
the exact candidate bytes. It cannot add a component, change dependencies, or
grant a provider. The replacement still passes compilation, dependency,
signature, export, capability-requirement, and bundle checks. A refused
descriptor names the field it broke (`base_source_hash`, `source_hash`,
`component_id`, or `path`) rather than collapsing every mistake into one
sentence. See the
[component reference](../reference/component-contracts.md#evaluate-one-replacement-component)
for every descriptor field and validation rule.

Candidate creation is a trusted build step and is not currently exposed by the
standalone executable. The source-checkout tool for maintainers is documented
under "Materialize candidate source" in `docs/maintainers/embedding.md`, which
is a repository document rather than a page the executable carries.

The active bundle stays immutable for the whole run. A run may author source,
but only a later host invocation can materialize it and start with the newly
compiled bundle. Component-override switches are invocation-only and are not
stored in `ptc-project.json`.

Run the unchanged baseline and the override with the same replay installation,
inputs, host ceilings, and content snapshots. Compare their values, envelopes,
usage, and traces. Replay removes model sampling as a variable; it
does not make external MCP content deterministic unless that content is also
frozen and identified.

## Next steps

- [Components and preludes](components-and-preludes.md) defines component
  identity, dependencies, exports, and signatures.
- [Running and debugging](running-and-debugging.md) documents override switches,
  artifacts, traces, and private inspection.
- [Kernel limits](../kernel-limits-reference.md) lists every run ceiling that
  must remain comparable between evaluations.
