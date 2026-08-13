# Kernel tutorial examples

Run these examples from the repository root.
[`docs/guides/quickstart.md`](../../docs/guides/quickstart.md) is the shortest
path from a clone to a live model run;
[`docs/guides/getting-started.md`](../../docs/guides/getting-started.md) walks
through the same examples in detail, and
[`docs/guides/building-agents.md`](../../docs/guides/building-agents.md)
explains the agent examples.

Examples 01 and 05 are credential-free and select no providers:

```bash
mix ptc run examples/kernel-tutorial/01-orders/ptc.json
mix ptc run examples/kernel-tutorial/05-signature-feedback/ptc.json
```

Examples 02 through 04 select providers, so each needs the shared host
installation that gives those aliases meaning:

```bash
mix ptc run examples/kernel-tutorial/02-deepseek-extract/ptc.json \
  --env-file .env \
  --host-config examples/kernel-tutorial/ptc-host.json
mix ptc run examples/kernel-tutorial/03-file-agent/ptc.json \
  --env-file .env \
  --host-config examples/kernel-tutorial/ptc-host.json
mix ptc run examples/kernel-tutorial/04-multi-turn-agent/ptc.json \
  --env-file .env \
  --host-config examples/kernel-tutorial/ptc-host.json
```

They require `OPENROUTER_API_KEY` in the host environment and use the trusted
`deepseek` model alias. From the repository root, copy `.env.example` to the
Git-ignored `.env` and replace its placeholder before running a live model
example. Each live command selects it explicitly with `--env-file .env`.
Credentials never go in the manifests or PTC-Lisp files.

[`ptc-host.json`](ptc-host.json) is the shared operator document these examples
install from;
[`docs/guides/host-configuration.md`](../../docs/guides/host-configuration.md)
explains its fields.

Run the live tutorial contracts manually with:

```bash
mix test test/ptc_runner/kernel/tutorial_examples_e2e_test.exs --include e2e
```

They are tagged `:e2e` and excluded from normal `mix test` and `mix precommit`
runs.
