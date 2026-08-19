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
    "components": [{"id": "main", "path": "main.clj"}],
    "entry": "main/run"
  },
  "input": {"value": {"name": "world"}}
}
```

Add a provider only after the operator has installed its alias. Every provider
the application uses is selected at the top level, under `providers.workflow`
for model access the trusted workflow holds, and under `providers.mission` for
the task tools that missions running model-authored programs may hold. Add both
scopes to the manifest above:

```json
{
  "providers": {
    "workflow": [{"name": "model"}],
    "mission": [{"name": "workspace"}]
  },
  "missions": {
    "default": {
      "components": [],
      "providers": ["workspace"]
    }
  }
}
```

A mission's own `providers` list can only narrow what `providers.mission`
already selected; naming an alias there does not introduce it, and a name
absent from `providers.mission` is rejected. Omitting a name is the point: the
grant is then absent from that mission's environment.

Install the aliases first, then validate. Both commands resolve the selected
providers against the host document, so they report the selected provider as
not installed until [host configuration](host-configuration.md) declares
`model` and `workspace`:

```console
ptc validate my-application/ptc-project.json
ptc doctor my-application/ptc-project.json
```

Use the [application-manifest reference](../reference/application-manifest.md)
for every field, validation rule, mission shape, provider-selection rule,
event policy, and limit. Continue with [host configuration](host-configuration.md)
to install the aliases the application selects.
