# LLM replay

This example serves one provider-neutral language-model response from a local
JSON Lines fixture. It needs no credential and performs no network activity.

Run it from the repository root:

```console
ptc init llm-replay --example llm-replay
ptc run llm-replay/ptc.json \
  --host-config llm-replay/ptc-host.json
```

The result is:

```json
{"content":"Frozen answer"}
```

Change the request in `workflow.clj` to see the replay-miss error and its new
`request_hash`. Copy that hash into `replay.jsonl` to match the changed request.
