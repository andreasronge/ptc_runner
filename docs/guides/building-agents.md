# Building agents in PTC-Lisp

PtcRunner is a meta-agentic harness rather than one fixed agent loop. The
Kernel provides bounded execution and authority; PTC-Lisp libraries define how
an agent prompts a model, handles feedback, retries, delegates work, remembers
successful state, and decides when to return or fail.

## PTC-Lisp and Clojure

PTC-Lisp is a small, eager, bounded subset of Clojure, plus a few
agent-oriented extensions. Familiar Clojure data, collection functions,
threading forms, destructuring, namespaces, and `defn` syntax carry over. The
runtime deliberately excludes arbitrary JVM access, macros, `eval`, lazy or
infinite sequences, and any Clojure API that is not in the supported surface.

PTC-specific additions include `return` and `fail`, `tool/...` capability
calls, and the `*1`, `*2`, and `*3` continuation values. Start with normal
Clojure data-transformation style, then check the
[PTC-Lisp specification](../ptc-lisp-specification.md),
[function reference](../function-reference.md), and
[documented Clojure gaps](../clojure-conformance-gaps.md) for the exact
boundary.

## Workflow and mission

Every Kernel run separates two environments:

| Environment | Purpose | Typical authority |
| --- | --- | --- |
| Workflow | Trusted agent orchestration and policy | Model requests, mission evaluation, annotations |
| Mission | Confined task execution | Narrow file, trace, or installed connector capabilities |

A model can write mission PTC-Lisp without receiving the workflow's model
capability. Mission code cannot recursively invoke the Kernel evaluation
boundary or access ambient host state.

```text
workflow PTC-Lisp ---- llm-request ----> model
        |
        | generated PTC-Lisp
        v
mission evaluation ---- task tools ----> granted resources
```

For the shipped `agent.core` loop, the complete flow is:

1. The host loads the manifest, freezes the workflow and mission PTC-Lisp
   bundles, installs capabilities, and obtains provider credentials from the
   host environment.
2. The workflow entry calls `agent.core/run` with the human task.
3. `agent.core` renders the PTC-Lisp mission API and sends the model one
   provider request through the workflow-only `llm-request` capability. The
   request exposes one model tool named `run_ptc_lisp`.
4. The model calls `run_ptc_lisp` with a PTC-Lisp program string. It does not
   receive direct access to the Kernel or host filesystem.
5. The Kernel compiles and evaluates that string inside the mission
   environment. Only mission capabilities can be called there.
6. `(return value)` completes the agent. An ordinary value continues to another
   model turn, and `(fail value)` terminates as a model-program failure.

The model is therefore used to author or refine bounded PTC-Lisp; it is not the
runtime that executes task tools.

## Use the shipped agent library

The shipped `agent.core` component owns a generic bounded model/tool loop. A
local workflow can remain small:

```clojure
(ns my.agent)

(defn run [input]
  (agent.core/run (get input "task") {"max_turns" 4}))
```

Select the installed library and declare the dependency in the manifest:

```json
"workflow": {
  "components": [
    {
      "id": "my.agent",
      "path": "agent.clj",
      "dependencies": ["agent.core"]
    },
    {"library": "agent.core"}
  ],
  "entry": "my.agent/run"
}
```

The installed dependency closure includes PTC-Lisp components for prompt
construction, provider-valid feedback, retries, native result handling, and
mission evaluation. The host freezes their exact source hashes into the
workflow bundle before execution.

## Select model access separately from task access

The manifest selects host-installed aliases and may narrow their grants:

```json
"providers": {
  "workflow": [
    {"name": "deepseek"}
  ],
  "mission": [
    {"name": "workspace", "config": {"allow": ["workspace.read"]}}
  ]
}
```

The separate trusted host document says what those names mean:

```json
"credentials": {
  "openrouter_key": {"env": "OPENROUTER_API_KEY"}
},
"install": {
  "deepseek": {
    "source": "llm",
    "model": "openrouter:deepseek/deepseek-v4-flash",
    "credential": "openrouter_key"
  },
  "workspace": {
    "source": "mcp",
    "transport": {
      "type": "stdio",
      "command": "node",
      "cwd": ".",
      "args": [
        "../mcp/filesystem/dist/server.js",
        "--root", "03-file-agent/files",
        "--include", "**"
      ],
      "inherit_environment": true,
      "env": {}
    },
    "tools": {
      "read_text_file": {
        "as": "workspace.read",
        "effect": "read"
      }
    }
  }
}
```

The host resolves and freezes the model, executable, working directory,
snapshot include rules, credential binding, and tool mapping. The manifest
cannot invent a model, callback, command, credential, or network destination.

## Supply model credentials from the host

Credentials never belong in PTC-Lisp, a manifest, a canonical trace, or a
committed project file. The host document binds its `openrouter_key` credential
to the operator's environment. For the tutorial's `deepseek` alias, use an
OpenRouter key:

```console
cp .env.example .env
chmod 600 .env
# Edit .env and set OPENROUTER_API_KEY to the real key.
```

