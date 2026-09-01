# Explore a project interactively

Inspect a workflow, mission, or immutable run capture from an interactive or
unattended REPL session.

## How do I open a workflow?

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

Mission sessions do not inherit workflow model access. Inspect-only mode
compiles without an API key; see
[Inspect source and generated programs](inspecting-source-and-programs.md).

## How do I query past runs?

Analyze public traces through the fixed, read-only profile:

```console
ptc repl --project ptc-project.json \
  --profile run-analysis-v1 \
  -e '(analysis/runs {})'
```

Every form evaluates under `evaluation_timeout_ms`, whose effective default is
30,000 ms. A form stopped by that ceiling names it and its configured value.
Raise it in the manifest if a form needs longer:

```json
{ "limits": { "evaluation_timeout_ms": 60000 } }
```

## How do I inspect private records?

Private inspection is a separate explicit mode because it can reveal prompts,
responses, generated source, and tool payloads. Do not grant it merely to query
ordinary activity.

Use the [REPL reference](../reference/repl.md) for every session mode, selector,
profile, preview limit, script form, JSON Lines contract, private-inspection
requirement, and cleanup rule.
