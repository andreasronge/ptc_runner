# Named reader/writer missions

One workflow coordinates two `agent.core` loops. The `reader` mission can read
only `reader-state/`; the `writer` mission can write only `writer-state/`. They
compile different PTC-Lisp APIs, receive different mission data, hold separate
continuations, and are granted different provider occurrences.

## Run it

Materialize a copy of this directory, then run the commands below from the
directory that copy sits in:

```console
ptc init named-mission-reader-writer --example named-mission-reader-writer
```

Both missions install the published
[`ptc-fs-mcp@0.1.0`](https://www.npmjs.com/package/ptc-fs-mcp) package through
`npx`: one installation maps only `read_text_file`, the other only
`write_text_file`, each with its own confined root. Node.js is required, and
the first run may download the package. The project selects the trusted
`deepseek` model alias and needs a non-empty `OPENROUTER_API_KEY`. Export it,
or replace the comment in the generated `.env` with an assignment.

```console
export OPENROUTER_API_KEY=...
ptc run named-mission-reader-writer/ptc-project.json
ptc viewer named-mission-reader-writer/ptc-project.json
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
