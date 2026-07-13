# Kernel tutorial examples

Run these examples from the repository root. The accompanying walkthrough is
[`docs/guides/kernel-tutorial.md`](../../docs/guides/kernel-tutorial.md).

```bash
mix ptc.run examples/kernel-tutorial/01-orders/ptc.json
mix ptc.run examples/kernel-tutorial/02-deepseek-extract/ptc.json
mix ptc.run examples/kernel-tutorial/03-file-agent/ptc.json
```

The final two examples require `OPENROUTER_API_KEY` in `.env` and use the
trusted `deepseek` model alias.
