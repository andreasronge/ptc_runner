#!/bin/zsh
# usage: ENV_FILE=/path/.env run.sh EXAMPLE_DIR OUT_DIR VARIANT [SAMPLES] [PARALLEL]
# Generates the six cells of one prompt variant and runs them, PARALLEL (default 6) cells at a time.
set -e
E=${1:?example dir}; O=${2:?out dir}; V=${3:?variant}; n=${4:-3}; par=${5:-6}
L=${0:A:h}
: ${ENV_FILE:?set ENV_FILE to the environment file holding OPENROUTER_API_KEY}
mkdir -p "$O"
"$L/gen-cells.sh" "$E" "$V" | sort -t- -k4,4r | xargs -P "$par" -n 1 -I{} env ENV_FILE="$ENV_FILE" "$L/run-cell.sh" "$E" "$O" {} "$n"
sort "$O/log.txt"
