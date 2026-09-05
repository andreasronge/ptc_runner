# LLM replay

This example serves one provider-neutral language-model response from a local
JSON Lines fixture. It needs no credential and performs no network activity.

It exists so a run can be repeated with the model held still. Copy this tree
when you want a test, a demo, or a baseline that must not call a provider: the
manifest selects a model alias the way any application does, and only
`ptc-host.json` decides that the alias is answered from a file. Swap that one
installation back to a live model and nothing else has to change.

`request_hash` is what ties a fixture line to a request. It is computed over
the provider-neutral request the workflow built, before any provider adapter
sees it, so the fixture is not tied to the vendor that recorded it. Matching is
exact by construction: change the system prompt, the messages, the tools, or
the schema and the request produces a different hash, so the run misses rather
than replaying an answer recorded for another question.

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
{"content":"Frozen answer","model":"frozen-model"}
```

The project records private inspection and grants it to the Viewer, so
`ptc viewer llm-replay/ptc-project.json` shows the prelude sources the run
loaded and the private model exchange. This example has no agent loop, so
there is no generated program.

Change the request in `workflow.clj` so the fixture no longer matches. The
call returns a provider-error envelope (`:status :error`, `:kind` set to
`:provider_error`, and `:reason` set to `:not_found`, with the new request hash
in the `:details` message). The example passes that envelope through `cap/unwrap!`, so the
evaluation fails instead of printing the error map as a successful result.
Copy the reported hash into `replay.jsonl` to match the changed request.
