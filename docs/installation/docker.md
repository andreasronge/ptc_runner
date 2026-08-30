# Docker installation

Install the self-contained Linux AMD64 or ARM64 image and run the PtcRunner CLI,
Viewer, and stdio launcher without a build toolchain.

Images are published as `ghcr.io/andreasronge/ptc_runner` starting with the
first root release after the container publication workflow lands. Older
releases are not backfilled. The image does not contain runtimes used by
external MCP servers.

## Pull and verify the image

Use an exact version tag for deployments:

```console
version=VERSION
image="ghcr.io/andreasronge/ptc_runner:$version"
docker pull "$image"
docker run --rm "$image" --version
```

Replace `VERSION` with a three-part release version such as `0.14.0`. The release
workflow creates each exact version tag once and refuses to replace one. GHCR
does not enforce that policy as registry-level tag immutability, so pin the
pulled repository digest and verify its attestation in automated deployments.
There are no moving `latest` or `MAJOR.MINOR` tags; PtcRunner is 0.x and breaking
changes are expected.

Each image has signed GitHub build provenance. Verification requires GitHub CLI
authentication and a registry login, including for a public image:

```console
gh auth refresh --scopes read:packages
gh auth token | docker login ghcr.io \
  --username "$(gh api user --jq .login)" --password-stdin
gh attestation verify "oci://$image" \
  --repo andreasronge/ptc_runner \
  --signer-workflow \
    andreasronge/ptc_runner/.github/workflows/container-release.yml \
  --source-ref "refs/tags/v$version" \
  --deny-self-hosted-runners
```

The added `read:packages` scope allows Docker to authenticate to GHCR. A classic
personal access token carrying `read:packages` can be used instead.

## Run a project

Map the container process to the host user so owner-only credentials remain
readable and project artifacts remain writable. Supply a writable home for
runtime-local files:

```console
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --volume "$PWD:/work" \
  "$image" init /work/hello-ptc

docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --volume "$PWD:/work" \
  "$image" run /work/hello-ptc/ptc-project.json
```

The generated project keeps traces and command envelopes under its mounted
`.ptc` directory, so `--rm` does not discard them. Do not run this form from a
root shell: a root host UID would also select root inside the container and
discard the image's non-root default. Without `--user`, the image runs as its
built-in `ptc` user with UID and GID 10001.

Mount host configuration and dotenv files only where the project expects them.
PTC's `--env-file` appears after the image name and is distinct from Docker's
option of the same name:

```console
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --volume "$PWD:/work" \
  "$image" run /work/hello-ptc/ptc-project.json \
    --env-file /work/hello-ptc/.env
```

Remote model and credential-based MCP providers work normally. A stdio MCP
server runs inside the container namespace: its executable and runtime must be
Linux-compatible and present in the image or an explicit mount. In particular,
the published image does not add Node.js or `npx`. Build a derived image when a
local MCP server needs another runtime. The runtime-included frontend also does
not initiate interactive MCP OAuth authorization; authorize through a
supported embedding host or use a provider that can execute non-interactively.

## Open a REPL

Allocate a terminal for interactive editing and history:

```console
docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --volume "$PWD:/work" \
  "$image" repl
```

## Open the Viewer

The Viewer binds to the container's loopback unless explicitly told otherwise,
which a published port cannot reach. Bind the wildcard only inside the
container and keep the host publication on loopback:

```console
viewer_token="$(openssl rand -hex 32)"
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --env PTC_VIEWER_TOKEN="$viewer_token" \
  -p 127.0.0.1:4123:4123 \
  -v "$PWD:/work" \
  "$image" viewer /work/hello-ptc/ptc-project.json \
    --listen 0.0.0.0 --port 4123
```

Open `http://localhost:4123/?live_token=$viewer_token#/live`. The page removes
the token from the visible URL after bootstrapping and uses it for Live reads
and mutations. The Runs trace browser itself remains unauthenticated.

Writing `-p 4123:4123` instead exposes that unauthenticated trace browser to the
network. The `127.0.0.1:` prefix is the host-side security decision.

## Build from a checkout

Maintainers can build and verify one local platform without publishing it:

```console
scripts/build_container_image.sh
```

The script produces `ptc:dev`, runs the standalone verification inside the
image, probes the finished image without adding packages, and confirms it runs
as a non-root user.
