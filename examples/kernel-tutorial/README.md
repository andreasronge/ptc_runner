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

They require `OPENROUTER_API_KEY` in the host environment and use the trusted
`deepseek` model alias. From the repository root, copy `.env.example` to the
Git-ignored `examples/kernel-tutorial/.env` and replace its placeholder before
running a live model example. Credentials never go in project documents,
manifests, or PTC-Lisp files.

```bash
cp .env.example examples/kernel-tutorial/.env
chmod 600 examples/kernel-tutorial/.env
```

Direct manifest invocation with explicit `--env-file` and `--host-config`
switches remains available as the low-level automation form.

[`ptc-host.json`](ptc-host.json) is the shared operator document these examples
install from;
[`docs/guides/host-configuration.md`](../../docs/guides/host-configuration.md)
explains its fields.

Run the live tutorial contracts manually with:

```bash
mix test test/quickstart_guide_test.exs \
  test/ptc_runner/kernel/tutorial_examples_e2e_test.exs \
  --include scheduled_e2e
```

The live contracts are tagged `:scheduled_e2e` and excluded from normal
`mix test` and `mix precommit` runs. The credential-free quickstart command
still runs in the normal suite.
