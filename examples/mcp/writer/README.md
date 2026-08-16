# Write-only MCP sample server

**Non-production sample.** This small Elixir script exists to make a confined
write effect runnable and inspectable. It accepts one root argument, creates
that directory if needed, and exposes one `write_text_file` tool.

The tool accepts only a one-segment lowercase basename and at most 65,536 UTF-8
bytes. It never resolves a caller-supplied directory, reads a file, starts a
subprocess, or uses the network. It refuses a destination observed as anything
other than a regular file, including a symlink. A successful call replaces a
regular file in place, so the sample is intentionally narrower than a
production race-hardened atomic artifact publisher.

Run it over stdio:

```console
elixir --erl "+S 1:1" server.exs ./output
```

Install it from a host document whose directory contains this sample:

```json
{
  "source": "mcp",
  "installation_revision": "writer-sample-v1",
  "transport": {
    "type": "stdio",
    "command": "elixir",
    "cwd": ".",
    "args": ["--erl", "+S 1:1", "server.exs", "output"]
  },
  "tools": {
    "write_text_file": {"as": "workspace.write", "effect": "write"}
  }
}
```

Every manifest selecting an installation that maps a write tool must supply a
non-empty `allow` list, for example:

```json
{"name": "writer", "config": {"allow": ["workspace.write"]}}
```

PtcRunner does not automatically retry a failed or timed-out write. A timeout
can be indeterminate: the external file may already have changed even though
the call did not return success. The sample therefore demonstrates the effect
contract as much as the filesystem operation.

See [Connecting tools with MCP](../../../docs/guides/connecting-tools-with-mcp.md)
and the runnable
[`named-mission-reader-writer`](../../named-mission-reader-writer/README.md)
example.
