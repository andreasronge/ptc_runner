#!/bin/zsh
# usage: gen-cells.sh EXAMPLE_DIR VARIANT
#   EXAMPLE_DIR: a materialized debug-a-failed-run tree whose three targets have been run (their .ptc captures exist)
#   VARIANT:     p1 = the shipped debugger-agent task (prescribed traversal order)
#                p2 = vocabulary only, no order
#                p3 = verdict definitions, decision-based stopping rule, both environments, and the
#                     debug.terminal diagnose/abstain actions selected into the evidence mission
# Writes nb-<target>-<variant>-<model>/ptc.json, the matching .ptc-project.json, and nb-host-<target>-<model>.json,
# for targets t (target), amb (target-ambiguous), wc (target-workflow-control) and models ds, luna.
set -e
E=${1:?example dir}; V=${2:?variant p1|p2|p3}
L=${0:A:h}
P1=$(grep -o '"task": "[^"]*\(\\"[^"]*\)*"' "$E/debugger-agent/ptc.json" | sed 's/^"task": //')
P2='"A captured run failed. Determine why it did not produce the value it was required to produce, using only evidence you actually read.\nThe evidence mission exposes debug.nav: runs lists captured runs; open lists one run'"'"'s collections and the filters each accepts; read returns one page of a collection; follow walks a typed relationship carried by an item. Collections include execution_errors, generated_sources, prelude_sources, capability_calls, activity and turns. Items carry relationships such as child_evaluations, generated_source, referenced_prelude_source and dependency_prelude_source. Decide for yourself which evidence to read and in which order. Follow a relationship object exactly as you received it, and only when its state is \"complete\". Do not invent filters.\nWhen the evidence you have read either identifies one responsible component or shows that no single component can be distinguished, make the very next program your final report. Do not gather more evidence after that point.\nThe report is an object with exactly these fields: \"decision\", \"cause\" (a string), \"evidence\" (an array of strings), and \"component_id\" only when you name one. Use decision \"diagnosed\" with the responsible component_id only when the source you read identifies one; otherwise use decision \"insufficient-evidence\" and let \"cause\" name what is missing."'
P3='"A captured run failed. Determine why it did not produce the value it was required to produce, using only evidence you actually read.\nEvidence tools: debug.nav/runs lists captured runs; debug.nav/open lists one run'"'"'s collections and the filters each accepts; debug.nav/read returns one page of a collection; debug.nav/follow walks a typed relationship carried by an item. Collections include execution_errors, explicit_failure_values, generated_sources, prelude_sources, capability_calls, activity and turns; relationships include child_evaluations, generated_source, referenced_prelude_source and dependency_prelude_source. Generated programs are authored by the workflow environment: the workflow'"'"'s own source is a prelude_sources item with environment \"workflow\", and mission sources have environment \"mission\". Follow a relationship object exactly as you received it, and only when its state is \"complete\". Do not invent filters.\nVerdicts: diagnosed means exactly one source you read is inconsistent with its own docstring or signature, or with the values the failing program required, and no other read source could absorb the discrepancy. If two or more read sources could each absorb it, the verdict is insufficient-evidence. Explaining how the failure happened is not a diagnosis.\nStop when you can either name that one source, or state which unread evidence would decide the question. Before abstaining, check whether the source that authored the failing call is in the capture.\nFinish through exactly one top-level call. Either (debug.terminal/diagnose {\"run_id\" .. \"component_id\" .. \"source_hash\" .. \"excerpt\" .. \"cause\" .. \"evidence\" [..]}), where source_hash is the sha256 of the frozen source item you read and excerpt is a verbatim fragment of it that shows the defect; or (debug.terminal/abstain {\"run_id\" .. \"cause\" .. \"evidence\" [..] \"missing\" [{\"component_id\" ..} {\"environment\" ..} {\"description\" ..}]}) naming what would decide the question. A refused action returns a map with \"refused\" true and the reason; correct the report and call again. The action completes the run itself; do not wrap it in return."'
typeset -A MODELS
MODELS[ds]="openrouter:deepseek/deepseek-v4-flash"
MODELS[luna]="openrouter:openai/gpt-5.6-luna"
typeset -A TARGETS
TARGETS[t]="target"
TARGETS[amb]="target-ambiguous"
TARGETS[wc]="target-workflow-control"
case $V in p1) TASK=$P1;; p2) TASK=$P2;; p3) TASK=$P3;; *) echo "unknown variant $V"; exit 2;; esac
port=4200
for tk in t amb wc; do
  T=${TARGETS[$tk]}
  for mk in ds luna; do
    M=${MODELS[$mk]}
    cat > "$E/nb-host-$tk-$mk.json" <<EOF
{
  "credentials": {"openrouter_key": {"env": "OPENROUTER_API_KEY"}},
  "install": {
    "failed-run-traces": {"source": "ptc_private_trace_snapshot", "installation_revision": "nb-traces-$tk-v1", "directory": "$T/.ptc/traces"},
    "debug.nav": {"source": "ptc_inspection_snapshot", "installation_revision": "nb-inspection-$tk-v1", "directory": "$T/.ptc/inspection"},
    "model": {
      "source": "llm",
      "structured_output_mode": "unsupported",
      "usage_guarantees": {"tokens": true, "cost_currency": "USD"},
      "installation_revision": "nb-model-$mk-v1",
      "model": "$M",
      "credential": "openrouter_key",
      "cache": false,
      "params": {"temperature": 0, "max_tokens": 8192},
      "accepts_data": ["normal", "private_inspection"]
    }
  },
  "limits": {"run_duration_ms": 600000, "workflow_timeout_ms": 540000, "evaluation_timeout_ms": 480000, "normal_event_count": 4096, "normal_event_bytes": 64000000}
}
EOF
    cell="nb-$tk-$V-$mk"
    mkdir -p "$E/$cell"
    if [ "$V" = p3 ]; then
      cp "$L/report.schema.json" "$L/debug.terminal.clj" "$E/$cell/"
      COMPONENTS='[{"id": "debug.terminal", "path": "debug.terminal.clj", "dependencies": ["debug.nav"]}, {"library": "debug.nav"}]'
      AGENT='{"max_turns": 30, "mission": "evidence", "consolidate_at_turns_remaining": 6}'
    else
      cp "$E/debugger-agent/report.schema.json" "$E/$cell/"
      COMPONENTS='[{"library": "debug.nav"}]'
      AGENT='{"max_turns": 30, "mission": "evidence"}'
    fi
    cat > "$E/$cell/ptc.json" <<EOF
{
  "version": 1,
  "workflow": {"components": [{"library": "agent.main"}], "entry": "agent.main/run"},
  "missions": {"evidence": {"components": $COMPONENTS, "providers": ["debug.nav", "failed-run-traces"]}},
  "contracts": {"result_schema": {"path": "report.schema.json"}},
  "input": {"value": {"task": $TASK, "agent": $AGENT}},
  "providers": {"workflow": [{"name": "model"}], "mission": [{"name": "debug.nav"}, {"name": "failed-run-traces", "config": {"expose": false}}]},
  "limits": {"run_duration_ms": 600000, "workflow_timeout_ms": 540000, "evaluation_timeout_ms": 480000, "normal_event_count": 4096, "normal_event_bytes": 64000000},
  "events": {"policy": "private"},
  "labels": {"name": "nav-bench-$tk-$V-$mk", "tags": {"mode": "agent"}}
}
EOF
    port=$((port+1))
    cat > "$E/$cell.ptc-project.json" <<EOF
{"kind": "ptc-project", "version": 1, "application": {"path": "$cell/ptc.json"}, "host": {"path": "nb-host-$tk-$mk.json"}, "artifacts": {"root": "$cell/.ptc", "trace": true, "inspection": true, "result": true, "envelope": true}, "viewer": {"port": $port, "open": false, "repl": true, "private": true}}
EOF
    ptc validate "$E/$cell.ptc-project.json" >/dev/null
    echo "$cell"
  done
done
