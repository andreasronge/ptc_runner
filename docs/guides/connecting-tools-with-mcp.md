# Connect an MCP tool

> **Audience:** operators and application authors granting a model the smallest
> useful external tool surface.

MCP is the external-tool boundary. The operator chooses the server, transport,
credentials, public name, read/write effect, and ceilings. The application can
select and narrow that installation but cannot widen it.

Use the checked-in file-agent example to see the complete split:

```console
ptc init kernel-tutorial --example kernel-tutorial
ptc doctor kernel-tutorial/03-file-agent.ptc-project.json
ptc doctor kernel-tutorial/03-file-agent.ptc-project.json --connect
ptc run kernel-tutorial/03-file-agent.ptc-project.json
```

That example maps one server operation to `workspace.read` and exposes only a
bounded wrapper to the mission. Its server has its own runtime prerequisite;
the first provider-free PtcRunner project does not. The server it launches is
the repository's `examples/mcp/filesystem` bundle, which is too large to embed:
copy that directory to `mcp/filesystem` beside the materialized tutorial, or run
this step from a checkout.

PtcRunner requires the MCP `2026-07-28` profile and `server/discover`. An
incompatible endpoint fails closed instead of falling back to a legacy
handshake; check the [protocol compatibility reference](../reference/mcp.md#protocol-compatibility)
before choosing a server.

When adding a real tool:

1. install the MCP source in the operator-owned host document;
2. map only the upstream operations the mission needs;
3. give every public mapping an explicit `read` or `write` effect;
4. select the alias in the intended mission;
5. explicitly allow selected write-bearing tools; and
6. run plain `doctor` before the active `--connect` probe.

Treat an indeterminate write as an unknown outcome, not as a safe automatic
retry. A server that returned a complete refusal has already answered; that
failure is not indeterminate. Keep credentials out of application manifests
and model-visible descriptions.

Use the [MCP reference](../reference/mcp.md) for stdio and HTTP transports,
tool mapping, effects, authentication, OAuth, lifecycle, cursors, content
identity, ceilings, and diagnostics.
