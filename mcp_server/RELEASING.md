# Releasing `ptc_runner_mcp`

`ptc_runner_mcp` is distributed as a standalone GitHub Release archive,
not as a Hex package. Stable MCP releases use `mcp-v*` tags so they do
not collide with root library `v*` tags.

## Target

Initial automated target:

```text
ptc_runner_mcp-darwin-arm64.tar.gz
```

Add other platforms only after the same build, checksum, extraction, and
smoke-test flow is automated for them.

## Release Gate

To rehearse the gate, artifact packaging, checksum verification, and
extracted-artifact smoke tests without publishing anything:

```bash
cd mcp_server
mix mcp.release_dry_run
```

This dry run creates only local build/package/smoke artifacts. It does
not create Git tags, push tags, create GitHub Releases, or upload
artifacts.

The release artifact should be uploaded only after CI has completed this
sequence on the target runner:

```bash
cd mcp_server
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test --max-failures 1 --trace --warnings-as-errors
MIX_ENV=prod mix release --overwrite
```

Package the full Mix release directory, not only `bin/ptc_runner_mcp`:

```bash
mkdir -p tmp/release_dist
tar -czf tmp/release_dist/ptc_runner_mcp-darwin-arm64.tar.gz \
  -C _build/prod/rel ptc_runner_mcp
cd tmp/release_dist
shasum -a 256 ptc_runner_mcp-*.tar.gz > SHA256SUMS
shasum -a 256 -c SHA256SUMS
```

## Artifact Smoke

Smoke-test the extracted archive, not the build directory:

```bash
mkdir -p tmp/release_smoke/extract
tar -xzf tmp/release_dist/ptc_runner_mcp-darwin-arm64.tar.gz \
  -C tmp/release_smoke/extract
bin="$PWD/tmp/release_smoke/extract/ptc_runner_mcp/bin/ptc_runner_mcp"
"$bin" version
```

Then run stdio JSON-RPC smoke tests for both public tool surfaces.

Pin smoke tests to an empty upstream configuration unless the artifact is
specifically an aggregator-mode artifact:

```bash
PTC_RUNNER_MCP_UPSTREAMS=/nonexistent/ptc_runner_mcp_release_smoke
PTC_RUNNER_MCP_RESPONSE_PROFILE=slim
```

Stateless mode:

1. Start `"$bin" start`.
2. Send `initialize`.
3. Send `notifications/initialized`.
4. Send `tools/list`.
5. Assert `lisp_eval` is advertised.
6. Assert `lisp_eval` has `inputSchema` and no `outputSchema` in slim mode.
7. Call `lisp_eval` with `(+ 1 2)`.
8. Assert the slim text result is `user=> 3` and has no
   `structuredContent`.
9. Send `exit`.

Session mode:

1. Start `"$bin" start --sessions`.
2. Send `initialize`.
3. Send `notifications/initialized`.
4. Send `tools/list`.
5. Assert `lisp_eval` is not advertised.
6. Assert `lisp_session_*` tools are advertised.
7. Assert calling `lisp_eval` returns `unknown_tool`.
8. Call `lisp_session_start` and assert it returns a `session_id`.
9. Send `exit`.

## Publish

Stable release:

```bash
git tag mcp-vX.Y.Z
git push origin mcp-vX.Y.Z
```

The GitHub release should contain:

- `ptc_runner_mcp-darwin-arm64.tar.gz`
- `SHA256SUMS`

Snapshot release automation may publish the same artifact shape to a
moving prerelease such as `mcp-snapshot`.

## Manual Fallback

Until an MCP-specific GitHub Actions workflow exists, run the same steps
locally on Apple Silicon macOS, then create the GitHub Release manually
for the `mcp-v*` tag and upload the archive plus `SHA256SUMS`.

Prefer releasing from a clean checkout/tag. If CI needs explicit build
metadata, set:

```bash
PTC_RUNNER_MCP_GIT_COMMIT=<commit>
PTC_RUNNER_MCP_GIT_DIRTY=false
```
