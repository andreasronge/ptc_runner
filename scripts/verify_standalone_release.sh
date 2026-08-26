#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ptc-runner-standalone-release.XXXXXX")"

# The Viewer check runs a long-lived command in the background. Reaping it
# belongs in the trap rather than beside the assertions, because any `set -e`
# failure between spawn and stop would otherwise leave it holding a port.
viewer_pid=""

# Never a bare `wait` after signalling: a shutdown regression is exactly what
# this gate exists to catch, and an unbounded wait would turn it into a CI run
# that hangs forever instead of failing. Returns 0 when the process left on its
# own, 1 when it had to be killed.
stop_viewer_process() {
  local deadline=$((SECONDS + 30))

  kill -TERM "$viewer_pid" 2> /dev/null || true

  while kill -0 "$viewer_pid" 2> /dev/null && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.2
  done

  if kill -0 "$viewer_pid" 2> /dev/null; then
    kill -KILL "$viewer_pid" 2> /dev/null || true
    wait "$viewer_pid" 2> /dev/null || true
    return 1
  fi

  return 0
}

cleanup() {
  if [ -n "$viewer_pid" ]; then
    stop_viewer_process || true
    wait "$viewer_pid" 2> /dev/null || true
  fi
  rm -rf "$release_tmp_dir"
}
trap cleanup EXIT

# Packaging rewrites and re-signs the assembled tree, so the artifact a user
# runs is not the tree `mix release` produced. `PTC_RELEASE_ROOT` points this
# gate at an already-packaged release and skips assembly, which is how the
# packaging script proves what it is about to publish rather than a rebuild of
# it.
release_root="${PTC_RELEASE_ROOT:-$release_tmp_dir/release}"
fixture_root="$release_tmp_dir/fixture"
application_root="$fixture_root/application"
command_bin="$release_root/bin/ptc"

mkdir -p "$application_root"

cat > "$application_root/main.clj" <<'EOF'
(ns smoke.main)

(defn run [input]
  (return input))
EOF

cat > "$application_root/ptc.json" <<'EOF'
{
  "version": 1,
  "workflow": {
    "components": [{"id": "smoke.main", "path": "main.clj"}],
    "entry": "smoke.main/run"
  },
  "input": {"value": {"city": "Malmö", "note": "café — 5 €"}},
  "providers": {"workflow": [], "mission": []}
}
EOF

cat > "$application_root/private-ptc.json" <<'EOF'
{
  "version": 1,
  "workflow": {
    "components": [{"id": "smoke.main", "path": "main.clj"}],
    "entry": "smoke.main/run"
  },
  "input": {"value": {"private": true}},
  "events": {"policy": "private"},
  "providers": {"workflow": [], "mission": []}
}
EOF

cat > "$fixture_root/provider-host.json" <<'EOF'
{
  "credentials": {"key": {"literal": "invalid-smoke-credential"}},
  "install": {
    "model": {
      "source": "llm",
      "structured_output_mode": "unsupported",
      "installation_revision": "release-smoke-v1",
      "model": "openrouter:release-smoke/invalid-model",
      "credential": "key"
    }
  },
  "limits": {"doctor_connectivity_timeout_ms": 100}
}
EOF

cat > "$fixture_root/provider-application.json" <<'EOF'
{
  "version": 1,
  "workflow": {
    "components": [{"id": "smoke.main", "path": "application/main.clj"}],
    "entry": "smoke.main/run"
  },
  "input": {"value": {}},
  "providers": {
    "workflow": [{"name": "model", "config": {}}],
    "mission": []
  }
}
EOF

cd "$project_root"
if [ -z "${PTC_RELEASE_ROOT:-}" ]; then
  MIX_ENV=prod mix release ptc_runner --overwrite --path "$release_root"
fi

test -x "$command_bin"

if command -v elixir > /dev/null; then
  test -d "$release_root/erts-$(elixir -e 'IO.write(:erlang.system_info(:version))')"
