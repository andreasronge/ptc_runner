#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/ci/_error_trap.sh"

project_root="$(cd "$script_dir/.." && pwd)"
release_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ptc-runner-standalone-release.XXXXXX")"

# The Viewer check runs a long-lived command in the background. Reaping it
# belongs in the trap rather than beside the assertions, because any `set -e`
# failure between spawn and stop would otherwise leave it holding a port.
viewer_pid=""
gateway_pid=""
gateway_provider_pid=""

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
  if [ -n "$gateway_pid" ]; then
    if ! kill -0 "$gateway_pid" 2> /dev/null; then
      cat "$release_tmp_dir/gateway.stderr" >&2
    fi
    kill -TERM "$gateway_pid" 2> /dev/null || true
    wait "$gateway_pid" 2> /dev/null || true
  fi
  if [ -n "$gateway_provider_pid" ]; then
    kill -TERM "$gateway_provider_pid" 2> /dev/null || true
    wait "$gateway_provider_pid" 2> /dev/null || true
  fi
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

(defn run
  "Returns the supplied input."
  {:signature "(input :map) -> :map"}
  [input]
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

interrupt_root="$fixture_root/interrupt"
mkdir -p "$interrupt_root"

cat > "$interrupt_root/main.clj" <<'EOF'
(ns probe.main "Busy loop with no provider." {:visibility :prompt})

(defn run [input]
  (return (loop [i 0 acc 0]
            (if (< i 6000000) (recur (inc i) (+ acc i)) acc))))
EOF

cat > "$interrupt_root/ptc.json" <<'EOF'
{
  "version": 1,
  "workflow": {
    "components": [{"id": "probe.main", "path": "main.clj"}],
    "entry": "probe.main/run"
  },
  "input": {"value": {}},
  "providers": {"workflow": [], "mission": []},
  "limits": {
    "run_duration_ms": 120000,
    "workflow_timeout_ms": 120000,
    "evaluation_timeout_ms": 120000
  }
}
EOF

cat > "$interrupt_root/ptc-project.json" <<'EOF'
{
  "kind": "ptc-project",
  "version": 1,
  "application": {"path": "ptc.json"},
  "artifacts": {
    "root": ".ptc",
    "trace": true,
    "inspection": false,
    "result": false,
    "envelope": false
  }
}
EOF

cat > "$fixture_root/provider-host.json" <<'EOF'
{
  "credentials": {"key": {"literal": "invalid-smoke-credential"}},
  "install": {
    "model": {
      "source": "llm",
      "structured_output_mode": "unsupported",
      "usage_guarantees": {"tokens": true, "cost_currency": "USD"},
      "installation_revision": "release-smoke-v2",
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
find "$release_root/lib" -path '*/priv/shipped_export_owners.json' -type f -print -quit | grep -q .
"$release_root/bin/ptc_runner" eval '
  true = PtcRunner.Kernel.SemanticRevision.runtime_dependency_artifacts_verified?()
'

"$command_bin" --version > "$release_tmp_dir/version.stdout"
grep -Eq \
  '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)? \([0-9a-f]{8}, (clean|dirty)\)$' \
  "$release_tmp_dir/version.stdout"

"$command_bin" help > "$release_tmp_dir/help.stdout"
grep -q '^Usage:$' "$release_tmp_dir/help.stdout"
grep -Fqx '  --help    — show root help' "$release_tmp_dir/help.stdout"
for command in init docs validate run doctor models repl version viewer materialize; do
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
"$command_bin" docs inspect-source > "$release_tmp_dir/docs-inspect-source.stdout"
grep -qx '# Inspect source and generated programs' \
  "$release_tmp_dir/docs-inspect-source.stdout"
"$command_bin" docs source-inspection > "$release_tmp_dir/docs-source-inspection.stdout"
grep -qx '# Source-inspection reference' \
  "$release_tmp_dir/docs-source-inspection.stdout"
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

# Run the command in its own foreground-style process group, as a terminal
# does, and interrupt the group. The packaged command must leave signal
# handling to the OS rather than opening the BEAM break menu or returning 0.
interrupt_status="$(python3 - \
  "$command_bin" \
  "$interrupt_root/ptc-project.json" \
  "$release_tmp_dir/interrupt.stdout" \
  "$release_tmp_dir/interrupt.stderr" <<'PYTHON'
import os
import signal
import subprocess
import sys
import time

command, project, stdout_path, stderr_path = sys.argv[1:]
with open(stdout_path, "wb") as stdout, open(stderr_path, "wb") as stderr:
    process = subprocess.Popen(
        [command, "run", project, "--progress"],
        stdin=subprocess.DEVNULL,
        stdout=stdout,
        stderr=stderr,
        start_new_session=True,
    )

    # The non-TTY progress writer emits its preparing milestone only after the
    # packaged BEAM has started and parsed the run command. Waiting for that
    # observable command boundary proves SIGINT can reach the runtime; elapsed
    # time says nothing about readiness when another build lane owns the CPU.
    readiness_marker = b"[00:00] preparing "
    readiness_deadline = time.monotonic() + 60
    ready = False
    while process.poll() is None:
        with open(stderr_path, "rb") as progress:
            ready = readiness_marker in progress.read()
        if ready:
            break
        if time.monotonic() >= readiness_deadline:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise SystemExit("packaged ptc run did not become ready within 60s")
        time.sleep(0.05)

    if not ready:
        raise SystemExit("packaged ptc run exited before becoming ready")

    os.killpg(process.pid, signal.SIGINT)
    try:
        returncode = process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        raise SystemExit("packaged ptc run did not stop on SIGINT within 30s")

if returncode >= 0:
    with open(stderr_path, encoding="utf-8") as stderr:
        sys.stderr.write(stderr.read())
print(128 - returncode if returncode < 0 else returncode)
PYTHON
)"
test "$interrupt_status" -eq 130
if grep -q 'BREAK:' "$release_tmp_dir/interrupt.stdout" \
  "$release_tmp_dir/interrupt.stderr"; then
  echo 'packaged ptc run opened the BEAM break menu on SIGINT' >&2
  exit 1
fi
if [[ -d "$interrupt_root/.ptc" ]]; then
  test -z "$(find "$interrupt_root/.ptc" -type f -name 'cmd-*.jsonl' -print -quit)"
fi

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

"$command_bin" repl --manifest "$application_root/ptc.json" --inspect-only -e '(+ 1 2)' \
  > "$release_tmp_dir/inspect-only.stdout"
printf '%s\n' '3' > "$release_tmp_dir/inspect-only.expected"
cmp "$release_tmp_dir/inspect-only.expected" "$release_tmp_dir/inspect-only.stdout"

# Inspect-only must compile a provider-backed application without a host or
# credentials. The provider fixture's credential is invalid on purpose.
"$command_bin" repl --manifest "$fixture_root/provider-application.json" \
  --inspect-only -e '(+ 1 2)' \
  > "$release_tmp_dir/inspect-only-provider.stdout"
cmp "$release_tmp_dir/inspect-only.expected" \
  "$release_tmp_dir/inspect-only-provider.stdout"

"$command_bin" materialize "$application_root/ptc.json" --workflow \
  --component smoke.main --source-out "$release_tmp_dir/smoke.main.clj" \
  > "$release_tmp_dir/source-out.stdout"
cmp "$application_root/main.clj" "$release_tmp_dir/smoke.main.clj"
grep -q 'source-out' "$release_tmp_dir/source-out.stdout"
"$release_root/bin/ptc_runner" eval '
  [path] = System.argv()
  {:ok, %File.Stat{mode: mode}} = File.stat(path)
  true = Bitwise.band(mode, 0o777) == 0o600
' "$release_tmp_dir/smoke.main.clj"

set +e
"$command_bin" materialize "$application_root/ptc.json" --workflow \
  --component smoke.main --source-out "$release_tmp_dir/smoke.main.clj" \
  > "$release_tmp_dir/source-out-exists.stdout" \
  2> "$release_tmp_dir/source-out-exists.stderr"
source_out_exists_status=$?
set -e
test "$source_out_exists_status" -eq 7
grep -q 'publication/source_out_destination_exists' \
  "$release_tmp_dir/source-out-exists.stderr"

"$command_bin" materialize "$application_root/ptc.json" --workflow \
  --component smoke.main --out "$release_tmp_dir/candidate" \
  --source "$application_root/main.clj" \
  > "$release_tmp_dir/candidate.stdout"
test -f "$release_tmp_dir/candidate/candidate.clj"
test -f "$release_tmp_dir/candidate/descriptor.json"
cmp "$application_root/main.clj" "$release_tmp_dir/candidate/candidate.clj"
grep -q 'candidate' "$release_tmp_dir/candidate.stdout"

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

# Exercise the gateway through the packaged command, rather than through a
# source-tree Mix task. This verifies the load-only companion boundary, health,
# an SSE write call, durable private audit, and clean signal-driven shutdown.
gateway_root="$release_tmp_dir/gateway"
gateway_app="$gateway_root/application"
gateway_audit="$gateway_root/audit"
mkdir -p "$gateway_app"

cat > "$gateway_app/main.clj" <<'EOF'
(ns gateway.main)
(defn run {:effect :write} [input] (return input))
EOF

cat > "$gateway_app/read.clj" <<'EOF'
(ns gateway.read)
(defn run {:effect :read} [input] (return input))
EOF

cat > "$gateway_app/schema.json" <<'EOF'
{"type":"object","properties":{"query":{"type":"string","x-mcp-header":"Query"}},"required":["query"],"additionalProperties":false}
EOF

cat > "$gateway_app/ptc.json" <<'EOF'
{
  "version": 1,
  "workflow": {
    "components": [{"id": "gateway.main", "path": "main.clj"}],
    "entry": "gateway.main/run"
  },
  "input": {"path": "missing.json"},
  "contracts": {
    "input_schema": {"path": "schema.json"},
    "result_schema": {"path": "schema.json"}
  }
}
EOF


cat > "$gateway_app/read-ptc.json" <<'EOF'
{
  "version": 1,
  "workflow": {
    "components": [{"id": "gateway.read", "path": "read.clj"}],
    "entry": "gateway.read/run"
  },
  "input": {"path": "missing.json"},
  "contracts": {
    "input_schema": {"path": "schema.json"},
    "result_schema": {"path": "schema.json"}
  }
}
EOF

cat > "$gateway_app/provider-main.clj" <<'EOF'
(ns gateway.provider-main "Provider-backed release probe." {:visibility :prompt})
(defn run {:effect :write} [input]
  (return (llm/request
            {"messages" [{"role" "user" "content" (get input "city")}]})))
EOF

cat > "$gateway_app/provider-schema.json" <<'EOF'
{"type":"object","properties":{"city":{"type":"string"},"delay_ms":{"type":"integer"}},"required":["city","delay_ms"],"additionalProperties":false}
EOF

cat > "$gateway_app/provider-result-schema.json" <<'EOF'
{"type":"object"}
EOF

cat > "$gateway_app/provider-ptc.json" <<'EOF'
{
  "version": 1,
  "workflow": {
    "components": [
      {"id": "gateway.provider-main", "path": "provider-main.clj", "dependencies": ["llm"]},
      {"library": "llm"}
    ],
    "entry": "gateway.provider-main/run"
  },
  "input": {"path": "missing.json"},
  "contracts": {
    "input_schema": {"path": "provider-schema.json"},
    "result_schema": {"path": "provider-result-schema.json"}
  },
  "providers": {"workflow": [{"name": "model"}]},
  "limits": {"run_duration_ms": 60000, "workflow_timeout_ms": 60000}
}
EOF

gateway_digest="$("$release_root/bin/ptc_runner" eval '
  [manifest] = System.argv()
  {:ok, template} =
    PtcRunner.Kernel.ServingTemplate.from_directory(
      manifest,
      PtcRunner.Kernel.Limits.installed_defaults()
    )
  IO.write(PtcRunner.Kernel.ServingTemplate.application_content_digest(template))
' "$gateway_app/ptc.json")"

gateway_read_digest="$("$release_root/bin/ptc_runner" eval '
  [manifest] = System.argv()
  {:ok, template} =
    PtcRunner.Kernel.ServingTemplate.from_directory(
      manifest,
      PtcRunner.Kernel.Limits.installed_defaults()
    )
  IO.write(PtcRunner.Kernel.ServingTemplate.application_content_digest(template))
' "$gateway_app/read-ptc.json")"

gateway_port="$(python3 - <<'PYTHON'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PYTHON
)"

gateway_provider_port=11434
cat > "$release_tmp_dir/mcp-provider.py" <<'PYTHON'
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers["content-length"]))
        time.sleep(30)
        response = json.dumps({"error": "probe should have been cancelled"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        try:
            self.wfile.write(response)
        except BrokenPipeError:
            pass

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PYTHON
python3 "$release_tmp_dir/mcp-provider.py" "$gateway_provider_port" \
  > "$release_tmp_dir/provider.stdout" 2> "$release_tmp_dir/provider.stderr" &
gateway_provider_pid=$!

cat > "$gateway_root/host.json" <<EOF
{
  "credentials": {
    "gateway": {"env": "GATEWAY_RELEASE_TOKEN"},
    "provider": {"env": "GATEWAY_PROVIDER_TOKEN"}
  },
  "install": {
    "model": {
      "source": "llm",
      "installation_revision": "release-provider-v1",
      "model": "ollama:release-provider",
      "credential": "provider",
      "structured_output_mode": "unsupported",
      "usage_guarantees": {"tokens": false, "cost_currency": null},
      "params": {"max_tokens": 64}
    }
  }
}
EOF

cat > "$gateway_root/credentials.env" <<'EOF'
GATEWAY_RELEASE_TOKEN=release-gateway-token-0123456789abcdef
GATEWAY_PROVIDER_TOKEN=release-provider-token
EOF


gateway_provider_digest="$("$release_root/bin/ptc_runner" eval '
  [manifest, host_path] = System.argv()
  {:ok, host} = PtcRunner.Kernel.HostConfig.load(host_path)
  {:ok, catalog} = PtcRunner.Kernel.HostInstallation.catalog(host)
  {:ok, template} =
    PtcRunner.Kernel.ServingTemplate.from_directory(
      manifest,
      host.limits,
      providers: catalog
    )
  IO.write(PtcRunner.Kernel.ServingTemplate.application_content_digest(template))
' "$gateway_app/provider-ptc.json" "$gateway_root/host.json")"

mix run -e '
  [manifest, host, env_file, output] = System.argv()
  {:ok, io} = File.open(output, [:write])
  Process.group_leader(self(), io)
  Mix.Tasks.Ptc.ProviderPins.run([manifest, "--host", host, "--env-file", env_file])
  File.close(io)
' -- "$gateway_app/provider-ptc.json" "$gateway_root/host.json" \
  "$gateway_root/credentials.env" "$release_tmp_dir/provider-pins.json"
gateway_installation_pins="$(python3 -c \
  'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["installation_config_pins"],separators=(",",":")))' \
  "$release_tmp_dir/provider-pins.json")"
gateway_snapshot_pins="$(python3 -c \
  'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["provider_snapshot_pins"],separators=(",",":")))' \
  "$release_tmp_dir/provider-pins.json")"

cat > "$gateway_root/gateway.json" <<EOF
{
  "version": 1,
  "listen": {"address": "127.0.0.1", "port": $gateway_port, "path": "/mcp"},
  "authentication": {"bearer": {"binding": "gateway"}},
  "host": {"path": "host.json"},
  "admission": {
    "max_inflight_requests": 2,
    "max_concurrent_runs": 1,
    "max_active_provider_calls": 1,
    "max_waiting_provider_calls": 0
  },
  "private_audit": {
    "directory": "audit",
    "max_file_bytes": 4096,
    "max_retained_files": 2
  },
  "tools": [{
    "name": "a",
    "title": "Read",
    "description": "Packaged read probe",
    "application": {"manifest": "application/read-ptc.json"},
    "expected_application_content_digest": "$gateway_read_digest",
    "installation_config_pins": {},
    "provider_snapshot_pins": {},
    "allow_write": false
  }, {
    "name": "write",
    "title": "Write",
    "description": "Packaged write probe",
    "application": {"manifest": "application/ptc.json"},
    "expected_application_content_digest": "$gateway_digest",
    "installation_config_pins": {},
    "provider_snapshot_pins": {},
    "allow_write": true
  }, {
    "name": "provider-write",
    "title": "Provider write",
    "description": "Packaged provider cancellation probe",
    "application": {"manifest": "application/provider-ptc.json"},
    "expected_application_content_digest": "$gateway_provider_digest",
    "installation_config_pins": $gateway_installation_pins,
    "provider_snapshot_pins": $gateway_snapshot_pins,
    "allow_write": true
  }]
}
EOF

"$command_bin" gateway "$gateway_root/gateway.json" \
  --env-file "$gateway_root/credentials.env" \
  > "$release_tmp_dir/gateway.stdout" \
  2> "$release_tmp_dir/gateway.stderr" &
gateway_pid=$!

python3 - "$gateway_port" <<'PYTHON'
import http.client
import json
import sys
import time

port = int(sys.argv[1])
deadline = time.monotonic() + 30
while True:
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
        conn.request("GET", "/health/ready", headers={"Host": f"127.0.0.1:{port}"})
        response = conn.getresponse()
        if response.status == 200:
            response.read()
            break
        response.read()
    except OSError:
        pass
    if time.monotonic() >= deadline:
        raise SystemExit("packaged gateway never became ready")
    time.sleep(0.1)

body = json.dumps({
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
        "_meta": {
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": {},
        },
        "name": "write",
        "arguments": {"query": "write"},
    },
}, separators=(",", ":"))
conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
conn.request("POST", "/mcp", body=body, headers={
    "Host": f"127.0.0.1:{port}",
    "Authorization": "Bearer release-gateway-token-0123456789abcdef",
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
    "MCP-Protocol-Version": "2026-07-28",
    "Mcp-Method": "tools/call",
    "Mcp-Name": "write",
    "Mcp-Param-Query": "write",
})
response = conn.getresponse()
payload = response.read().decode()
if response.status != 200 or '"isError":false' not in payload:
    raise SystemExit(f"packaged gateway write failed: {response.status} {payload}")
PYTHON

# The pinned real MCP client must exercise the assembled release, not only the
# source test server. It covers discover, list, read, write, and contract error
# through the SDK's negotiated 2026-07-28 transport.
npm --prefix "$project_root/ptc_gateway/test/support/mcp_conformance" \
  ci --ignore-scripts --silent
node "$project_root/ptc_gateway/test/support/mcp_conformance/client_journey.mjs" \
  "http://127.0.0.1:$gateway_port/mcp" \
  release-gateway-token-0123456789abcdef \
  > "$release_tmp_dir/gateway-client.json"
python3 - "$release_tmp_dir/gateway-client.json" <<'PYTHON'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    journey = json.load(stream)

if journey["read"].get("isError") or journey["write"].get("isError"):
    raise SystemExit("packaged MCP client read/write journey failed")
if not journey["contractFailure"].get("isError"):
    raise SystemExit("packaged MCP client contract failure was not a tool error")
PYTHON

# Hold a real upstream MCP provider call in the assembled release, prove the
# atomic run slot remains occupied, then disconnect the client and wait for the
# durable write audit before continuing.
python3 - "$gateway_port" "$gateway_audit" <<'PYTHON'
import glob
import http.client
import json
import socket
import sys
import time

port = int(sys.argv[1])
audit_dir = sys.argv[2]
body = json.dumps({
    "jsonrpc": "2.0", "id": 91, "method": "tools/call",
    "params": {
        "_meta": {
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": {},
        },
        "name": "provider-write",
        "arguments": {"city": "nyc", "delay_ms": 30000},
    },
}, separators=(",", ":")).encode()
request = (
    f"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
    "Authorization: Bearer release-gateway-token-0123456789abcdef\r\n"
    "Content-Type: application/json\r\nAccept: application/json, text/event-stream\r\n"
    "MCP-Protocol-Version: 2026-07-28\r\nMcp-Method: tools/call\r\n"
    "Mcp-Name: provider-write\r\n"
    f"Content-Length: {len(body)}\r\n\r\n"
).encode() + body

client = socket.create_connection(("127.0.0.1", port), timeout=5)
client.sendall(request)
accepted = b""
while b": accepted" not in accepted and len(accepted) < 16384:
    accepted += client.recv(4096)
if b"HTTP/1.1 200" not in accepted or b": accepted" not in accepted:
    raise SystemExit(f"provider call was not committed before dispatch: {accepted!r}")

busy = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
busy.request("POST", "/mcp", body=body, headers={
    "Host": f"127.0.0.1:{port}",
    "Authorization": "Bearer release-gateway-token-0123456789abcdef",
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
    "MCP-Protocol-Version": "2026-07-28",
    "Mcp-Method": "tools/call",
    "Mcp-Name": "provider-write",
})
response = busy.getresponse()
response.read()
if response.status != 429:
    raise SystemExit(f"provider call released admission early: {response.status}")
client.close()

deadline = time.monotonic() + 15
while time.monotonic() < deadline:
    records = []
    for path in glob.glob(audit_dir + "/*.jsonl"):
        with open(path, encoding="utf-8") as stream:
            records.extend(json.loads(line) for line in stream if line.strip())
    if any(r["tool_name"] == "provider-write" and r["disconnected"] for r in records):
        break
    time.sleep(0.1)
else:
    raise SystemExit("disconnected packaged provider write was not audited")
PYTHON

grep -q '"tool_name":"write"' "$gateway_audit"/*.jsonl

# Start another held provider call, then terminate the packaged gateway while
# it is active. The gateway must drain, cancel, audit, clean provider/admission
# owners, and preserve the resulting clean exit status.
shutdown_ready="$release_tmp_dir/gateway-shutdown-ready"
python3 - "$gateway_port" "$shutdown_ready" <<'PYTHON' &
import json
import socket
import sys

port = int(sys.argv[1])
ready = sys.argv[2]
body = json.dumps({
    "jsonrpc": "2.0", "id": 92, "method": "tools/call",
    "params": {
        "_meta": {
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": {},
        },
        "name": "provider-write",
        "arguments": {"city": "nyc", "delay_ms": 30000},
    },
}, separators=(",", ":")).encode()
request = (
    f"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
    "Authorization: Bearer release-gateway-token-0123456789abcdef\r\n"
    "Content-Type: application/json\r\nAccept: application/json, text/event-stream\r\n"
    "MCP-Protocol-Version: 2026-07-28\r\nMcp-Method: tools/call\r\n"
    "Mcp-Name: provider-write\r\n"
    f"Content-Length: {len(body)}\r\n\r\n"
).encode() + body
client = socket.create_connection(("127.0.0.1", port), timeout=5)
client.sendall(request)
accepted = b""
while b": accepted" not in accepted and len(accepted) < 16384:
    accepted += client.recv(4096)
if b": accepted" not in accepted:
    raise SystemExit("shutdown provider call was not active")
open(ready, "w", encoding="utf-8").close()
while client.recv(4096):
    pass
PYTHON
shutdown_client_pid=$!
shutdown_deadline=$((SECONDS + 15))
while [ ! -e "$shutdown_ready" ] && [ "$SECONDS" -lt "$shutdown_deadline" ]; do
  kill -0 "$shutdown_client_pid" 2> /dev/null || break
  sleep 0.1
done
test -e "$shutdown_ready"
kill -TERM "$gateway_pid"
set +e
wait "$gateway_pid"
gateway_status=$?
wait "$shutdown_client_pid"
shutdown_client_status=$?
set -e
gateway_pid=""
if [ "$gateway_status" -ne 0 ]; then
  echo "packaged gateway exited with status $gateway_status" >&2
  cat "$release_tmp_dir/gateway.stderr" >&2
  exit 1
fi
test "$shutdown_client_status" -eq 0
grep -q '"tool_name":"provider-write"' "$gateway_audit"/*.jsonl
test ! -s "$release_tmp_dir/gateway.stdout"

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
# so this signals the VM itself. The standalone entry point restores the OS
# default disposition, and the shell reports 128 plus SIGTERM's number.
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
test "$viewer_status" -eq 143

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
