#!/bin/zsh
# Deterministic check of the two terminal actions against the pricing capture; no model call.
# usage: probe.sh EXAMPLE_DIR   (a materialized debug-a-failed-run tree whose target has been run)
set -e
E=${1:?example dir}
L=${0:A:h}
RID=$(ls -tr "$E"/target/.ptc/traces/*.jsonl | head -1 | sed -E 's|.*/(cmd-[a-z0-9]+)\..*|\1|')
rm -rf "$E/nb3-probe"; mkdir -p "$E/nb3-probe"
cp "$L/debug.terminal.clj" "$L/probe/main.clj" "$L/probe/ptc.json" "$E/nb3-probe/"
cat > "$E/nb3-probe.ptc-project.json" <<JSON
{"kind": "ptc-project", "version": 1, "application": {"path": "nb3-probe/ptc.json"}, "host": {"path": "ptc-host.json"}, "artifacts": {"root": "nb3-probe/.ptc", "trace": true, "inspection": true, "result": true, "envelope": true}}
JSON
for c in diag-ok diag-badhash diag-badexcerpt abs-refuted-cid abs-refuted-env abs-ok; do
  sed "s/__RUN_ID__/$RID/g" "$L/probe/inputs/$c.json" > "$E/nb3-probe/$c.json"
  rm -rf "$E/nb3-probe/.ptc"
  printf '%-18s ' "$c"
  ptc run "$E/nb3-probe.ptc-project.json" --input "$c.json" >/dev/null 2>&1 || true
  cat "$E"/nb3-probe/.ptc/results/*.private.json 2>/dev/null | grep -o '"outcome":"[a-z_]*"\|"reason":"[^"]*"\|"decision":"[^"]*"' | tr '\n' ' '; echo
done