else
  # Verifying a packaged artifact where no toolchain sits beside it -- inside
  # the runtime container, for instance. What matters there is that the runtime
  # travelled with the artifact, not which toolchain assembled it.
  test "$(find "$release_root" -maxdepth 1 -type d -name 'erts-*' | wc -l)" -eq 1
fi
find "$release_root/lib" -maxdepth 1 -type d -name 'req_llm-*' -print -quit | grep -q .
find "$release_root/lib" -maxdepth 1 -type d -name 'ptc_viewer-*' -print -quit | grep -q .
cmp "$project_root/THIRD_PARTY_NOTICES.md" "$release_root/THIRD_PARTY_NOTICES.md"
cmp "$project_root/LICENSES/Apache-2.0.txt" "$release_root/LICENSES/Apache-2.0.txt"
cmp "$project_root/LICENSES/MIT.txt" "$release_root/LICENSES/MIT.txt"
"$release_root/bin/ptc_runner" eval '
  true = PtcRunner.Kernel.SemanticRevision.runtime_dependency_artifacts_verified?()
'

"$command_bin" --version > "$release_tmp_dir/version.stdout"
grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+ \([0-9a-f]{8}, (clean|dirty)\)$' "$release_tmp_dir/version.stdout"

"$command_bin" help > "$release_tmp_dir/help.stdout"
grep -q '^Usage:$' "$release_tmp_dir/help.stdout"
grep -Fqx '  --help    — show root help' "$release_tmp_dir/help.stdout"
for command in init docs validate run doctor models repl viewer; do
  grep -q "ptc $command" "$release_tmp_dir/help.stdout"
  "$command_bin" help "$command" > "$release_tmp_dir/help-$command.stdout"
done

"$command_bin" init "$fixture_root/initialized" > "$release_tmp_dir/init.stdout"
test -f "$fixture_root/initialized/ptc.json"
grep -qx 'created AGENTS.md, .gitignore, main.clj, ptc.json, ptc-project.json' "$release_tmp_dir/init.stdout"
test -f "$fixture_root/initialized/AGENTS.md"

# The release must serve its own documentation from the embedded catalog, with
# no repository checkout, no `priv` documentation directory, and no network.
"$command_bin" docs > "$release_tmp_dir/docs.stdout"
grep -q '^Pages:$' "$release_tmp_dir/docs.stdout"
grep -q '^  agent-guide ' "$release_tmp_dir/docs.stdout"
"$command_bin" docs agent-guide > "$release_tmp_dir/docs-agent-guide.stdout"
grep -qx '# Drive ptc as an agent' "$release_tmp_dir/docs-agent-guide.stdout"
"$command_bin" docs schema-project > "$release_tmp_dir/docs-schema-project.stdout"
grep -q 'ptc-project-config.schema.json' "$release_tmp_dir/docs-schema-project.stdout"
"$command_bin" docs schema-mcp > "$release_tmp_dir/docs-schema-mcp.stdout"
cmp "$project_root/site/schemas/mcp-2026-07-28.schema.json" "$release_tmp_dir/docs-schema-mcp.stdout"
if "$command_bin" docs no-such-page > "$release_tmp_dir/docs-unknown.stdout" 2>&1; then
  echo "expected 'ptc docs no-such-page' to fail" >&2
  exit 1
fi

"$command_bin" validate "$application_root/ptc.json" > "$release_tmp_dir/validate.stdout"
grep -q '"provider_activity":false' "$release_tmp_dir/validate.stdout"

"$command_bin" run "$application_root/ptc.json" > "$release_tmp_dir/run.stdout"
printf '%s\n' '{"city":"Malmö","note":"café — 5 €"}' > "$release_tmp_dir/run.expected"
cmp "$release_tmp_dir/run.expected" "$release_tmp_dir/run.stdout"

envelope_path="$release_tmp_dir/run-envelope.json"
"$command_bin" run "$application_root/ptc.json" --envelope "$envelope_path" \
  > "$release_tmp_dir/envelope.stdout" \
  2> "$release_tmp_dir/envelope.stderr"
