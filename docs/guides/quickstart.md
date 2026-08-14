# Quickstart

This is the shortest path from a clone to a program written by a model and run
by the Kernel. This page gives only the commands; follow the links for detail.

You need Elixir and Erlang/OTP, and an
[OpenRouter](https://openrouter.ai/keys) API key for the model step. `mise
install` installs the pinned toolchain versions; `docs/development-setup.md`
covers a machine that has neither.

## 1. Run a workflow with no credentials

```console
git clone https://github.com/andreasronge/ptc_runner
cd ptc_runner
mix deps.get
```

<!-- ptc-guide-e2e: id=quickstart-orders -->
```console
mix ptc run examples/kernel-tutorial/01-orders/ptc.json
```

```json
{"order_count":3,"paid_count":2,"paid_total":335.75,"pending_ids":["A-101"]}
```

That is a PTC-Lisp function reading JSON input. It needs no model, host
document, or network access. On a fresh clone, the first `mix ptc` command
performs normal dependency validation and compilation; later commands use the
fast startup path.

## 2. Supply a model credential

```console
cp .env.example .env
chmod 600 .env
```

Set `OPENROUTER_API_KEY` in `.env` to your key. The command names that exact
file with `--env-file`; PtcRunner never searches for it implicitly. `.env` is
Git-ignored, and credentials never belong in a manifest, PTC-Lisp, or a trace.
[Host configuration](host-configuration.md#declare-credentials-once) documents the three
declaration forms and how to move off `.env` for a real deployment.

## 3. Let the model write the program

<!-- ptc-guide-e2e: id=quickstart-live-agent requires=OPENROUTER_API_KEY -->
```console
mix ptc run examples/kernel-tutorial/04-multi-turn-agent/ptc.json \
  --env-file "${PTC_ENV_FILE:-.env}" \
  --host-config examples/kernel-tutorial/ptc-host.json
```

```json
{"ok":true,"value":42}
```

The model was given a task, wrote PTC-Lisp, and the runtime evaluated that
program in the confined mission environment over two turns.

The `PTC_ENV_FILE` fallback above uses the `.env` you just created. Automation
may point it at another explicitly named environment file.

[`ptc-host.json`](../../examples/kernel-tutorial/ptc-host.json) is the operator
document: it maps the `deepseek` alias to a model and binds it to the
credential. The manifest selects that alias and may narrow it, but cannot name
a model, endpoint, or key. That asymmetry is the whole security argument, laid
out in the [README](../../README.md#why-it-is-safe).

## If step 3 fails

A missing or unreadable key aborts before execution with
`active_preflight/credential_unavailable`. The
`provider/deepseek/credentials` subject identifies the alias and operation; in
this example `OPENROUTER_API_KEY` was not visible to the command.

Inspect the complete readiness report with active doctor:

```console
mix ptc doctor examples/kernel-tutorial/04-multi-turn-agent/ptc.json \
  --env-file .env \
  --host-config examples/kernel-tutorial/ptc-host.json --connect
```

With no key it exits nonzero, marks the credential check failed, and reports
`readiness: "failed"`. With the key in place it performs real provider work
and reports `readiness: "ready"`. Plain `ptc doctor` performs no active
provider work and reports `readiness: "unverified"`.

`doctor --connect` may make provider requests and incur cost. See
[Running and debugging](running-and-debugging.md#choose-a-command) for the command and
failure contracts.

## Next

- [Getting started](getting-started.md) — the same ground at walking pace: the
  manifest, the entry function, results, traces, and the REPL.
- [Building agents](building-agents.md) — the agent loop, the correction
  protocol, and giving a model a small mission API.
- [`examples/kernel-tutorial/`](../../examples/kernel-tutorial/README.md) — the
  other four examples. `02-deepseek-extract` calls a model without generating
  code, `03-file-agent` gives the model one MCP tool and needs Node, and
  `05-signature-feedback` is credential-free.
