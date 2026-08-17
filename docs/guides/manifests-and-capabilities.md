# Configure an application

> **Audience:** application authors assembling a PtcRunner workflow and its
> bounded mission environments.

A PtcRunner application declares code, input, selected providers, missions,
and narrower limits in `ptc.json`. The document can select only names that the
operator installed. It cannot add credentials, endpoints, commands, or wider
authority.

Start with a generated project:

```console
ptc init my-application
ptc run my-application/ptc-project.json
```

The generated application is deliberately small:

```json
{
  "version": 1,
  "workflow": {
    "components": [{"id": "app.main", "path": "main.clj"}],
    "entry": "app.main/run"
  },
  "input": {"value": {}}
}
```

Add a provider only after the operator has installed its alias. Model access
belongs to the trusted workflow; task tools belong to the mission that runs
model-authored programs:

```json
{
  "providers": {"workflow": [{"name": "model"}]},
  "missions": {
    "default": {
      "components": [],
      "providers": ["workspace"]
    }
  }
}
```

Validate structure and selected authority before running:

```console
ptc validate my-application/ptc-project.json
ptc doctor my-application/ptc-project.json
```

Use the [application-manifest reference](../reference/application-manifest.md)
for every field, validation rule, mission shape, provider-selection rule,
event policy, and limit. Continue with [host configuration](host-configuration.md)
to install the aliases the application selects.