cmp "$release_tmp_dir/run.expected" "$release_tmp_dir/envelope.stdout"
test ! -s "$release_tmp_dir/envelope.stderr"
"$release_root/bin/ptc_runner" eval '
  [path] = System.argv()
  envelope = path |> File.read!() |> Jason.decode!()
  true = PtcRunner.Kernel.CommandContract.valid_envelope?(envelope)
  "ok" = envelope["status"]
' "$envelope_path"

failed_envelope="$release_tmp_dir/failed-envelope.json"
set +e
"$command_bin" validate "$application_root/missing.json" --envelope "$failed_envelope" \
  > "$release_tmp_dir/failed-envelope.stdout" \
  2> "$release_tmp_dir/failed-envelope.stderr"
failed_envelope_status=$?
set -e
test "$failed_envelope_status" -eq 3
test ! -s "$release_tmp_dir/failed-envelope.stdout"
grep -q 'application/application_not_found' "$release_tmp_dir/failed-envelope.stderr"
"$release_root/bin/ptc_runner" eval '
  [path] = System.argv()
  envelope = path |> File.read!() |> Jason.decode!()
  true = PtcRunner.Kernel.CommandContract.valid_envelope?(envelope)
  "error" = envelope["status"]
' "$failed_envelope"

rejected_envelope="$release_tmp_dir/rejected-envelope.json"
set +e
"$command_bin" run "$application_root/ptc.json" --unknown \
  --envelope "$rejected_envelope" \
  > "$release_tmp_dir/rejected.stdout" \
  2> "$release_tmp_dir/rejected.stderr"
rejected_status=$?
set -e
test "$rejected_status" -eq 2
test ! -e "$rejected_envelope"
grep -q 'arguments/invalid_arguments' "$release_tmp_dir/rejected.stderr"
grep -q 'unknown switch; accepted:' "$release_tmp_dir/rejected.stderr"

collision_path="$release_tmp_dir/collision.json"
set +e
"$command_bin" run "$application_root/ptc.json" \
  --output "$collision_path" --envelope "$collision_path" \
  > "$release_tmp_dir/collision.stdout" \
  2> "$release_tmp_dir/collision.stderr"
collision_status=$?
set -e
test "$collision_status" -eq 2
test ! -e "$collision_path"
grep -q 'arguments/conflicting_arguments' "$release_tmp_dir/collision.stderr"
grep -q 'two destinations name the same file: --output and --envelope' \
  "$release_tmp_dir/collision.stderr"

existing_envelope="$release_tmp_dir/existing-envelope.json"
printf '%s\n' 'original' > "$existing_envelope"
set +e
"$command_bin" doctor --envelope "$existing_envelope" \
  > "$release_tmp_dir/existing-envelope.stdout" \
  2> "$release_tmp_dir/existing-envelope.stderr"
existing_envelope_status=$?
set -e
test "$existing_envelope_status" -eq 2
printf '%s\n' 'original' > "$release_tmp_dir/existing-envelope.expected"
cmp "$release_tmp_dir/existing-envelope.expected" "$existing_envelope"
grep -q 'arguments/envelope_destination_exists' "$release_tmp_dir/existing-envelope.stderr"
grep -q 'remove it or point --envelope at another path' \
  "$release_tmp_dir/existing-envelope.stderr"

"$command_bin" doctor "$application_root/ptc.json" > "$release_tmp_dir/doctor.stdout"
grep -q '"provider_activity":false' "$release_tmp_dir/doctor.stdout"

"$command_bin" models --host-config "$fixture_root/provider-host.json" \
  > "$release_tmp_dir/models.stdout"
grep -q '"installations"' "$release_tmp_dir/models.stdout"

"$command_bin" repl -e -10 > "$release_tmp_dir/repl.stdout"
printf '%s\n' '-10' > "$release_tmp_dir/repl.expected"
cmp "$release_tmp_dir/repl.expected" "$release_tmp_dir/repl.stdout"

