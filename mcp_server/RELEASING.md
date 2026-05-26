# Releasing `ptc_runner_mcp`

`ptc_runner_mcp` is distributed as a standalone GitHub Release archive
and as a Docker image on GitHub Container Registry, not as a Hex
package. Stable MCP releases use `mcp-v*` tags so they do not collide
with root library `v*` tags.

## Target

Initial automated target:

```text
ptc_runner_mcp-darwin-arm64.tar.gz
ghcr.io/andreasronge/ptc-runner-mcp:TAG
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

The `mcp-v*` tag triggers `.github/workflows/mcp-docker.yml`, which
builds and pushes the Docker image to GHCR with:

```text
ghcr.io/andreasronge/ptc-runner-mcp:mcp-vX.Y.Z
ghcr.io/andreasronge/ptc-runner-mcp:X.Y.Z
ghcr.io/andreasronge/ptc-runner-mcp:sha-<short-sha>
```

Pushes to `main` publish snapshot tags:

```text
ghcr.io/andreasronge/ptc-runner-mcp:snapshot
ghcr.io/andreasronge/ptc-runner-mcp:main
ghcr.io/andreasronge/ptc-runner-mcp:sha-<short-sha>
```

The workflow uses `GITHUB_TOKEN` with `packages: write`; no personal
access token is needed for CI publishing.

The GitHub release should contain:

- `ptc_runner_mcp-darwin-arm64.tar.gz`
- `SHA256SUMS`

Snapshot release automation may publish the same artifact shape to a
moving prerelease such as `mcp-snapshot`.

## Docker Smoke

Before relying on CI, build and smoke-test the image locally:

```bash
mcp_server/scripts/docker-build.sh \
  --image ghcr.io/andreasronge/ptc-runner-mcp \
  --tag local \
  --load

docker run --rm ghcr.io/andreasronge/ptc-runner-mcp:local version
```

HTTP smoke:

```bash
export PTC_RUNNER_MCP_HTTP_AUTH_TOKEN="$(openssl rand -base64 32)"

docker run --rm -d --name ptc-runner-mcp-smoke -p 7332:7332 \
  -e PTC_RUNNER_MCP_HTTP_AUTH_TOKEN="$PTC_RUNNER_MCP_HTTP_AUTH_TOKEN" \
  ghcr.io/andreasronge/ptc-runner-mcp:local

curl http://127.0.0.1:7332/health
curl http://127.0.0.1:7332/ready

docker stop ptc-runner-mcp-smoke
```

Check publish tag selection without pushing:

```bash
mcp_server/scripts/docker-publish.sh \
  --image ghcr.io/andreasronge/ptc-runner-mcp \
  --ref refs/tags/mcp-vX.Y.Z \
  --sha "$(git rev-parse HEAD)" \
  --dry-run
```

## Manual Fallback

If GitHub Actions publishing is unavailable, run the same archive steps
locally on Apple Silicon macOS, then create the GitHub Release manually
for the `mcp-v*` tag and upload the archive plus `SHA256SUMS`.

For a manual Docker push, first authenticate to GHCR with a GitHub
personal access token that has `write:packages`, then run:

```bash
echo "$CR_PAT" | docker login ghcr.io -u andreasronge --password-stdin

mcp_server/scripts/docker-publish.sh \
  --image ghcr.io/andreasronge/ptc-runner-mcp \
  --ref refs/tags/mcp-vX.Y.Z \
  --sha "$(git rev-parse HEAD)"
```

Prefer releasing from a clean checkout/tag. If CI needs explicit build
metadata, set:

```bash
PTC_RUNNER_MCP_GIT_COMMIT=<commit>
PTC_RUNNER_MCP_GIT_DIRTY=false
```
