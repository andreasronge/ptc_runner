# Quickstart

Four commands, from a clone to a program the model wrote and the runtime ran.
This page only performs the steps; every "why" is a link.

You need Elixir and Erlang/OTP, and an
[OpenRouter](https://openrouter.ai/keys) API key for the model step. `mise
install` installs the pinned toolchain versions; `docs/development-setup.md`
covers a machine that has neither.

## 1. Run a workflow with no credentials

```console
git clone https://github.com/andreasronge/ptc_runner
cd ptc_runner
mix deps.get
mix ptc run examples/kernel-tutorial/01-orders/ptc.json
```

```json
{"order_count":3,"paid_count":2,"paid_total":335.75,"pending_ids":["A-101"]}
```

That is a PTC-Lisp function reading JSON input. No model, no host document, no
network. The first run compiles the dependencies and the project, which took
about 90 seconds from a fresh clone; later runs start in a few seconds.

## 2. Supply a model credential

```console
cp .env.example .env
chmod 600 .env
```

Set `OPENROUTER_API_KEY` in `.env` to your key. `.env` is Git-ignored, and
credentials never belong in a manifest, a PTC-Lisp file, or a trace.
[Host configuration](host-configuration.md#credentials) documents the three
declaration forms and how to move off `.env` for a real deployment.

## 3. Let the model write the program

```console
mix ptc run examples/kernel-tutorial/04-multi-turn-agent/ptc.json \
  --host-config examples/kernel-tutorial/ptc-host.json
```

```json
{"ok":true,"value":42}
```

The model was given a task, wrote PTC-Lisp, and the runtime evaluated that
program in the confined mission environment over two turns. Two live model
calls cost a fraction of a cent.

[`ptc-host.json`](../../examples/kernel-tutorial/ptc-host.json) is the operator
document: it maps the `deepseek` alias to a model and binds it to the
credential. The manifest selects that alias and may narrow it, but cannot name
a model, endpoint, or key. That asymmetry is the whole security argument, laid
out in the [README](../../README.md#why-it-is-safe).

## If step 3 fails

A missing or unreadable key aborts before the run:

```text
** (Mix) error: active_preflight/credential_unavailable: provider/deepseek/credentials: a required provider credential is unavailable (run_ref: cmd-00000000000000000000000000)
```

The `provider/deepseek/credentials` subject identifies the provider alias and
the operation that failed. In this example it means `OPENROUTER_API_KEY` was
not visible to the command. Use the active doctor operation to inspect the
complete readiness report:

```console
mix ptc doctor examples/kernel-tutorial/04-multi-turn-agent/ptc.json \
  --host-config examples/kernel-tutorial/ptc-host.json --connect
```

With no key it exits nonzero and reports
`provider/deepseek/credentials` as `fail/credential_unavailable`. Checks for
which the failed operation retained no evidence are
`skipped/not_verified_due_to_failure`; they are not claims that those checks
did or did not run. The report's `readiness` is `failed`.

Once the key is in place, the same command exits successfully, every check
reports `pass`, including `provider/deepseek/credentials`, and `readiness` is
`ready`. Plain `ptc doctor` performs no active provider work and therefore
reports `readiness: "unverified"`.

## Next

- [Getting started](getting-started.md) — the same ground at walking pace: the
  manifest, the entry function, results, traces, and the REPL.
- [Building agents](building-agents.md) — the agent loop, the correction
  protocol, and giving a model a small mission API.
- [`examples/kernel-tutorial/`](../../examples/kernel-tutorial/README.md) — the
  other four examples. `02-deepseek-extract` calls a model without generating
  code, `03-file-agent` gives the model one MCP tool and needs Node, and
  `05-signature-feedback` is credential-free.