# The interactive REPL installs OTP's line editor only when stdin is a
# terminal, so every other check above runs the plain reader and none of them
# can observe it. Drive the packaged command through a pseudo-terminal:
# assemble one expression with emacs keys, recall it from history, then prove
# the recall survives process exit. `PTC_SKIP_PTY_GATE` exists for a host that
# knowingly cannot provide a terminal. Per-PR core-release sets it; Nightly,
# Docker verify, and packaging install `expect` and run the check.
if [ -n "${PTC_SKIP_PTY_GATE:-}" ]; then
  echo 'note: PTC_SKIP_PTY_GATE set, skipped the interactive REPL check' >&2
else
  command -v expect > /dev/null || {
    echo 'expect(1) is required to verify the interactive REPL' >&2
    exit 1
  }

  # The editor reads the terminal type: with `TERM` unset or `dumb` -- a build
  # container, a bare CI step -- the group runs in dumb mode, and `Ctrl+A`
  # lands in the expression as a literal byte instead of moving the cursor.
  # That fallback is correct behavior, but it is not what this gate exists to
  # check, so the gate supplies a terminal type rather than inheriting one.
  export TERM="${TERM:-xterm}"

  HOME="$release_tmp_dir/home" expect -f - "$command_bin" > "$release_tmp_dir/pty.stdout" <<'EXPECT'
set timeout 60
log_user 1
spawn [lindex $argv 0] repl
expect "ptc> "
send "+ 2 3"
after 300
send "\001("
after 200
send "\005)\r"
expect -re "\r\n5\r\n"
send "\033\[A"
after 300
send "\r"
expect -re "\r\n5\r\n"
send ":quit\r"
expect eof
EXPECT

  HOME="$release_tmp_dir/home" expect -f - "$command_bin" > "$release_tmp_dir/pty-history.stdout" <<'EXPECT'
set timeout 60
log_user 1
spawn [lindex $argv 0] repl
expect "ptc> "
after 500
send "\033\[A"
after 300
send "\033\[A"
after 300
send "\r"
expect -re "\r\n5\r\n"
send ":quit\r"
expect eof
EXPECT

  grep -q '(+ 2 3)' "$release_tmp_dir/pty.stdout"
  grep -q '(+ 2 3)' "$release_tmp_dir/pty-history.stdout"
fi

set +e
"$command_bin" repl --manifest "$application_root/private-ptc.json" --private-terminal \
  < /dev/null \
  > "$release_tmp_dir/private-repl.stdout" \
  2> "$release_tmp_dir/private-repl.stderr"
private_repl_status=$?
set -e
test "$private_repl_status" -eq 1
grep -q 'private manifest REPL requires attached stdin and stdout terminals' \
  "$release_tmp_dir/private-repl.stderr"

set +e
"$command_bin" doctor "$fixture_root/provider-application.json" \
  --host-config "$fixture_root/provider-host.json" \
  --connect \
  > "$release_tmp_dir/provider.stdout" \
  2> "$release_tmp_dir/provider.stderr"
provider_status=$?
set -e

test "$provider_status" -eq 4
grep -Eq 'active_preflight/connectivity_(unavailable|timeout)' \
  "$release_tmp_dir/provider.stderr"
if grep -q 'provider_application_unavailable' "$release_tmp_dir/provider.stderr"; then
  echo 'assembled release did not admit its command-owned optional provider application' >&2
  exit 1
fi

# The Viewer ships inside the release, so the gate proves the packaged command
# actually serves rather than only that its application directory is present.
# `--port 0` asks the operating system for a free port: a fixed one collides
# with whatever already holds it on a shared machine. Redirecting stdout also
# exercises the browser-open gate, because the `init` project sets
# `"open": true` and there is no terminal here.
project_root_fixture="$fixture_root/initialized"
"$command_bin" run "$project_root_fixture/ptc-project.json" > "$release_tmp_dir/viewer-run.stdout"

