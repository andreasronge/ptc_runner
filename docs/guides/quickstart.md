# Quickstart

This is the shortest path from a clone to a program written by a model and run
by the Kernel. This page gives only the commands; follow the links for detail.

You need Elixir and Erlang/OTP, and an
[OpenRouter](https://openrouter.ai/keys) API key for the model step. `mise
install` installs the pinned toolchain versions; `docs/development-setup.md`
covers a machine that has neither.

## 1. Run hello world with no credentials

```console
git clone https://github.com/andreasronge/ptc_runner
cd ptc_runner
mix deps.get
```

<!-- ptc-guide-e2e: id=quickstart-hello scratch=hello-ptc -->
```console
mix ptc init hello-ptc
mix ptc run hello-ptc/ptc-project.json
```

```json
{}
```

`init` creates a minimal PTC-Lisp function, its application manifest, and a
project document that remembers local artifact and Viewer settings. The run
needs no model, host document, credential, or network access and records its
trace and command envelope under `hello-ptc/.ptc`.

## 2. Supply a model credential

```console
cp .env.example examples/kernel-tutorial/.env
chmod 600 examples/kernel-tutorial/.env
```

Set `OPENROUTER_API_KEY` in that file to your key. The tutorial project names
that exact file; PtcRunner never searches for it implicitly. `.env` is
Git-ignored, and credentials never belong in a manifest, PTC-Lisp, or a trace.
[Host configuration](host-configuration.md#declare-credentials-once) documents the three
declaration forms and how to move off `.env` for a real deployment.

## 3. Let the model write the program

<!-- ptc-guide-e2e: id=quickstart-live-agent project=examples/kernel-tutorial/04-multi-turn-agent.ptc-project.json requires=OPENROUTER_API_KEY assert=two-turn-agent -->
```console
mix ptc run examples/kernel-tutorial/04-multi-turn-agent.ptc-project.json
```

```json
{"ok":true,"value":42}
```

The model was given a task, wrote PTC-Lisp, and the runtime evaluated that
program over two turns. The later [Building agents](building-agents.md) guide
explains the workflow/mission boundary, prompt policy, and replaceable preludes;
none of that is required to complete this first run.

The project document remembers the application manifest, shared host
installation, environment file, artifact root, and Viewer settings. Each run
uses its unique run reference for the trace and public command envelope, so it
does not replace an earlier run. [Running and debugging](running-and-debugging.md)
explains its result, usage, trace, and failure artifacts.

[`ptc-host.json`](https://github.com/andreasronge/ptc_runner/blob/main/examples/kernel-tutorial/ptc-host.json) is the operator
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
mix ptc doctor examples/kernel-tutorial/04-multi-turn-agent.ptc-project.json --connect
```

With no key it exits nonzero, marks the credential check failed, and reports
`readiness: "failed"`. With the key in place it performs real provider work
and reports `readiness: "ready"`. Plain `mix ptc doctor` performs no active
provider work and reports `readiness: "unverified"`.

`doctor --connect` may make provider requests and incur cost. See
[Running and debugging](running-and-debugging.md#choose-a-command) for the command and
failure contracts.

## Next

- [Getting started](getting-started.md) — read the generated files, run a
  data-processing example, and inspect results, traces, and the REPL.
- [Building agents](building-agents.md) — the agent loop, the correction
  protocol, and giving a model a small mission API.
- [`examples/kernel-tutorial/`](https://github.com/andreasronge/ptc_runner/tree/main/examples/kernel-tutorial) — five focused examples.
  `02-deepseek-extract` calls a model without generating code,
  `03-file-agent` gives the model one MCP tool and needs Node but no npm install
  because the server bundle is committed, and `05-signature-feedback` is
  credential-free.
