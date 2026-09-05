#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

python3 "$ci_repo_root/scripts/project-plt-cache.py" restore
mix dialyzer --format github
python3 "$ci_repo_root/scripts/project-plt-cache.py" publish
