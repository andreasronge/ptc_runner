# ptc_runner_mcp Development

This document is for people building, testing, packaging, or debugging
the MCP server from source. User-facing installation and MCP client
configuration live in [README.md](README.md).

## Requirements

- Elixir 1.15+
- Erlang/OTP 26+
- macOS for the currently supported local release artifact

Run commands in `mcp_server/` unless noted otherwise.

## Local Development

Fetch dependencies:

```bash
mix deps.get
```

Run the server from source in stdio mode:

```bash
mix mcp.run
```

This is equivalent to `mix run --no-halt` with stdio attached and is
useful for local iteration before building a release.

## Build A Release

```bash
MIX_ENV=prod mix release --overwrite
```

The executable lands at:

```bash
_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp
```

Smoke test:

```bash
_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp version
```

The MCP `initialize` response advertises `serverInfo.name` as
`ptc_lisp`, plus the package version and build metadata. When built
from a git checkout, `serverInfo.version` uses SemVer build metadata
such as `0.1.0+abc123def456`, and `serverInfo.build` includes
compile-time `git_commit` and `git_dirty` fields. CI or packaging
scripts can override these with `PTC_RUNNER_MCP_GIT_COMMIT` and
`PTC_RUNNER_MCP_GIT_DIRTY`.

## Test And Check

Targeted test example:

```bash
mix test test/ptc_runner_mcp/release_env_test.exs
```

Standard local checks:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test
```

The repo may also define pre-commit hooks that run a scoped subset of
these checks.

## Release Distribution And Remote IEx

The release defaults `RELEASE_DISTRIBUTION=none`. That is the right
default for stdio MCP clients because they often spawn one server
subprocess per configured client or probe. A fixed distributed Erlang
node name would make those subprocesses collide.

Remote IEx debugging is still available when you opt in explicitly.
Start the release with distribution enabled and a unique node name:

```bash
RELEASE_DISTRIBUTION=sname \
RELEASE_NODE=ptc_runner_mcp_debug_1 \
_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp start
```

Attach from another terminal with the same settings:

```bash
RELEASE_DISTRIBUTION=sname \
RELEASE_NODE=ptc_runner_mcp_debug_1 \
_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp remote
```

Use a different `RELEASE_NODE` for every concurrent debug process.

## Release Lifecycle Commands

Useful commands:

```bash
ptc_runner_mcp start       # foreground server
ptc_runner_mcp version     # print release version
ptc_runner_mcp eval "..."  # one-shot VM expression
```

These commands require a distributed node and therefore only work for
processes started with `RELEASE_DISTRIBUTION=sname` or
`RELEASE_DISTRIBUTION=name`:

```bash
ptc_runner_mcp remote
ptc_runner_mcp rpc "..."
ptc_runner_mcp pid
ptc_runner_mcp stop
ptc_runner_mcp restart
```

For ordinary stdio operation, stop the server by closing stdin or
sending SIGINT/SIGTERM from the owning process.

## Manual JSON-RPC Smoke Test

```bash
cat <<'EOF' | _build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp start
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"hello","version":"0.0.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"lisp_eval","arguments":{"program":"(+ 1 2)"}}}
EOF
```

For a fuller raw protocol walkthrough, see
[`docs/guides/mcp-getting-started.md`](../docs/guides/mcp-getting-started.md).

## Diagnostics

Useful local flags:

```bash
ptc_runner_mcp start --debug-tool
ptc_runner_mcp start --trace-dir /tmp/ptc-traces
ptc_runner_mcp start --log-level debug
```

Be careful with debug logs and full trace payloads: they may include
programs, context, and result data. The detailed diagnostics reference
lives in [`docs/mcp-debug.md`](../docs/mcp-debug.md), and all flags are
listed in
[`docs/mcp-server-configuration.md`](../docs/mcp-server-configuration.md).

## Packaging Notes

The intended release channel is a standalone `ptc_runner_mcp` archive.
The first supported target is Apple Silicon macOS, with additional
targets added as CI coverage and packaging are proven.

Expected artifacts:

- one archive per OS/architecture pair;
- snapshot prereleases from `main`;
- versioned releases from tags;
- `SHA256SUMS` generated in CI after packaging.
