# Configure an application

Use `ptc.json` to declare code, input, selected providers, missions, and limits.

The document can select only names installed by `ptc-host.json`. It cannot add
credentials, endpoints, commands, or permissions.

## How do I start an application?

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

## How do I run the same application on new data?

Keep stable default input in `ptc.json`. For one run, put another JSON object in
a file such as `input.json`:

```json
{"name":"Ada"}
```

Pass it with `--input`. The path resolves relative to `ptc.json` first, so this
works even when the command runs from another directory:

```console
ptc run my-application/ptc-project.json --input input.json
```

Use `--private-input` instead when the input must not appear in ordinary output
or traces. Private input also requires private output handling; see the
[command-line reference](../reference/cli.md#run-a-manifest).

## How do I select a provider?

Add a provider only after `ptc-host.json` has installed its alias. Every provider
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

A mission can only narrow `providers.mission`; an absent alias is rejected. If
it selects no providers, requirements outside implicit capabilities are also
rejected. See [mission isolation](../reference/application-manifest.md#supply-input-and-named-missions)
for the complete rule and remediation.

## How do I stop a long or expensive run?

Set runtime ceilings under `limits` and cap model calls on the selected alias:

```json
{
  "providers": {
    "workflow": [{"name": "model", "config": {"max_calls": 6}}]
  },
  "limits": {
    "run_duration_ms": 60000,
    "workflow_capability_calls": 12
  }
}
```

`run_duration_ms` bounds the whole run. `max_calls` bounds calls to that model
alias, while `workflow_capability_calls` covers all workflow capability calls.
The installed ceilings in `ptc-host.json` remain the maximum values `ptc.json`
may request. See the [limits reference](../kernel-limits-reference.md) for every
ceiling and its default.

## How do I check the configuration?

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
