#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

# StreamData increases its property run count under CI. Establish that part of
# the test contract here without changing the environment of non-test gates
# such as Dialyzer, whose local PLT cache selection depends on CI being unset.
export CI=1

usage() {
  echo "usage: core-tests.sh [--schedulers POSITIVE_INTEGER]" >&2
  exit 64
}

case "$#" in
  0)
    ;;

  2)
    if [ "$1" != "--schedulers" ] || ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
      usage
    fi
    export ERL_FLAGS="+S $2:$2"
    ;;

  *)
    usage
    ;;
esac

# `PTC_TEST_LANE=library` leaves out the `:operator` modules: the tests that
# drive the repository through its Mix tasks, git hooks, scripts, Viewer,
# guides, and examples. The pre-push hook selects that lane when a push
# touches none of those surfaces; CI and a bare invocation run everything.
lane_args=()
if [ "${PTC_TEST_LANE:-}" = library ]; then
  lane_args=(--exclude operator)
fi

mix compile --warnings-as-errors
mix test --max-failures 1 --warnings-as-errors ${lane_args[@]+"${lane_args[@]}"}