viewer_trace="$(find "$project_root_fixture/.ptc/traces" -maxdepth 1 -type f -name 'cmd-*.jsonl' -print -quit)"
test -n "$viewer_trace"
viewer_run_ref="$(basename "$viewer_trace" .jsonl)"

viewer_log="$release_tmp_dir/viewer.stdout"
"$command_bin" viewer "$project_root_fixture/ptc-project.json" --port 0 \
  < /dev/null \
  > "$viewer_log" \
  2> "$release_tmp_dir/viewer.stderr" &
viewer_pid=$!

viewer_port=""
viewer_deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$viewer_deadline" ]; do
  viewer_port="$(sed -n 's|^PTC Viewer listening on http://127\.0\.0\.1:\([0-9]\{1,5\}\)$|\1|p' "$viewer_log")"
  [ -n "$viewer_port" ] && break
  kill -0 "$viewer_pid" 2> /dev/null || break
  sleep 0.2
done

if [ -z "$viewer_port" ]; then
  echo 'the packaged viewer never reported a bound port' >&2
  cat "$release_tmp_dir/viewer.stderr" >&2
  exit 1
fi

# No `curl` here on purpose: the Docker verify stage installs only `expect` and
# `diffutils`, and a probe that installs its own tooling can pass for an image
# that would fail in a user's hands. The release carries a runtime that can
# open a socket, so it makes its own request.
"$release_root/bin/ptc_runner" eval '
  [port, run_ref] = System.argv()
  port = String.to_integer(port)
  deadline = System.monotonic_time(:millisecond) + 30_000

  connect = fn connect ->
    options = [:binary, active: false, packet: :raw]

    case :gen_tcp.connect(~c"127.0.0.1", port, options, 1_000) do
      {:ok, socket} ->
        socket

      {:error, reason} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          connect.(connect)
        else
          raise "the packaged viewer never accepted a connection: #{inspect(reason)}"
        end
    end
  end

  read = fn read, socket, acc ->
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, bytes} -> read.(read, socket, acc <> bytes)
      {:error, :closed} -> acc
      {:error, reason} -> raise "the packaged viewer response failed: #{inspect(reason)}"
    end
  end

  request = fn path ->
    socket = connect.(connect)

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nConnection: close\r\n\r\n"
      )

    response = read.(read, socket, "")
    :ok = :gen_tcp.close(socket)
    response
  end

  response = request.("/api/kernel/runs")

  unless String.starts_with?(response, "HTTP/1.1 200 ") do
    raise "the packaged viewer did not answer 200: #{String.slice(response, 0, 120)}"
  end

  unless String.contains?(response, run_ref) do
    raise "the packaged viewer did not list the run it was pointed at"
  end

  launch_response = request.("/api/live/launch")

  unless String.starts_with?(launch_response, "HTTP/1.1 200 ") and
           String.contains?(launch_response, ~s("enabled":true)) do
    raise "the packaged project viewer did not enable its fixed launch target"
  end
' "$viewer_port" "$viewer_run_ref"

# `rel/overlays/bin/ptc` execs `bin/ptc_runner eval`, which execs the runtime,
# so this signals the VM itself and OTP stops it through `init:stop/0`.
if ! stop_viewer_process; then
  viewer_pid=""
  echo 'the packaged viewer did not stop on SIGTERM within 30s' >&2
  exit 1
fi

set +e
wait "$viewer_pid"
viewer_status=$?
set -e
viewer_pid=""
test "$viewer_status" -eq 0

"$release_root/bin/ptc_runner" eval '
  [port] = System.argv()
  port = String.to_integer(port)
  deadline = System.monotonic_time(:millisecond) + 10_000

  refused = fn refused ->
    case :gen_tcp.connect(~c"127.0.0.1", port, [active: false], 1_000) do
      {:error, _reason} ->
        :ok

      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)

        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          refused.(refused)
        else
          raise "the stopped viewer still holds its port"
        end
    end
  end

  refused.(refused)
' "$viewer_port"
