# Kernel tutorial examples

Run these examples from the repository root.
[`docs/guides/quickstart.md`](../../docs/guides/quickstart.md) is the shortest
path from a clone to a live model run;
[`docs/guides/getting-started.md`](../../docs/guides/getting-started.md) walks
through the same examples in detail, and
[`docs/guides/building-agents.md`](../../docs/guides/building-agents.md)
explains the agent examples.

Each example has a project document in this directory. Point `mix ptc run` at
it to reuse the application, host, environment, artifact, and Viewer paths.
Examples 01 and 05 are credential-free and select no providers:

```bash
mix ptc run examples/kernel-tutorial/01-orders.ptc-project.json
mix ptc run examples/kernel-tutorial/05-signature-feedback.ptc-project.json
```

Examples 02 through 04 select providers. Their project documents all reference
the shared host installation and the tutorial's explicitly named `.env`:

```bash
mix ptc run examples/kernel-tutorial/02-deepseek-extract.ptc-project.json
mix ptc run examples/kernel-tutorial/03-file-agent.ptc-project.json
mix ptc run examples/kernel-tutorial/04-multi-turn-agent.ptc-project.json
```

They require `OPENROUTER_API_KEY` and use the trusted `deepseek` model alias.
Follow the [model-authored Quickstart](../../docs/guides/quickstart.md#run-a-model-authored-program)
once before running them. Example 03 also requires Node.js 22 or newer; its
server bundle is committed, so no `npm install` or build is needed.

Direct manifest invocation with explicit `--env-file` and `--host-config`
switches remains available as the low-level automation form.

[`ptc-host.json`](ptc-host.json) is the shared operator document these examples
install from;
[`docs/guides/host-configuration.md`](../../docs/guides/host-configuration.md)
explains its fields.

The [Quickstart](../../docs/guides/quickstart.md) owns the shortest live path;
the [MCP guide](../../docs/guides/connecting-tools-with-mcp.md) explains the
filesystem tool connection used by Example 03.
