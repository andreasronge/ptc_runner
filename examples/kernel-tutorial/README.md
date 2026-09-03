# Kernel tutorial examples

Materialize a copy of this directory with
`ptc init kernel-tutorial --example kernel-tutorial`, then run the commands
below from the directory that copy sits in.
`ptc docs quickstart` is the shortest path from a clone to a live model run;
`ptc docs getting-started` walks through the same examples in detail, and
`ptc docs building-agents` explains the agent examples.

Each example has a project document in this directory. Point `ptc run` at
it to reuse the application, host, environment, artifact, and Viewer paths.
Examples 01 and 05 are credential-free and select no providers:

```console
ptc init kernel-tutorial --example kernel-tutorial
ptc run kernel-tutorial/01-orders.ptc-project.json
ptc run kernel-tutorial/05-signature-feedback.ptc-project.json
```

Examples 02 through 04 select providers. Their project documents all reference
the shared host installation and the tutorial's explicitly named `.env`:

```console
ptc run kernel-tutorial/02-deepseek-extract.ptc-project.json
ptc run kernel-tutorial/03-file-agent.ptc-project.json
ptc run kernel-tutorial/04-multi-turn-agent.ptc-project.json
```

They require a non-empty `OPENROUTER_API_KEY` and use the trusted `deepseek`
model alias. Keep the generated comment-only `.env` and export the variable, or
replace its comment with a non-empty assignment. Assigned file values override
exported values, including empty assignments. Follow `ptc docs quickstart` once
before running them. Example 03
launches `ptc-fs-mcp@0.1.0` through `npx`; the first run may download that
package. Node.js and `npx` are required.

Example 06 is a deliberate cost-budget refusal. It uses a separate host
document so its 1 microUSD installed ceiling cannot affect the successful live
examples, and repeats that ceiling in the application manifest:

```console
ptc run kernel-tutorial/06-cost-budget.ptc-project.json
echo $? # 6
```

With a valid `OPENROUTER_API_KEY`, the run fails before provider dispatch with
an `execution/runtime_limit_exceeded` envelope naming
`llm_cost_microusd`. Its `reservation_tariff.id` value,
`openrouter-model-pricing-v1`, is an operator-chosen opaque identity for the
pricing basis prepared with this installation; it is not an ID issued by
OpenRouter. Raise both copies of `llm_cost_microusd` to turn this starting point
into a budget suitable for a real workflow.

Example 04 requests explicit 120-second `run_duration_ms` and
`workflow_timeout_ms` limits for its live, two-turn model loop. Its
`max_turns` setting bounds the agent protocol; it is not a time allowance.
Every turn and provider wait must also finish within both Kernel clocks.
Applications should choose an explicit bounded allowance for their expected
turn count and model latency; this tutorial value is not a completion guarantee.

Direct manifest invocation with explicit `--env-file` and `--host-config`
switches remains available as the low-level automation form.

Every project document here sets `artifacts.inspection` and `viewer.private`
to `true`, because reading the PTC-Lisp is the point of the tutorial. Each run
therefore writes a private inspection artifact next to its trace, and
`ptc viewer <project>` shows the prelude sources the run actually loaded and,
for the model-driven steps, the program the model generated for each
evaluation. That evidence contains prompts, responses, and tool payloads; a
project that should not retain it sets both settings back to `false`.

`ptc-host.json` is the shared operator document for Examples 02 through 04;
`ptc-host-cost-budget.json` isolates Example 06's deliberate ceiling.
`ptc docs host-configuration` explains its fields.

The Quickstart (`ptc docs quickstart`) owns the shortest live path; the MCP
guide (`ptc docs connecting-tools-with-mcp`) explains the filesystem tool
connection used by Example 03.
