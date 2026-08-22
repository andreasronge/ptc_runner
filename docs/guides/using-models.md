# Use a model

Select, verify, and observe a model without working on PtcRunner's provider
implementation.

`ptc-host.json` installs a model under a stable alias, and
`ptc.json` selects that alias for its trusted workflow. Generated mission code
does not receive the model route.

## What must the model support?

An agent loop needs an endpoint that accepts tool-bearing requests. A model may
accept ordinary completions while rejecting the agent's tool contract;
PtcRunner reports that separately from a missing model or credential failure.

## How do I choose one?

Start with the model in the shipped examples: OpenRouter's
[`deepseek/deepseek-v4-flash`](https://openrouter.ai/deepseek/deepseek-v4-flash).
Model catalogs and routing change over time, so PtcRunner does not keep a static
compatibility list. Choose a model advertised for tool use, install it under an
alias, and confirm the exact route with `ptc doctor PROJECT.json --connect`.

Two aliases share the public `llm-request` call budget. `config.max_calls`
additionally caps an alias only when it is stricter than that shared budget.

## Where do credentials belong?

Bind credentials outside the application, preferably through a named environment
variable or another credential source in `ptc-host.json`. Then inspect the public
installation without revealing its credential or private endpoint:

```console
ptc models ptc-project.json
ptc doctor ptc-project.json
```

`models` names the selector each LLM alias configured; an endpoint-bearing
`openai-compat:` selector is withheld instead, because it carries the
private address from `ptc-host.json`.

## How do I check connectivity?

Plain `doctor` is inert. Use the active connectivity probe only when a remote
request is intended:

```console
ptc doctor ptc-project.json --connect
```

## What does a run record?

After a run, the trace records how many model calls were made, which alias they
used, reported token usage and cost, timing, and a safe failure class. Prompts
and responses are private and appear only when private inspection is enabled.

Start with [Install models and tools](host-configuration.md) for one complete
workflow. The [model and host reference](../reference/host-installation.md)
owns selector forms, credentials, cache policy, request parameters, ceilings,
diagnostics, and connectivity behavior. See [Customize an
agent](building-agents.md) for the model-neutral loop.
