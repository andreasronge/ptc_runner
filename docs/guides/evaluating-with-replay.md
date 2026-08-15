# Evaluate changes with replay

Live model output drifts between runs. The `llm_replay` provider holds model
responses fixed so a difference between a baseline and candidate run can be
attributed to the candidate component rather than another model sample.

Replay changes neither the manifest grammar nor the application's model alias.
The operator swaps the installed provider behind that alias.

## Run the network-free example

The checked-in example needs no credential or network access:

<!-- ptc-guide-e2e: id=replay-frozen-answer -->
```console
mix ptc run examples/llm-replay/ptc.json \
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
mix ptc doctor examples/llm-replay/ptc.json \
  --host-config examples/llm-replay/ptc-host.json
```

A missing, empty, malformed, duplicate, or oversized fixture set fails its
local provider check as `fixtures_unreadable`.

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

## Materialize candidate source

A runtime `defn` lasts only for its run. Materialize model-authored source when
it should become a candidate component for a later evaluation:

```console
mix ptc.materialize ptc.json \
  --workflow \
  --component my.helper \
  --out private/candidate \
  --source authored.clj \
  --origin-run-id run-2026-08-03-0001
```

Select exactly one target with `--workflow` or `--target-mission NAME`.
Candidate source comes from `--source`, or from one string selected with
`--from-result PATH --result-pointer POINTER`. The new directory and its source
and descriptor files are owner-only and never replace existing paths.

The gate re-acquires the candidate through its descriptor, verifies that it
compiles, requires prompt-visible exports to have signatures and docstrings,
and compares every export's reachable effects with its base. Effect widening is
refused unless `--accept-widened-effect` records an explicit operator decision.
The task creates evidence; it never installs the candidate or acquires a
provider.

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
