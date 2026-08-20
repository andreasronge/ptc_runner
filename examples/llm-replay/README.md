# LLM replay

This example serves one provider-neutral language-model response from a local
JSON Lines fixture. It needs no credential and performs no network activity.

Run it from the repository root:

```console
ptc init llm-replay --example llm-replay
ptc run llm-replay/ptc-project.json
```

The project document remembers the host installation. `ptc run llm-replay/ptc.json`
alone does not: `frozen-model` is selected by the manifest and installed by
`ptc-host.json`. `replay.jsonl` is the fixture, not a runnable document.

The result is:

```json
{"content":"Frozen answer"}
```

Change the request in `workflow.clj` so the fixture no longer matches. The
call returns a provider-error envelope (`:status :error`, `kind`
`provider_error`, `reason` `not_found`, with the new `request_hash` in
`details`). The example passes that envelope through `cap/unwrap!`, so the
evaluation fails instead of printing the error map as a successful result.
Copy the reported hash into `replay.jsonl` to match the changed request.
