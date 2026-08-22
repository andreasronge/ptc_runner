#!/usr/bin/env bash
#
# Builds a local Linux container image and proves the release inside it.
#
#   scripts/build_container_image.sh [IMAGE_TAG]
#
# This remains a local single-platform path. The container-release workflow
# owns multi-platform publication, immutable version tags, and provenance.
#
# The build runs the standalone verification inside the image, so a failure
# here is a failure of the release, not of the packaging.

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_tag="${1:-ptc:dev}"
[ "$#" -gt 0 ] && shift

command -v docker > /dev/null || {
  echo 'docker is required to build the container image' >&2
  exit 69
}

# The Viewer probe below has to reach the container the way a user's browser
# would -- from the host, through a published port -- so this one client runs
# outside the image on purpose.
command -v curl > /dev/null || {
  echo 'curl is required to verify the published Viewer port from the host' >&2
  exit 69
}

docker buildx version > /dev/null 2>&1 || {
  echo 'docker buildx is required: the Dockerfile uses a multi-stage verify target' >&2
  exit 69
}

cd "$project_root"

# Extra arguments are forwarded to buildx, but not these two: choosing another
# target or another Dockerfile skips the in-image gate while the probes below
# still pass, and the script would report a verification that never ran.
for argument in "$@"; do
  case "$argument" in
    --target | --target=* | -f | --file | --file=*)
      echo "$argument is not accepted: it would bypass the in-image verification" >&2
      exit 64
      ;;
  esac
done

# The explicit Docker exporter keeps this tag local to the daemon. Using the
# global `--tag` option would also apply it to any extra registry exporter and
# make a push-by-digest release build try to publish the local probe tag.
# Loading still limits this helper to one platform at a time; the publication
# workflow assembles the independently verified native results afterward.
docker buildx build \
  --output "type=docker,name=$image_tag" \
  "$@" \
  --target released \
  .

# The in-image gate installs `expect` and `diffutils` to run, and an installed
# package can drag in a library the shipped image lacks -- verification that
# supplies its own dependencies can pass for an image that would fail in a
# user's hands. These probes drive the finished image with nothing added, so a
# missing runtime library shows up as the broken output it would really be.
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/ptc-image-probe.XXXXXX")"
viewer_containers=()
mounted_run=(
  --user "$(id -u):$(id -g)"
  --env HOME=/tmp
  --volume "$probe_dir:/work"
)

probe_cleanup() {
  if [ "${#viewer_containers[@]}" -gt 0 ]; then
    docker rm --force "${viewer_containers[@]}" > /dev/null 2>&1 || true
  fi
  rm -rf "$probe_dir"
}
trap probe_cleanup EXIT

cat > "$probe_dir/main.clj" <<'EOF'
(ns smoke.main)

(defn run [input]
  (return input))
EOF

cat > "$probe_dir/ptc.json" <<'EOF'
{
  "version": 1,
  "workflow": {
    "components": [{"id": "smoke.main", "path": "main.clj"}],
    "entry": "smoke.main/run"
  },
  "input": {"value": {"city": "Malmö"}},
  "providers": {"workflow": [], "mission": []}
}
EOF

cp test/support/mcp_stdio_source_fixture.sh "$probe_dir/mcp_stdio_source_fixture.sh"
chmod 0755 "$probe_dir/mcp_stdio_source_fixture.sh"

docker run --rm "${mounted_run[@]}" "$image_tag" --version > "$probe_dir/version.stdout"
grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' "$probe_dir/version.stdout"

# Exercise the target-native C launcher through the release's real stdio
# transport. Finding the optional application in the release is not enough:
# this proves its executable can start a child, frame an MCP exchange, and
# close cleanly on the architecture being verified.
docker run --rm "${mounted_run[@]}" \
  --entrypoint /opt/ptc/bin/ptc_runner \
  "$image_tag" eval '
    alias PtcRunner.Kernel.MCPStdioTransport

    [fixture, marker] = System.argv()
    {:ok, launcher} = PtcRunnerLauncher.executable_path()
    executable = "/bin/sh"

    {:ok, transport} =
      MCPStdioTransport.start(
        launcher: launcher,
        launcher_protocol_version: PtcRunnerLauncher.protocol_version(),
        executable: executable,
        executable_sha256: executable |> File.read!() |> then(&:crypto.hash(:sha256, &1)),
        cwd: "/work",
        args: [fixture, marker],
        env: %{"HOME" => "/tmp", "PATH" => "/usr/bin:/bin"},
        grace_ms: 50,
        start_timeout_ms: 5_000
      )

    metadata = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientInfo" => %{"name" => "ptc_runner", "version" => "0.x"},
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    {:ok, %{"result" => %{"supportedVersions" => ["2026-07-28"]}}} =
      MCPStdioTransport.request(transport, "server/discover", %{}, metadata, 8_192, 5_000)

    :ok = MCPStdioTransport.close(transport)
  ' /work/mcp_stdio_source_fixture.sh /work/launcher.marker
