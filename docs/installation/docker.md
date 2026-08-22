# Docker installation

Build and run the self-contained PtcRunner container image.

Linux is currently
verified through a local container scaffold. A public image
and multi-architecture publication contract are still pending, so there is no
registry name that the documentation can truthfully present as an installation
today.

Build and verify the local image from a source checkout:

```console
scripts/build_container_image.sh
```

The script produces `ptc:dev`, runs the standalone verification inside the
finished image, probes that image without adding packages, and confirms it runs
as a non-root user.

Run an application through an explicit mount. Match the container process to
the host user so owner-only credentials remain readable and project artifacts
remain writable; use a writable container home for runtime-local files:

```console
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --volume "$PWD:/work" \
  ptc:dev run /work/ptc-project.json
```

Do not run this form from a root shell. A root host UID would also select root
inside the container and discard the image's non-root default.

Open an interactive REPL:

```console
docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --volume "$PWD:/work" \
  ptc:dev repl
```

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
  ptc:dev viewer /work/ptc-project.json --listen 0.0.0.0
```

Open `http://localhost:4123/?live_token=$viewer_token#/live`. The page removes
the token from the visible URL after bootstrapping and uses it for Live
mutations. The Runs trace browser itself remains unauthenticated.

Writing `-p 4123:4123` instead exposes an unauthenticated trace browser to the
network. The `127.0.0.1:` prefix is the host-side security decision.

The published-image route will become the default only after the target matrix
and immutable image tags have release evidence.
