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

mix compile --warnings-as-errors
mix test --max-failures 1 --warnings-as-errors