When commands run from the repository root, the adapter loads that `.env` at
application startup. An already exported shell variable takes precedence:

```console
export OPENROUTER_API_KEY="..."
mix ptc.run examples/kernel-tutorial/03-file-agent/ptc.json \
  --host-config examples/kernel-tutorial/ptc-host.json
```

`.env` is ignored by Git, but it is still a plaintext local secret; use the
shell, `direnv`, or a secret manager where appropriate. The host fixes the
full `openrouter:deepseek/deepseek-v4-flash` model identifier, so the manifest's
short alias contains no provider-resolution magic and cannot carry or override
its credential.

## Give the model a small mission API

Prompt-visible mission wrappers make the supported calls and return contracts
clear:

```clojure
(ns my.files "Mission access to the granted file root." {:visibility :prompt})

(defn read-text
  "Read one UTF-8 file beneath the configured root."
  {:signature "(path :string) -> :string"}
  [path]
  (let [response (tool/workspace.read {"path" path})]
    (if (= :ok (get response :status))
      (str (str/join "\n"
             (map #(get % "text") (get-in response [:value "lines"])))
           "\n")
      (fail response))))
```

The wrapper signature validates the public function boundary. The raw
capability still validates its own arguments, result schema, byte ceiling,
timeout, quota, and environment grant.

## Multi-turn continuation

An ordinary successful mission form commits definitions and continues the
agent loop:

```clojure
(defn normalize-name [value] (clojure.string/trim value))
```

A later turn can call the committed definition and complete:

```clojure
(return (normalize-name "  Ada  "))
```

Failed turns publish none of their candidate definitions. Two separate bounded
continuation stores exist:

- **definition memory** contains committed `def` and `defn` bindings;
- **value history** contains at most the three most recent ordinary successful
  values, exposed directly as `*1` (newest), `*2`, and `*3`.

These are the same `*1`/`*2`/`*3` values seen in a direct PTC-Lisp REPL. They
are not REPL commands and they are not an additional hidden agent memory. An
ordinary successful model-authored mission program adds its result to this
history and continues the loop. A terminal `(return ...)` commits definitions
but does not add its returned value to history. Failed evaluations preserve the
previous definitions and history unchanged.

The workflow's `max_turns` policy does not expand the Kernel's run, evaluation,
provider, source, heap, result, history, memory, or event ceilings.

## Handle failures as policy

Capability calls return uniform success or error envelopes. The workflow may
retry a transient model failure, provide bounded correction feedback after a
pure evaluation error, degrade to another result, or call `fail`.

External effects are not rolled back with Lisp memory. The shipped agent loop
therefore does not automatically retry an evaluation error after capability
activity. This policy lives in PTC-Lisp, while the Kernel remains responsible
for accounting and rejecting late results after closure.

## Keep prompts domain-blind

Agent and system prompts describe the language, available API, current task,
and generic correction protocol. They must not encode benchmark domains,
fixture values, or expected answer patterns. Capability descriptions may
describe the capability they expose.

## Run the complete file-agent flow

The checked-in file agent joins every piece above:

```text
examples/kernel-tutorial/03-file-agent/
├── ../ptc-host.json shared host installation
├── ptc.json       manifest and provider grants
├── agent.clj      workflow entry over agent.core
├── files.clj      prompt-visible mission API
└── files/
    └── brief.txt  frozen mission input
```

Its input asks the model to read `brief.txt`. A typical model action is:

```clojure
(return (tutorial.files/read-text "brief.txt"))
```

`ptc.json` connects the pieces: `tutorial.agent/run` is the workflow entry,
`agent.core` is its shipped PTC-Lisp dependency, `deepseek` is installed only
in the workflow, and the mapped `workspace.read` MCP tool is installed only in
the mission. The model sees the documented `tutorial.files/read-text` facade,
not the host credential or an unrestricted file API.

Run it from the repository root and retain its sanitized trace:

```console
mkdir -p tmp/file-agent-traces
mix ptc.run examples/kernel-tutorial/03-file-agent/ptc.json \
  --host-config examples/kernel-tutorial/ptc-host.json \
  --trace tmp/file-agent-traces/file-agent.jsonl
```

The public result has this stable shape (duration and remaining budgets vary):

```json
{
  "value": {
    "ok": true,
    "value": "Project Lantern\nOwner: Morgan\n..."
  },
  "usage": {
    "subordinate_evaluations": 1,
    "capability_calls": {
      "workflow": {"llm-request": 1},
      "mission": {"workspace.read": 1}
    }
  },
  "evaluation_memory": {
    "defined_count": 0,
    "history_count": 0
  }
}
```

That accounting makes the authority flow visible without exposing the prompt,
model response, generated source, or file payload in the canonical log. The
zero `history_count` is expected: the first mission program used `return`, so
there was no ordinary intermediate value to retain as `*1`.

Inspect the run through the bounded log-analysis REPL:

