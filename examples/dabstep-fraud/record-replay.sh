#!/bin/sh
# Write an llm_replay fixture from the model exchanges one or more runs recorded.
#
#   ./record-replay.sh ARTIFACT_ROOT RUN_REF [RUN_REF ...] > fixture.jsonl
#
# Reads the private inspection record through the analysis profile, so it
# needs the same authority as `ptc transcript`. One line per distinct request
# hash; a hash a run requested more than once gets an ordered `responses`
# array. Response usage and model labels are dropped because the fixture
# replays content, not cost.
set -eu
root=$(cd "$1" && pwd)
shift
[ "$#" -ge 1 ] || { echo "usage: $0 ARTIFACT_ROOT RUN_REF [RUN_REF ...]" >&2; exit 2; }
for run in "$@"; do
  case $run in
    cmd-[a-z0-9]*) expr "$run" : 'cmd-[a-z0-9]*$' >/dev/null || { echo "not a run reference: $run" >&2; exit 2; } ;;
    *) echo "not a run reference: $run" >&2; exit 2 ;;
  esac
done
# `--private-output` publishes exactly one evaluation and refuses a path inside
# the directory holding its own session trace (the system temp directory).
# `--run` keeps the profile from loading every run in the directory, which
# otherwise exceeds its retained-source limit once the directory fills up.
stage=$(mktemp -d "$PWD/.record-replay.XXXXXX")
trap 'rm -rf "$stage"' EXIT
out=$stage/value.json
runs=$(printf '"%s" ' "$@")
select=$(printf -- '--run %s ' "$@")
${PTC:-ptc} repl --profile private-run-analysis-v2 --private-unattended \
  --resource "traces=$root/traces" --resource "inspection=$root/inspection" \
  --format jsonl --private-output "$out" $select \
  -e "(let [exchanges
           (fn [run]
             (loop [cursor nil acc []]
               (let [page (analysis/read run (if cursor
                                               {\"collection\" \"model_exchanges\" \"cursor\" cursor}
                                               {\"collection\" \"model_exchanges\"}))
                     acc (into acc (get page \"items\"))]
                 (if (get page \"next_cursor\") (recur (get page \"next_cursor\") acc) acc))))
           response
           (fn [item]
             (if (and (get item \"complete?\") (= \"ok\" (get-in item [\"result\" \"status\"])))
               (dissoc (get-in item [\"result\" \"value\"]) \"tokens\" \"model\")
               (fail {:status :error :kind :incomplete-exchange :sequence (get item \"input_sequence\")})))
           grouped
           (reduce (fn [m item]
                     (update m (get item \"request_hash\") (fn [vs] (conj (or vs []) (response item)))))
                   {}
                   (mapcat exchanges [$runs]))]
       (mapv (fn [[h vs]]
               (if (= 1 (count vs))
                 {\"schema_version\" 1 \"request_hash\" h \"response\" (first vs)}
                 {\"schema_version\" 1 \"request_hash\" h \"responses\" vs}))
             grouped))" >/dev/null
python3 -c 'import json,sys; [print(json.dumps(l, separators=(",", ":"))) for l in json.load(open(sys.argv[1]))]' "$out"
