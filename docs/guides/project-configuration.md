# Project configuration

Use one explicitly named `ptc-project.json` to remember stable local paths and
development preferences:

```console
mix ptc run ptc-project.json
mix ptc doctor ptc-project.json
mix ptc doctor ptc-project.json --connect
mix ptc repl --project ptc-project.json
mix ptc viewer ptc-project.json
```

`mix ptc init DIRECTORY` generates this file alongside `ptc.json` and
`main.clj`. PtcRunner never searches parent directories or guesses a project
from its filename; the `"kind": "ptc-project"` discriminator identifies the
document.

The kernel tutorial ships one project document per runnable example. A
credential-free run and its Viewer need only the same JSON path:

```console
mix ptc run examples/kernel-tutorial/01-orders.ptc-project.json
mix ptc viewer examples/kernel-tutorial/01-orders.ptc-project.json
```

The provider-backed examples additionally reference the shared host document
and `examples/kernel-tutorial/.env` from their project files. After creating
that explicitly named environment file, their run commands have the same
single-argument shape:

```console
mix ptc run examples/kernel-tutorial/04-multi-turn-agent.ptc-project.json
```

## Keep the three roles separate

| File | Owner | Purpose |
| --- | --- | --- |
| `ptc.json` | application author or model | workflow, components, input, provider selections, narrower limits |
| `ptc-host.json` | operator | installed providers, credential references, commands, endpoints, outer limits |
| `ptc-project.json` | operator or project checkout | paths to those files, local artifact policy, Viewer preferences |

Credential values and provider declarations do not belong in the project
file. Project choices do not become part of application content identity.

## Document shape

```json
{
  "$schema": "https://ptc-runner.dev/schemas/ptc-project-config.schema.json",
  "kind": "ptc-project",
  "version": 1,
  "application": {"path": "ptc.json"},
  "host": {
    "path": "ptc-host.json",
    "env_file": {"path": ".env"}
  },
  "artifacts": {
    "root": ".ptc",
    "trace": true,
    "inspection": false,
    "result": false,
    "envelope": true
  },
  "viewer": {
    "port": 4123,
    "open": true,
    "repl": true,
    "private": false
  }
}
```

`kind`, `version`, and `application` are required. `host`, `artifacts`, and
`viewer` are optional. Every object rejects unknown and duplicate keys. Paths
are portable relative paths resolved beneath the project document's directory;
absolute paths and `..` traversal are rejected. The generated schema is
[`priv/schemas/ptc-project-config.schema.json`](https://github.com/andreasronge/ptc_runner/blob/main/priv/schemas/ptc-project-config.schema.json).

Inspection requires traces because private records must correlate with a
canonical run. `viewer.private` is a separate explicit local grant: creating a
private artifact does not automatically expose it to Viewer.

## Artifact layout

For `run`, enabled project artifacts derive from the command run reference:

```text
.ptc/traces/<run-ref>.jsonl
.ptc/traces/<run-ref>.private.jsonl
.ptc/inspection/<run-ref>.inspection.jsonl
.ptc/results/<run-ref>.json
.ptc/results/<run-ref>.private.json
.ptc/envelopes/<run-ref>.json
```

The root and its fixed child directories are owner-only. The first project run
creates the complete layout atomically; an existing incomplete, permissive, or
symlinked layout is refused. Artifact files retain the normal no-replace and
privacy rules.

## Overrides and lazy environment loading

An explicit command value wins over the corresponding project default:

```console
mix ptc run ptc-project.json --host-config deployment/staging-host.json
mix ptc run ptc-project.json --trace-dir tmp/one-off-traces
mix ptc repl --project ptc-project.json --env-file deployment/staging.env
```

Input and component-override switches remain invocation-only. A project
environment file is loaded only when inert preparation proves that a selected
provider uses an environment-backed credential. Provider-free runs, passive
doctor, Viewer, and file- or literal-backed credentials do not read it.

Direct manifest invocation remains the low-level form for automation:

```console
mix ptc run ptc.json \
  --host-config ptc-host.json \
  --trace-dir build/traces \
  --envelope build/command.json
```

## Viewer

`ptc viewer ptc-project.json` uses the project's trace root, port,
browser-opening preference, REPL setting, and private-data authorization. Trace
and correlated inspection directories are captured before the listener starts;
HTTP requests select only a run ID and never a filesystem path. Browser opening
is a bounded convenience, and additionally requires an attached terminal:
missing or failing platform openers do not stop Viewer.

The listener binds `127.0.0.1`. The project document deliberately cannot change
that: exposure is an invocation-time decision made with `--listen 0.0.0.0`,
where it stays visible in the command line rather than stored in a file. See
[Running and debugging](running-and-debugging.md#expose-it-deliberately-or-not-at-all).

The Viewer ships in the standalone release and the container image, and is
absent from the published Hex package. Embedding hosts can use the standalone
API described in [Embedding PtcRunner in Elixir](embedding-in-elixir.md).