```console
mix ptc.repl \
  --profile log-analysis-v1 \
  --resource traces=tmp/file-agent-traces \
  -e '(def run-id (get-in (log/runs {}) ["items" 0 "run_id"]))' \
  -e '(log/run run-id)' \
  -e '(log/turns run-id {"limit" 100})' \
  -e '(log/counters {})'
```

Because this directory contains one run, index `0` selects it. `log/run` shows
the complete status and capability/evaluation counters; `log/turns` shows the
ordered sanitized events. Exact prompts, model responses, generated PTC-Lisp,
and capability payloads require an explicitly enabled private inspection
artifact; see [Running and debugging](running-and-debugging.md).

One verified DeepSeek run produced 17 canonical events and this flow:

| Sequence | Canonical evidence | What happened |
| --- | --- | --- |
| 1–2 | `run-started`, workflow `evaluation-started` | The frozen workflow began. |
| 3–4 | `kernel-mission-model-context` capability | `agent.core` obtained the prompt-visible mission API. |
| 5–6 | workflow `llm-request`, status `ok` | DeepSeek received the task, language context, and `run_ptc_lisp` schema. |
| 7–9 | `workflow-annotation`, kind `tool-call`, turn `0` | The model returned one valid `run_ptc_lisp` action. |
| 10–11 | `kernel-eval`, mission `evaluation-started` | The Kernel accepted a 47-byte PTC-Lisp program; the trace retained its hash and size, not its source. |
| 12–13 | mission `workspace.read`, status `ok` | The program used the one granted task capability. |
| 14–15 | mission status `returned`, `kernel-eval` status `ok` | The mission completed on its first turn, with zero history values. |
| 16–17 | workflow `evaluation-stopped`, `run-stopped` | The public result and bounded usage were finalized successfully. |

The same run's aggregate query returned two evaluations, four workflow
capability calls (mission-context lookup, model request, annotation, and
mission evaluation), one mission capability call, and zero errors. Durations,
IDs, timestamps, and hashes vary; the event ordering and authority separation
are the useful contract.

### Analyze what the model received and generated

Canonical traces intentionally answer *what happened* without retaining
private content. For local development, repeat the run with an explicit
inspection artifact to answer *what the model saw and wrote*:

```console
mkdir -p tmp/file-agent-private
mix ptc.run examples/kernel-tutorial/03-file-agent/ptc.json \
  --host-config examples/kernel-tutorial/ptc-host.json \
  --trace tmp/file-agent-private/file-agent.jsonl \
  --inspect tmp/file-agent-private/file-agent.inspection.jsonl
```

The inspection artifact is created with owner-only permissions and contains
the full request, response, generated source, and capability payloads. Keep it
local and do not publish it as a normal trace. The log-analysis REPL cannot
read or join this private data by design; inspect it with the development
Viewer described in [Running and debugging](running-and-debugging.md).

In a verified one-turn DeepSeek run, the request contained four relevant
parts:

| Feed part | What DeepSeek received |
| --- | --- |
| System instructions | Call `run_ptc_lisp` exactly once per turn; ordinary results continue; successful definitions persist; failed definitions roll back; `return` completes; `fail` aborts; do not answer in prose. |
| Language summary | PTC-Lisp is described to the model as a bounded Clojure-like language, followed by its common forms, namespaces, JSON-map convention, exclusions, and short examples. |
| Available mission API | Only `(tutorial.files/read-text path)`, documented as a read effect from a string path to a string result. |
| User message and model tool | Read `brief.txt` through that wrapper and return its exact contents; one `run_ptc_lisp` tool accepting one required `program` string. |

The request did **not** contain the file contents, provider credential,
unrestricted filesystem access, or the workflow's raw `llm-request`
capability. The model had to express the requested action through the one
advertised mission function. The provider reported 895 input tokens for this
small feed in the verified run; token counts can change with prompt or provider
updates.

DeepSeek generated exactly this 47-byte program:

```clojure
(return (tutorial.files/read-text "brief.txt"))
```

The code is minimal and correct:

1. `tutorial.files/read-text` uses the prompt-visible wrapper instead of
   guessing a raw host or capability API.
2. `"brief.txt"` is the requested relative path; the host-confined provider
   resolves and validates it beneath the granted root.
3. `return` makes the first mission evaluation terminal, so no second model
   turn is needed.
4. The program creates no definitions and no ordinary intermediate result,
   matching the public `defined_count: 0` and `history_count: 0`.

This example is intentionally simple: the task already supplies both the
function and path, so the model's job is mainly to select the allowed API and
serialize a valid terminal PTC-Lisp program. More complex agents use the same
boundary across several turns, with inspection recording each private request,
response, and generated program while the canonical trace retains only bounded
operational evidence.

The live tutorial set under `examples/kernel-tutorial/` also includes:

- `02-deepseek-extract` uses a model as one bounded capability;
- `03-file-agent` runs model-authored PTC-Lisp with confined file access;
- `04-multi-turn-agent` demonstrates committed definitions across turns.

They currently require the repository's trusted `deepseek` model alias and an
`OPENROUTER_API_KEY` configured outside PTC-Lisp and the manifest.
