# Kernel tutorial examples

Run these examples from the repository root. Start with the credential-free
walkthrough in
[`docs/guides/getting-started.md`](../../docs/guides/getting-started.md), then
use [`docs/guides/building-agents.md`](../../docs/guides/building-agents.md)
for the live model examples.

```bash
mix ptc.run examples/kernel-tutorial/01-orders/ptc.json
mix ptc.run examples/kernel-tutorial/02-deepseek-extract/ptc.json
mix ptc.run examples/kernel-tutorial/03-file-agent/ptc.json
mix ptc.run examples/kernel-tutorial/04-multi-turn-agent/ptc.json
mix ptc.run examples/kernel-tutorial/05-signature-feedback/ptc.json
```

Examples 02 through 04 require `OPENROUTER_API_KEY` in the host environment and
use the trusted `deepseek` model alias. Examples 01 and 05 are credential-free.
From the repository root, copy `.env.example` to the Git-ignored `.env` and
replace its placeholder before running a live model example. Credentials never
go in the manifests or PTC-Lisp files.

Run the live tutorial contracts manually with:

```bash
mix test test/ptc_runner/kernel/tutorial_examples_e2e_test.exs --include e2e
```

They are tagged `:e2e` and excluded from normal `mix test` and `mix precommit`
runs.
