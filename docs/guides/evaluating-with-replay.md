# Evaluate changes with replay

> **Audience:** application authors comparing an agent prompt or prelude change
> against fixed model responses before an explicit promotion decision.

Live model output drifts between runs. The `llm_replay` provider holds model
responses fixed so a difference between a baseline and candidate run can be
attributed to the candidate component rather than another model sample.

Replay changes neither the manifest grammar nor the application's model alias.
The operator swaps the installed provider behind that alias.

## Run the network-free example

The checked-in example needs no credential or network access:

```console
ptc run examples/llm-replay/ptc.json \
  --host-config examples/llm-replay/ptc-host.json
```

```json
{"content":"Frozen answer"}
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
ptc doctor examples/llm-replay/ptc.json \
  --host-config examples/llm-replay/ptc-host.json
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

Matching is exact. Changed messages, tools, or provider-neutral parameters
produce another hash and fail instead of silently consuming unrelated evidence.
An ordered `responses` sequence supports workflows that make the same request
more than once.

## Evaluate the candidate without installing it

`--component-override-descriptor` replaces one component already selected by
the manifest:

```json
{
  "target": {"environment": "workflow"},
  "component_id": "my.agent",
  "base_source_hash": "sha256:<64 lowercase hex>",
  "source_hash": "sha256:<64 lowercase hex>",
  "path": "candidate.clj"
}
```

For a mission component, use
`{"environment": "mission", "mission": "reader"}` as the target. The
candidate path is confined to the descriptor directory. `source_hash`
identifies the candidate bytes; `base_source_hash` prevents evaluation against
a component version from which it was not derived. Dependencies, signatures,
exports, and capability requirements are checked normally.

Candidate creation is a trusted build step and is not currently exposed by the
standalone executable. The source-checkout tool for maintainers is documented
under [Embedding and host APIs](../maintainers/embedding.md#materialize-candidate-source).

The optional closed `provenance` object may contain `run_id`, `prompt_hash`,
`authored_at`, and `accept_widened_effect`. These are operator claims rather
than proof of origin.

Run the unchanged baseline and the override with the same replay installation,
inputs, host ceilings, and content snapshots. Compare their values, envelopes,
usage, and canonical traces. Replay removes model sampling as a variable; it
does not make external MCP content deterministic unless that content is also
frozen and identified.

## Next steps

- [Components and preludes](components-and-preludes.md) defines component
  identity, dependencies, exports, and signatures.
- [Running and debugging](running-and-debugging.md) documents override switches,
  artifacts, traces, and private inspection.
- [Kernel limits](../kernel-limits-reference.md) lists every run ceiling that
  must remain comparable between evaluations.
