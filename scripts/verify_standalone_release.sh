#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ptc-runner-standalone-release.XXXXXX")"

cleanup() {
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
"$release_root/bin/ptc_runner" eval '
  true = PtcRunner.Kernel.SemanticRevision.runtime_dependency_artifacts_verified?()
'

"$command_bin" --version > "$release_tmp_dir/version.stdout"
grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' "$release_tmp_dir/version.stdout"

"$command_bin" help > "$release_tmp_dir/help.stdout"
grep -q '^Usage:$' "$release_tmp_dir/help.stdout"
grep -Fqx '  --help    — show root help' "$release_tmp_dir/help.stdout"
for command in init validate run doctor models repl; do
  grep -q "ptc $command" "$release_tmp_dir/help.stdout"
  "$command_bin" help "$command" > "$release_tmp_dir/help-$command.stdout"
done

"$command_bin" init "$fixture_root/initialized" > "$release_tmp_dir/init.stdout"
test -f "$fixture_root/initialized/ptc.json"
grep -qx 'created .gitignore, main.clj, ptc.json, ptc-project.json' "$release_tmp_dir/init.stdout"

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
test "$existing_envelope_status" -eq 74
printf '%s\n' 'original' > "$release_tmp_dir/existing-envelope.expected"
cmp "$release_tmp_dir/existing-envelope.expected" "$existing_envelope"
grep -q 'envelope/publication_failed' "$release_tmp_dir/existing-envelope.stderr"

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
# knowingly cannot provide a terminal; the workflow installs `expect` instead
# of setting it.
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
