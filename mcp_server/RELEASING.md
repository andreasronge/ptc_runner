# Releasing `ptc_runner_mcp`

`ptc_runner_mcp` is released as a standalone MCP server binary, not as a
Hex package. The primary distribution channel should be GitHub Releases.

## Release Channels

- Snapshot releases: prerelease artifacts built from the latest `main`
  or a selected commit. Use these for testing current work before a
  stable release.
- Stable releases: immutable artifacts built from `mcp-v*` tags, for
  example `mcp-v0.1.0`.

Use `mcp-v*` tags so MCP server releases do not collide with root
library tags.

## Initial Platform

Start with Apple Silicon macOS:

```bash
ptc_runner_mcp-darwin-arm64.tar.gz
```

Add `darwin-x64`, `linux-x64`, and Windows only after the artifact build
and smoke-test process is proven for macOS arm64.

## Local Build Shape

From `mcp_server/`:

```bash
mix deps.get
MIX_ENV=prod mix release --overwrite
_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp version
```

The distributable archive should contain the Mix release directory, not
just the shell script in `bin/`.

## Verification

Every published archive must have a SHA-256 checksum. CI should generate
a single `SHA256SUMS` file after packaging all artifacts:

```bash
shasum -a 256 ptc_runner_mcp-*.tar.gz > SHA256SUMS
```

Before extracting a downloaded release, verify it:

```bash
shasum -a 256 -c SHA256SUMS
```

An install script must verify the checksum before extraction or execution.
This is the same supply-chain boundary as any other downloaded binary.

## Smoke Tests

After extracting an archive, CI should run:

```bash
bin/ptc_runner_mcp version
```

It should also run stdio JSON-RPC smoke tests for both supported tool
surfaces.

Default stateless mode:

1. `initialize`
2. `notifications/initialized`
3. `tools/list`
4. Assert `lisp_eval` is advertised.
5. Call `lisp_eval` with `(+ 1 2)` and assert the slim text result is
   `user=> 3`.
6. `notifications/exit`

Session mode:

1. Start with `bin/ptc_runner_mcp start --sessions`.
2. `initialize`
3. `notifications/initialized`
4. `tools/list`
5. Assert `lisp_eval` is not advertised and `lisp_session_*` tools are
   advertised.
6. Assert a `lisp_eval` call returns `unknown_tool`.
7. Call `lisp_session_start` and assert it returns a `session_id`.
8. `notifications/exit`

Pin smoke tests to an empty upstream configuration unless the release
being tested is specifically an aggregator-mode artifact; local
operator config must not change the release gate's expected tool
surface.

Release artifacts should not be uploaded unless these checks pass.

## GitHub Workflow Direction

The release workflow should eventually:

1. Build on the native target runner.
2. Run `mix format --check-formatted` and the MCP server tests.
3. Build the production Mix release.
4. Package the release directory as `ptc_runner_mcp-<platform>.tar.gz`.
5. Generate `SHA256SUMS`.
6. Extract the archive and smoke-test the extracted binary.
7. Upload archives and `SHA256SUMS` to a GitHub Release.

Snapshots can publish to a moving prerelease such as `mcp-snapshot`.
Stable releases should publish from `mcp-v*` tags.
