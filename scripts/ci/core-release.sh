#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

scripts/verify_core_package.sh
# Own the assembled executable here so the checkout-only example can share it
# without adding Node or example files to the in-image standalone verifier.
gateway_release_dir="$(mktemp -d "${TMPDIR:-/tmp}/ptc-core-release.XXXXXX")"
trap 'rm -rf "$gateway_release_dir"' EXIT
MIX_ENV=prod mix release ptc_runner --overwrite --path "$gateway_release_dir/release"

# The interactive PTY REPL needs expect(1) and a real terminal. Timed
# keystrokes make it slow and load-sensitive, and GitHub's Ubuntu image does
# not ship expect -- installing it on the PR job hung apt-get long enough to
# cancel the 20-minute gate. Nightly, Docker verify, and the packaging script
# run the check without this skip.
PTC_RELEASE_ROOT="$gateway_release_dir/release" PTC_SKIP_PTY_GATE=1 \
  scripts/verify_standalone_release.sh
python3 scripts/verify_gateway_example.py "$gateway_release_dir/release/bin/ptc"
