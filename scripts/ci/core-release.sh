#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

scripts/verify_core_package.sh
# The interactive PTY REPL needs expect(1) and a real terminal. Timed
# keystrokes make it slow and load-sensitive, and GitHub's Ubuntu image does
# not ship expect -- installing it on the PR job hung apt-get long enough to
# cancel the 20-minute gate. Nightly, Docker verify, and the packaging script
# run the check without this skip.
PTC_SKIP_PTY_GATE=1 scripts/verify_standalone_release.sh
