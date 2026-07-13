# PTC Kernel tutorial: bounded Lisp workflows and model-written programs

This tutorial builds three workflows from the command line. The first is
fully deterministic, the second calls DeepSeek as a bounded capability, and
the third lets DeepSeek write a small PTC-Lisp mission program that can read
one explicitly granted directory.

You do not need to write Elixir for the main tutorial. You need a PtcRunner
checkout, Elixir/Mix to run its command-line tasks, basic Clojure syntax, and
an OpenRouter key for the two live-model examples. The final section shows the
equivalent Elixir embedding boundary for host-application authors.

The complete files are under
[`examples/kernel-tutorial/`](https://github.com/andreasronge/ptc_runner/tree/main/examples/kernel-tutorial/).
All commands below run from the repository root.

## The mental model

A run has two deliberately different Lisp environments:

| Environment | Usually authored by | Typical authority | Trust level |
| --- | --- | --- | --- |
| Workflow | Human/developer | LLM calls, orchestration, annotations, subordinate evaluation | Trusted application policy |
| Mission | Human or model | Narrow task capabilities such as reading one granted directory | Confined task execution |

The host loads a strict JSON manifest, compiles immutable component bundles,
grants named capabilities, and starts one bounded run. Workflow Lisp can ask
the reserved `kernel-eval` boundary to evaluate a static `program` or dynamic
source in the mission environment. Mission Lisp never inherits workflow LLM
authority and cannot recursively call `kernel-eval`.

The resulting flow is:

```text
human manifest + workflow Lisp
             |
             v
      bounded workflow  ---- llm-request ----> DeepSeek
             |
             | model-produced PTC-Lisp source
             v
      bounded mission   ---- fs-read --------> granted directory only
             |
             v
 public result/error + usage + canonical events
```

The important PTC-Lisp additions for a Clojure user are:

- `(return value)` marks an intentional successful result;
- `(fail value)` marks an intentional workflow failure;
- `data/input` is the manifest input object at the generated entry boundary;
- `(tool/name {...})` invokes only a capability granted to the current
  environment and returns a uniform status envelope;
- `(program ...)` captures opaque static subordinate source; it is not general
  `eval` and does not capture workflow locals.

Use string keys at JSON boundaries. Keywords are convenient for internal
status values such as `:ok` and `:returned`.

## Setup

Fetch dependencies and verify the direct REPL:

```bash
mix deps.get
mix ptc.repl -e '(mapv #(* % %) [1 2 3 4])'
```

The REPL prints the Clojure-style value:

```clojure
[1 4 9 16]
```

Definitions and up to three successful results persist within one invocation:

```bash
mix ptc.repl \
  -e '(def tax-rate 0.2)' \
  -e '(* 100 tax-rate)' \
  -e '(+ *1 5)'
```

Output:

```text
#'tax-rate
20.0
25.0
```

A human syntax or runtime mistake gets bounded evaluator feedback, not a BEAM
stack trace. In interactive mode the session stays open; in `-e` or script
mode the task exits non-zero:

```text
Error (<reason>): <bounded evaluator message>
```

Use `:doc mapv`, `:find json`, and `:help` in the interactive REPL. The full
language surface is in the [PTC-Lisp specification](../ptc-lisp-specification.md)
and [function reference](../function-reference.md).

For DeepSeek, copy the environment template and set an OpenRouter key:

```bash
cp .env.example .env
# Edit .env and replace the OPENROUTER_API_KEY placeholder.
```

The examples use the repository alias `deepseek`. Model aliases are resolved
by the trusted host registry, not by Lisp or the manifest. To verify the live
boundary independently:

```bash
PTC_TEST_MODEL=deepseek \
  mix test test/ptc_runner/kernel/deepseek_e2e_test.exs --include e2e
```

## Anatomy of a manifest

This is the smallest useful shape:

```json
{
  "version": 1,
  "workflow": {
    "components": [
      {"id": "my.workflow", "path": "workflow.lisp"}
    ],
    "entry": "my.workflow/run"
  },
  "input": {"value": {"question": "What should I process?"}}
}
```

The generated entry expression is `(my.workflow/run data/input)`. The entry
must therefore be a qualified public function taking the input object:

```clojure
(ns my.workflow)

(defn run [input]
  (return {"received" (get input "question")}))
```

Manifest paths are relative to the manifest. A component may call exports from
another component only when its manifest entry lists the dependency:

```json
{
  "id": "my.workflow",
  "path": "workflow.lisp",
  "dependencies": ["my.helpers"]
}
```

Dependency IDs must be sorted and unique. Unknown manifest keys, duplicate
JSON keys, undeclared component calls, missing capabilities, unsafe paths, and
limit values above the host ceiling are rejected before execution.

## Use case 1: deterministic data transformation

The human creates
[`orders.lisp`](https://github.com/andreasronge/ptc_runner/blob/main/examples/kernel-tutorial/01-orders/orders.lisp), a normal
Clojure-style aggregation:

```clojure
(ns tutorial.orders)

(defn summarize [input]
  (let [orders (get input "orders")
        paid (filter #(= "paid" (get % "status")) orders)]
    (return
      {"order_count" (count orders)
       "paid_count" (count paid)
       "paid_total" (reduce + 0 (map #(get % "total") paid))
       "pending_ids" (mapv #(get % "id")
                           (filter #(= "pending" (get % "status")) orders))})))
```

The manifest uses a JSON file as input. Run it with:

```bash
mix ptc.run examples/kernel-tutorial/01-orders/ptc.json
```

The human receives one JSON object on standard output. The exact value from
the checked-in fixture is:

```json
{
  "value": {
    "order_count": 3,
    "paid_count": 2,
    "paid_total": 335.75,
    "pending_ids": ["A-101"]
  },
  "usage": {
    "protocol_errors": 0,
    "subordinate_evaluations": 0,
    "capability_calls": {"mission": {}, "workflow": {}},
    "events_dropped": {}
  },
  "evaluation_memory": {"bytes": 24, "defined_count": 0}
}
```

The real output also contains changing state such as `remaining_ms`. Pipe the
result through `jq '.value'` when a shell pipeline needs only the business
value.

Use `--mission` to replace the input file without editing the versioned
manifest. Despite the historical option name, this overrides the top-level
input object; the path remains confined relative to the manifest directory:

```bash
mix ptc.run examples/kernel-tutorial/01-orders/ptc.json \
  --mission another-orders.json
```

This pattern fits deterministic ETL, policy checks, scoring, normalization,
and post-processing where an LLM would add cost and uncertainty.

## Use case 2: DeepSeek as one bounded capability

In
[`extract.lisp`](https://github.com/andreasronge/ptc_runner/blob/main/examples/kernel-tutorial/02-deepseek-extract/extract.lisp),
the human creates the request and owns its output policy. The manifest grants
the workflow one provider named `llm` configured with the `deepseek` alias:

```json
"providers": {
  "workflow": [
    {"name": "llm", "config": {"model": "deepseek", "cache": false}}
  ]
}
```

The Lisp call crosses the provider-neutral boundary:

```clojure
(tool/llm-request
  {"system" "Extract project metadata as one compact JSON object."
   "messages" [{"role" "user" "content" text}]})
```

Raw tools return an envelope. On success it resembles:

```clojure
{:status :ok
 :value {"content" "{\"project\":\"Atlas\",...}" ...}}
```

Provider failures, timeouts, denied calls, invalid arguments, and quota
exhaustion also return bounded error envelopes. The example explicitly turns
a provider error into `(fail ...)` instead of accidentally treating it as
model content.

Run the example:

```bash
mix ptc.run examples/kernel-tutorial/02-deepseek-extract/ptc.json
```

One live DeepSeek run produced:

```json
{
  "value": {
    "model_output": "{\"project\":\"Atlas\",\"owner\":\"Priya\",\"risk\":\"delayed vendor security approval\"}",
    "note": "model_output is model text; validate or parse it before production use"
  },
  "usage": {
    "capability_calls": {
      "mission": {},
      "workflow": {"llm-request": 1}
    }
  }
}
```

The returned `content` is still untrusted model text. A production workflow
should parse it with `json/parse-string`, validate required keys and value
types, and send correction feedback or fail when it does not match the
contract.

This pattern fits classification, extraction, rewriting, and judgment calls
where the model returns data but does not author executable mission logic.

## Use case 3: DeepSeek writes a confined mission program

The file-agent example separates orchestration from task authority:

- the human-authored workflow may call DeepSeek and `kernel-eval`;
- the model receives one `run_ptc_lisp` tool schema and creates a program;
- that program executes in the mission environment;
- only the mission environment has `file-read`, rooted at
  `examples/kernel-tutorial/03-file-agent/files/`;
- the model cannot call the workflow's LLM capability or escape the file root.

The human creates the mission helper:

```clojure
(ns tutorial.files)

(defn read-text [path]
  (let [response (tool/fs-read {"path" path})]
    (if (= :ok (get response :status))
      (get-in response [:value "content"])
      response)))
```

The human also creates the workflow protocol and feedback policy in
[`agent.lisp`](https://github.com/andreasronge/ptc_runner/blob/main/examples/kernel-tutorial/03-file-agent/agent.lisp). The
important loop is:

```clojure
(loop [turn 0
       messages [{"role" "user" "content" task}]]
  (let [action (normalize-action (request-model messages))]
    (case (get action :kind)
      :program
      ;; Call the reserved boundary with dynamic model source.
      (tool/kernel-eval {"kind" :source "source" (get action :program)})

      :protocol-error
      ;; Add bounded correction feedback and ask again.
      (recur (inc turn)
             (conj messages {"role" "user" "content" correction})))))
```

The model can receive these exact corrections:

```text
Protocol error: <reason>. Call run_ptc_lisp exactly once with one program string.

The PTC-Lisp evaluation did not return successfully (<outcome>).
Send one corrected run_ptc_lisp call.

Your program ran, but its return value had the wrong shape.
Return the file content as a string. Send one corrected run_ptc_lisp call.
```

The workflow caps the loop at four turns. It validates that the model made
exactly one correctly named tool call, supplied only a non-empty `program`
argument, used an explicit `return`, produced evaluable PTC-Lisp, and returned
the expected value type. A provider failure and a model-program `(fail ...)`
terminate immediately; protocol/evaluation mistakes are recoverable until the
turn limit.

Run it:

```bash
mix ptc.run examples/kernel-tutorial/03-file-agent/ptc.json
```

In a verified live run, DeepSeek created:

```clojure
(return (tutorial.files/read-text "brief.txt"))
```

The human received:

```json
{
  "value": {
    "model_program": "(return (tutorial.files/read-text \"brief.txt\"))",
    "result": {
      "content": "Project Lantern\nOwner: Morgan\nCurrent risk: the production data-retention decision is still unresolved.\nNext checkpoint: architecture review on Thursday.\n"
    }
  },
  "usage": {
    "protocol_errors": 0,
    "subordinate_evaluations": 1,
    "capability_calls": {
      "mission": {"fs-read": 1},
      "workflow": {"llm-request": 1}
    }
  }
}
```

The example intentionally returns `model_program` so the tutorial user can
inspect what DeepSeek authored. Canonical operational traces omit model
prompts, responses, capability arguments/results, and dynamic program source.
A production application should expose model source only when its own privacy
and retention policy permits it.

This pattern fits model-authored queries, data exploration, file analysis, and
tool orchestration where the model needs narrow task authority but must not
inherit the workflow's provider or control capabilities.

## Logging and the trace viewer

Persist the canonical events for any manifest entry run with `--trace`:

```bash
mkdir -p tmp/tutorial-traces

mix ptc.run examples/kernel-tutorial/03-file-agent/ptc.json \
  --trace tmp/tutorial-traces/file-agent.jsonl
```

The result still goes to standard output. The trace is bounded, validated,
append-only JSONL. Inspect its event vocabulary directly:

```bash
jq -c '{sequence, type, data}' tmp/tutorial-traces/file-agent.jsonl
```

A successful file-agent run contains events such as:

```text
run-started
evaluation-started        workflow
capability-started        llm-request
capability-stopped         llm-request
capability-started        workflow-annotate
workflow-annotation       agent-action
capability-stopped         workflow-annotate
capability-started        kernel-eval
evaluation-started        mission
capability-started        fs-read
capability-stopped         fs-read
evaluation-stopped         mission
capability-stopped         kernel-eval
evaluation-stopped         workflow
run-stopped
```

Events pair evaluations by `evaluation_id` and capabilities by
`capability_id`. They include environment, status, duration, labels, prelude
component IDs/hashes, limit events, and aggregate usage. They deliberately do
not contain prompt/response bodies or capability payloads.

Open the read-only viewer:

```bash
mix ptc.viewer --trace-dir tmp/tutorial-traces
```

The viewer lists runs and renders paired workflow/mission evaluations,
capability calls, annotations, limits, usage metrics, and raw canonical event
metadata. Use `--port 4130` to choose a port or `--no-open` when running on a
remote machine.

The direct REPL can also persist its session events:

```bash
mix ptc.repl --trace tmp/tutorial-traces/repl.jsonl \
  -e '(def x 40)' \
  -e '(+ x 2)'
```

For private policy, set `"events": {"policy": "private"}` in the manifest and
use the reserved `.private.jsonl` suffix:

```bash
mix ptc.run private-ptc.json --trace traces/run.private.jsonl
```

The file is restricted to owner read/write before event data is appended.
Standard directory discovery and the viewer omit private-suffixed traces; a
host must explicitly construct a private TraceLog source to read them. Private
policy changes sink failure and discovery behavior—it does not make canonical
events a full prompt/response transcript.

## Results, failures, and feedback

`mix ptc.run` writes successful `Kernel.Result` data as JSON:

- `value` is the workflow's public value;
- `usage` reports remaining time, calls by environment/name, subordinate
  evaluations, protocol errors, memory state, closure state, and dropped
  events;
- `evaluation_memory` summarizes committed mission definitions/state.

An explicit Lisp `(fail value)` becomes a `workflow_failed` / `explicit_failure`
Kernel error. Parser, analyzer, timeout, memory, source, result, quota, provider,
and event-sink failures keep their own bounded classifications. The Mix task
exits non-zero and prints a bounded inspected error, for example:

```text
** (Mix) ptc.run failed: %PtcRunner.Kernel.Error{
  kind: :workflow_failed,
  reason: :explicit_failure,
  ...
}
```

Inside Lisp, capability errors are normally recoverable values:

```clojure
{:status :error
 :kind :provider_error
 :reason :unavailable
 :retryable? true}
```

The workflow—not the Kernel—decides whether to retry, correct the model,
degrade gracefully, or call `fail`. Keep that policy small, deterministic,
and bounded by a turn count as the file-agent example does.

## Limits and security boundaries

Every run has positive hard ceilings. Common manifest overrides include:

```json
"limits": {
  "run_duration_ms": 30000,
  "workflow_capability_calls": 16,
  "workflow_capability_calls_per_name": 8,
  "mission_capability_calls": 32,
  "subordinate_evaluations": 8,
  "terminal_result_bytes": 250000
}
```

Overrides may lower the installed host ceilings; they cannot raise them.
Important defaults include a 30-second run/workflow deadline, one-second
mission evaluations, bounded workflow/mission heaps, 64 workflow capability
calls, 128 mission calls, 16 subordinate evaluations, bounded source/result
sizes, and a bounded event sink. See `PtcRunner.Kernel.Limits.defaults/0` for
the complete current set.

Authority is equally explicit:

- `llm` is allowed only in the workflow provider list;
- `file-read` is allowed only in the mission provider list;
- file paths must be relative, remain below the configured root, and contain
  no symlink traversal;
- component tool requirements are discovered at compilation and must match
  environment grants;
- manifests can select trusted provider names and JSON configuration, but
  cannot register modules, callbacks, commands, or URLs as executable code.

Treat the workflow bundle and manifest as application code. Treat model source,
mission input, file content, and provider output as untrusted data.

## Useful Mix tasks

| Command | Purpose |
| --- | --- |
| `mix ptc.run MANIFEST` | Run the manifest's qualified entry and print public JSON |
| `mix ptc.run MANIFEST --mission INPUT.json` | Run with a confined alternate input object |
| `mix ptc.run MANIFEST --trace TRACE.jsonl` | Persist bounded canonical events after the run |
| `mix ptc.repl` | Start the direct transactional PTC-Lisp REPL |
| `mix ptc.repl -e EXPR -l SETUP.lisp` | Run repeatable REPL expressions with optional setup |
| `mix ptc.repl --manifest MANIFEST` | Reuse a manifest workflow bundle/capability set interactively |
| `mix ptc.viewer --trace-dir DIR` | Browse public canonical JSONL traces locally |
| `mix ptc.validate_spec` | Validate generated language/spec artifacts |
| `mix ptc.smoke` | Compare shared `.clj` smoke cases with Babashka |
| `mix precommit` | Run format, compile, Credo, spec, tests, and viewer tests |
| `mix prepush` | Run Dialyzer and unused-dependency checks |

`mix help ptc.run`, `mix help ptc.repl`, and `mix help ptc.viewer` show the
installed command options.

## Testing your own workflow

Start with three layers:

1. Exercise pure transformations in `mix ptc.repl`.
2. Run fixed manifest inputs with `mix ptc.run` and assert `.value` using `jq`.
3. Put live-provider checks behind an explicit E2E flag and assert a narrow
   contract, not prose wording.

For example:

```bash
actual="$(mix ptc.run examples/kernel-tutorial/01-orders/ptc.json | jq -c '.value')"
test "$actual" = \
  '{"order_count":3,"paid_count":2,"paid_total":335.75,"pending_ids":["A-101"]}'
```

For model workflows, test the protocol parser and feedback loop with scripted
responses in normal tests, then keep one small live DeepSeek E2E check for the
real provider boundary. Do not make correctness depend on an exact natural
language completion unless the prompt explicitly constrains it to one token or
one schema.

## Advanced: embedding from Elixir

The manifest path is preferred for deployable workflows. An Elixir host uses
the same public primitives when it needs custom provider builders, an HTTP
frontend, or application-owned event persistence:

```elixir
alias PtcRunner.Kernel
alias PtcRunner.Kernel.Component
alias PtcRunner.Kernel.EventSink
alias PtcRunner.Kernel.Limits
alias PtcRunner.Kernel.MissionEnvironment
alias PtcRunner.Kernel.RunConfig
alias PtcRunner.Kernel.WorkflowEnvironment

{:ok, component} =
  Component.new(
    id: "example",
    source: "(ns example) (defn run [input] (return (* 2 (get input \"n\"))))"
  )

{:ok, bundle} = Kernel.compile_bundle([component])
{:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
{:ok, mission} = MissionEnvironment.new([])
{:ok, limits} = Limits.new()
{:ok, sink} = EventSink.start(:normal, limits, run_id: "embedded-example")

{:ok, config} =
  RunConfig.new(
    workflow_environment: workflow,
    mission_environment: mission,
    input: %{"input" => %{"n" => 21}},
    limits: limits,
    event_sink: sink
  )

{:ok, %{value: 42}} = Kernel.run("(example/run data/input)", config)
events = EventSink.events(sink)
EventSink.stop(sink)
```

Custom capabilities remain host-owned Elixir callbacks registered through
`ProviderRegistry.new/1`; manifests may select their bounded public names but
cannot provide executable callback code.

## Where to go next

- [Kernel REPL](kernel-repl.md) covers session modes and trace persistence.
- [Kernel component bundles](capability-prelude.md) covers namespaces,
  dependencies, exports, and tool requirements.
- [Kernel contract](../plans/lisp-kernel/kernel-contract.md) defines authority,
  lifecycle, results, and the manifest schema.
- [TraceLog contract](../plans/lisp-kernel/tracelog-contract.md) defines event
  schemas, sanitization, filtering, pagination, and private sources.
- [Kernel product readiness](../plans/lisp-kernel/product-readiness.md) records
  current limitations, prioritized improvements, and release gates.
- [Capability connectors](../plans/lisp-kernel/capability-connectors.md) is the
  future plan for MCP, OpenAPI, database, file, and server integrations, with
  proposed configuration and PTC-Lisp examples.
- [Host access and prelude workspaces](../plans/lisp-kernel/host-access-and-prelude-workspaces.md)
  plans authenticated human/model trace inspection, exact-source grants,
  versioned prelude candidates, validation, review, and promotion, with usage
  examples in its appendix.
