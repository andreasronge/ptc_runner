# Use a model

> **Audience:** application authors and operators selecting, verifying, and
> observing a model without working on PtcRunner's provider implementation.

The operator installs a model under a stable alias in the host document. The
application selects that alias for its trusted workflow. Generated mission code
does not receive the model route.

Bind credentials outside the application, preferably through a named environment
variable or another operator-owned credential source. Then inspect the public
installation without revealing its credential or private endpoint:

```console
ptc models ptc-project.json
ptc doctor ptc-project.json
```

Plain `doctor` is inert. Use the active connectivity probe only when a remote
request is intended:

```console
ptc doctor ptc-project.json --connect
```

An agent loop requires a model endpoint that supports tool-bearing requests.
A provider may accept an ordinary completion while rejecting the agent's tool
contract; PtcRunner reports that separately from a missing model or credential
failure.

After a run, canonical evidence records attributable call counts, usage, timing,
and a safe failure class. Prompts and responses are private and appear only when
the operator explicitly enables private inspection.

Start with [Install models and tools](host-configuration.md) for one complete
operator workflow. The [model and host reference](../reference/host-installation.md)
owns selector forms, credentials, cache policy, request parameters, ceilings,
diagnostics, and connectivity behavior. See [Customize an
agent](building-agents.md) for the model-neutral loop.
