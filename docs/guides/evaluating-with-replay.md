# Evaluate changes with replay

Compare a prompt or prelude change against fixed model responses before you
decide whether to keep it.

Live model output changes between runs. The `llm_replay` provider answers each
request from a fixture instead, so a difference between a baseline run and a
candidate run comes from the candidate rather than from another model sample.
Replay changes nothing in the manifest: you replace the provider behind the
model alias in `ptc-host.json`.

## Run the network-free example

<!-- ptc-guide-e2e: id=guide-replay-frozen-answer frontend=mix scratch=replay-example -->
```console
ptc init replay-example --example llm-replay
ptc run replay-example/ptc-project.json
```

```json
{"content":"Frozen answer","model":"frozen-model"}
```

The project retains private inspection and grants it to the Viewer:

```console
ptc viewer replay-example/ptc-project.json
```

## Install a replay model

The host document points the alias at a JSON Lines fixture file:

```json
"frozen-model": {
  "source": "llm_replay",
  "installation_revision": "frozen-model-v1",
  "fixtures": "evaluation/replay.jsonl"
}
```

Each line carries `schema_version` 1, the hash of the request it answers, and
one `response`, or an ordered list of `responses` for a request the workflow
makes more than once:

```json
{"schema_version":1,"request_hash":"sha256:0000000000000000000000000000000000000000000000000000000000000000","response":{"content":"frozen"}}
```

`ptc doctor` and `ptc validate` both read the fixture file, so a broken file
fails before a run starts. The
[host reference](../reference/host-installation.md#choose-a-provider-source)
lists the rules a fixture file must follow.

## Write a fixture from a real request

Start with a placeholder hash and the response shape you want. The first run
misses and prints the hash it looked for:

```text
no replay fixture matches this request (request_hash: sha256:...)
```

Copy that hash into the fixture and run again. Matching is exact, so an edited
prompt misses instead of reusing an old answer. When the request carries
private data the hash is not printed; follow
[Inspect a private model conversation](../reference/cli.md#inspect-a-private-model-conversation)
to read it from the private record.

A miss reaches the workflow as a provider error value. The shipped
`llm-replay` example calls `cap/unwrap!` so a miss still fails the run.

## Evaluate the candidate without installing it

Export the component you want to change, edit the copy, and publish it as a
candidate, as shown in
[Inspect and customize components](components-and-preludes.md#change-the-prompt-on-a-run).
Then run the baseline and the candidate with the same replay installation,
input, host ceilings, and content snapshots:

```console
ptc run ptc-project.json
ptc run ptc-project.json \
  --component-override-descriptor private/agent-prompt-candidate/descriptor.json
```

Compare the values, envelopes, usage, and traces. The descriptor replaces one
component the manifest already selects, including one selected through a
dependency such as `agent.prompt`. It cannot add a component, change
dependencies, or grant a provider; the
[component reference](../reference/component-contracts.md#evaluate-one-replacement-component)
lists its fields and validation rules.

Replay removes model sampling as a variable, but every model-visible
observation must remain stable. For details, see the
[exact request-matching requirement](../reference/host-installation.md#choose-a-provider-source).

## Next steps

- [Inspect and customize components](components-and-preludes.md) has the
  materialize and validate commands.
- [Kernel limits](../kernel-limits-reference.md) lists the ceilings that must
  stay equal between the two runs.
