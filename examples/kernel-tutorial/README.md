# Kernel tutorial examples

Run these examples from the repository root. The accompanying walkthrough is
[`docs/guides/kernel-tutorial.md`](../../docs/guides/kernel-tutorial.md).

```bash
mix ptc.run examples/kernel-tutorial/01-orders/ptc.json
mix ptc.run examples/kernel-tutorial/02-deepseek-extract/ptc.json
mix ptc.run examples/kernel-tutorial/03-file-agent/ptc.json
mix ptc.run examples/kernel-tutorial/04-multi-turn-agent/ptc.json
```

The final three examples require `OPENROUTER_API_KEY` in `.env` and use the
trusted `deepseek` model alias.

Run the live tutorial contracts manually with:

```bash
mix test test/ptc_runner/kernel/tutorial_examples_e2e_test.exs --include e2e
```

They are tagged `:e2e` and excluded from normal `mix test` and `mix precommit`
runs.
