# Named reader/writer missions

This runnable agentic flow uses one workflow to coordinate two `agent.core`
loops. The `reader` mission can read only `reader-state/`; the `writer` mission
can write only `writer-state/`. They compile different PTC-Lisp APIs, receive
different mission data, hold separate continuations, and are granted different
provider occurrences.

## Setup and execution

Both missions install the published
[`ptc-fs-mcp@0.1.0`](https://www.npmjs.com/package/ptc-fs-mcp) package: one
installation maps only `read_text_file`, the other only `write_text_file`, each
with its own confined root. The first run may download that package. Node.js is
required. Export an OpenRouter key:

```console
export OPENROUTER_API_KEY=...
```

Run from the repository root (host transport paths are resolved relative to
the host configuration):

```console
mix ptc run examples/named-mission-reader-writer/ptc.json \
  --host-config examples/named-mission-reader-writer/ptc-host.json
```

The reader returns the exact contents of `reader-state/brief.txt`. The workflow
passes that value to the writer agent, which creates
`writer-state/summary.txt`, and the final result reports the read text and the
writer's completion value.

## Security boundary

The workflow owns orchestration and the model provider, but it does not donate
one mission's authority to the other. `reader_workspace` exposes only
`workspace.read` and is granted only to `reader`; `writer_workspace` exposes
only `workspace.write` and is granted only to `writer`. A generated reader
program cannot resolve the write tool, and a writer program cannot resolve the
read tool. The two installations also have different confined roots, so
provider state remains separate even if public tool names or model behavior
change. `write_text_file` accepts only one lowercase basename, caps content,
and refuses to replace non-regular files; the package is a focused runnable
example, not a production filesystem service.
