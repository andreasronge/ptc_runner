# Explore a project interactively

> **Audience:** application authors and operators inspecting a workflow,
> mission, or immutable run capture.

Open the workflow environment declared by a project:

```console
ptc repl --project ptc-project.json
```

Evaluate one expression without opening a terminal:

```console
ptc repl --project ptc-project.json -e '(dir)'
```

Inspect one mission with its own components, data, and direct provider closure:

```console
ptc repl --project ptc-project.json --mission default
```

Mission sessions do not inherit workflow model access or other missions. They
are useful for checking exactly what a generated program can see.

Analyze public traces through the fixed, read-only profile:

```console
ptc repl --project ptc-project.json \
  --profile run-analysis-v1 \
  -e '(analysis/runs {})'
```

Private inspection is a separate explicit mode because it can reveal prompts,
responses, generated source, and tool payloads. Do not grant it merely to query
ordinary activity.

Use the [REPL reference](../reference/repl.md) for every session mode, selector,
profile, preview limit, script form, JSON Lines contract, private-authority
requirement, and cleanup rule.
