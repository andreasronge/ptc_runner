# Kernel tutorial examples

Materialize a copy of this directory, then run the commands below from the
directory that copy sits in:

```console
ptc init kernel-tutorial --example kernel-tutorial
```

`ptc docs quickstart` is the shortest path from a clone to a live model run.
`ptc docs getting-started` walks the first step in detail, and
`ptc docs building-agents` explains the agent steps.

Each step has a project document beside a directory of the same name. Point
`ptc run` at the project document; it carries the application, host,
environment, artifact, and Viewer paths.

| Step | What it shows | Needs a key |
| --- | --- | --- |
| `01-orders` | A deterministic workflow that selects no provider | no |
| `02-deepseek-extract` | One model request with a structured-output schema | yes |
| `03-file-agent` | An agent loop holding a filesystem tool over MCP | yes |
| `04-multi-turn-agent` | A two-turn agent loop under explicit Kernel clocks | yes |
| `05-signature-feedback` | Signatures, and the feedback a failed check returns | no |
| `06-cost-budget` | A deliberate cost-limit refusal, exit status 6 | yes |
| `07-parallel-fan-out` | Twelve parallel model requests, then one synthesis request | yes |

## Steps without a key

```console
ptc run kernel-tutorial/01-orders.ptc-project.json
ptc run kernel-tutorial/05-signature-feedback.ptc-project.json
```

## Steps with a key

The live steps select the trusted `deepseek` model alias and need a non-empty
`OPENROUTER_API_KEY`. Export it, or replace the comment in the generated
`.env` with an assignment. An assigned file value overrides the exported one,
including an empty assignment.

```console
ptc run kernel-tutorial/02-deepseek-extract.ptc-project.json
ptc run kernel-tutorial/03-file-agent.ptc-project.json
ptc run kernel-tutorial/04-multi-turn-agent.ptc-project.json
ptc run kernel-tutorial/07-parallel-fan-out.ptc-project.json
```

Step 02 sends a JSON Schema with the request and returns the object the model
filled in:

```json
{"owner":"Priya","project":"Project Atlas","risk":"delayed vendor security approval"}
```

The shared host installs the model with `structured_output_mode` set to
`json_schema`; `ptc docs host-installation` explains the modes.

Step 03 launches `ptc-fs-mcp@0.3.0` through `npx`, so Node.js is required and
the first run may download the package. `ptc docs connecting-tools-with-mcp`
explains that connection.

Step 04 requests 120-second `run_duration_ms` and `workflow_timeout_ms` limits
for its two-turn loop. `max_turns` bounds the agent protocol, not the time;
every turn and provider wait must also finish within both clocks.

Step 07 fans twelve requests out with `pmap`, then asks for a two-sentence
summary. It runs long enough to watch in the Viewer's Live tab;
`ptc docs running-and-debugging` shows how.

## The cost-budget refusal

Step 06 uses its own host document, `ptc-host-cost-budget.json`, so its
1 microUSD ceiling cannot affect the other steps. The manifest repeats the
ceiling.

```console
ptc run kernel-tutorial/06-cost-budget.ptc-project.json
echo $? # 6
```

With a valid key, the run fails before provider dispatch with an
`execution/runtime_limit_exceeded` envelope naming `llm_cost_microusd`. The
tariff id `openrouter-model-pricing-v1` is an operator-chosen name for the
pricing basis prepared with this installation, not an id issued by OpenRouter.
Raise both copies of `llm_cost_microusd` to turn this step into a real budget.

## What a run leaves behind

Every project document sets `artifacts.inspection` and `viewer.private` to
`true`, because reading the PTC-Lisp is the point of the tutorial. Each run
writes a private inspection artifact beside its trace, and `ptc viewer` on the
project document shows the prelude sources the run loaded and, for the agent
steps, the program the model generated for each evaluation. That evidence
contains prompts, responses, and tool payloads; a project that should not
retain it sets both settings back to `false`.

`ptc-host.json` is the shared operator document for the live steps;
`ptc docs host-configuration` explains its fields.