grep -Eq '^[1-9][0-9]*:server/discover$' "$probe_dir/launcher.marker"

# Standard output carries a machine contract: a runtime that writes a startup
# warning there corrupts it, and only an untouched image can prove it does not.
docker run --rm "${mounted_run[@]}" "$image_tag" run /work/ptc.json \
  > "$probe_dir/run.stdout" 2> /dev/null
printf '%s\n' '{"city":"Malmö"}' > "$probe_dir/run.expected"
cmp "$probe_dir/run.expected" "$probe_dir/run.stdout"

test "$(docker run --rm --entrypoint id "$image_tag" --user)" != "0"

# The Viewer is the one command whose container behavior the in-image gate
# cannot check: it binds inside the container's own network namespace, and the
# whole question is whether a published port reaches it from the host. Prove
# both directions here, on the finished image.
docker run --rm "${mounted_run[@]}" "$image_tag" init /work/app > /dev/null
docker run --rm "${mounted_run[@]}" "$image_tag" run /work/app/ptc-project.json \
  > /dev/null 2> /dev/null

probe_run_ref="$(basename "$(find "$probe_dir/app/.ptc/traces" -maxdepth 1 -type f -name 'cmd-*.jsonl' -print -quit)" .jsonl)"
test -n "$probe_run_ref"

# Docker chooses the host port, so this cannot collide with whatever else the
# machine is running. `127.0.0.1:` keeps the exposure on host loopback: that
# prefix is the boundary once the container binds the wildcard, and its absence
# is what would publish an unauthenticated trace browser to the network.
#
# This assigns `viewer_container` rather than printing it. A command
# substitution would run it in a subshell, where appending to
# `viewer_containers` is lost and the EXIT trap has nothing to clean up after a
# mid-probe failure.
start_viewer() {
  viewer_container="$(docker run --detach "${mounted_run[@]}" \
    --publish 127.0.0.1::4123 "$image_tag" viewer /work/app/ptc-project.json --port 4123 "$@")"
  viewer_containers+=("$viewer_container")
}

# Waiting on the log line rather than on the port: a refused connection is the
# expected answer in the negative case below, and it must mean "bound to the
# container's own loopback", not "has not started yet".
await_viewer() {
  local name="$1" deadline=$((SECONDS + 90))

  while [ "$SECONDS" -lt "$deadline" ]; do
    if docker logs "$name" 2>&1 | grep -q 'PTC Viewer listening on'; then
      return 0
    fi

    docker inspect --format '{{.State.Running}}' "$name" 2> /dev/null | grep -q true || break
    sleep 0.5
  done

  echo "the container Viewer never reported a bound port:" >&2
  docker logs "$name" >&2 || true
  exit 1
}

start_viewer --listen 0.0.0.0
published_viewer="$viewer_container"
await_viewer "$published_viewer"
published_endpoint="$(docker port "$published_viewer" 4123/tcp | head -1)"
test -n "$published_endpoint"

curl --silent --show-error --fail --max-time 20 \
  "http://$published_endpoint/api/kernel/runs" > "$probe_dir/viewer.json"
grep -q "$probe_run_ref" "$probe_dir/viewer.json"

# And the negative that justifies the flag: without it the Viewer binds the
# container's own loopback, which a published port cannot forward to.
start_viewer
loopback_viewer="$viewer_container"
await_viewer "$loopback_viewer"
loopback_endpoint="$(docker port "$loopback_viewer" 4123/tcp | head -1)"
test -n "$loopback_endpoint"

# `--fail` is not the test: it also reports 4xx and 5xx as failures, so a
# regression that exposed the Viewer but answered 404 would read as unreachable.
# `%{http_code}` is `000` only when no HTTP response arrived at all, which is
# the actual claim -- the published port does not reach a loopback bind.
loopback_code="$(curl --silent --output /dev/null --max-time 10 \
  --write-out '%{http_code}' "http://$loopback_endpoint/api/kernel/runs" || true)"

if [ "$loopback_code" != "000" ]; then
  echo 'a container Viewer without --listen answered through a published port' >&2
  echo "the loopback default is not holding (HTTP $loopback_code)" >&2
  exit 1
fi

docker rm --force "$published_viewer" "$loopback_viewer" > /dev/null
viewer_containers=()

echo
echo "built $image_tag; the standalone verification passed inside it,"
echo "and the finished image answers correctly with nothing added to it"
echo "try: docker run --rm -it --user \"\$(id -u):\$(id -g)\" --env HOME=/tmp \\"
echo "       -v \"\$PWD:/work\" $image_tag repl"
echo "     docker run --rm --user \"\$(id -u):\$(id -g)\" --env HOME=/tmp \\"
echo "       -p 127.0.0.1:4123:4123 -v \"\$PWD:/work\" $image_tag \\"
echo "       viewer /work/ptc-project.json --listen 0.0.0.0 --port 4123"
