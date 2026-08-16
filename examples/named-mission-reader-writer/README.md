# Named reader/writer missions

This runnable agentic flow uses one workflow to coordinate two `agent.core`
loops. The `reader` mission can read only `reader-state/`; the `writer` mission
can write only `writer-state/`. They compile different PTC-Lisp APIs, receive
different mission data, hold separate continuations, and are granted different
provider occurrences.

## Setup and execution

The repository includes the built read-only filesystem MCP sample and the
repository includes a reusable [write-only MCP sample](../mcp/writer/README.md)
implemented with the same Elixir/OTP toolchain as PtcRunner. Export an
OpenRouter key:

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
read tool. The two filesystem servers also have different confined roots, so
provider state remains separate even if public tool names or model behavior
change. The writer server accepts only one-segment lowercase relative names,
caps content at 65,536 bytes, and refuses to replace non-regular files; it is a
focused runnable example, not a production filesystem service.
