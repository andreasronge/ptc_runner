# Use a model

Select, verify, and observe a model without working on PtcRunner's provider
implementation.

`ptc-host.json` installs a model under a stable alias, and
`ptc.json` selects it for trusted workflow code. Generated mission code never
receives the route.

## What must the model support?

An agent loop needs an endpoint that accepts tools. PtcRunner distinguishes an
unsupported tool contract from a missing model or credential.

## How do I choose one?

Start with the shipped example model: OpenRouter's
[`deepseek/deepseek-v4-flash`](https://openrouter.ai/deepseek/deepseek-v4-flash).
Catalogs and routing change, so choose a model advertised for tool use and
confirm its exact route with `ptc doctor PROJECT.json --connect`.

Two aliases share the public `llm-request` call budget. `config.max_calls`
additionally caps an alias only when it is stricter than that shared budget.

## Where do credentials belong?

Bind credentials outside the application, preferably through a named source in
`ptc-host.json`. Inspect the public installation without revealing its
credential or private endpoint:

```console
ptc models ptc-project.json
ptc doctor ptc-project.json
```

`models` names each LLM selector but withholds an endpoint-bearing
`openai-compat:` selector because it carries a private address.

## What can I check before a run?

Plain `doctor` is inert. Use the active connectivity probe only when a remote
request is intended:

```console
ptc doctor ptc-project.json --connect
```

ptc models, ptc validate, and ptc doctor do not provide a pre-run price quote.
Use the optional reservation budget described in [Size an LLM cost
budget](../kernel-limits-reference.md#size-an-llm-cost-budget); a refusal names
the next call's exact requirement.

## What does a run record?

After a run, the trace records how many model calls were made, which alias they
used, reported token usage and cost, timing, and a safe failure class. Prompts
and responses are private and appear only when private inspection is enabled.

Start with [Install models and tools](host-configuration.md) for one complete
workflow. The [model and host reference](../reference/host-installation.md)
owns selector forms, credentials, cache policy, request parameters, ceilings,
diagnostics, and connectivity behavior. See [Customize an
agent](building-agents.md) for the model-neutral loop.
