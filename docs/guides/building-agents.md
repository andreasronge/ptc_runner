# Building agents in PTC-Lisp

PtcRunner is a meta-agentic harness rather than one fixed agent loop. The
Kernel provides bounded execution and authority; PTC-Lisp libraries define how
an agent prompts a model, handles feedback, retries, delegates work, remembers
successful state, and decides when to return or fail.

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
      "path": "agent.lisp",
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

## Grant model access separately from task access

An agent workflow normally receives the built-in model provider:

```json
"providers": {
  "workflow": [
    {"name": "llm", "config": {"model": "deepseek", "cache": false}}
  ]
}
```

The mission receives only the capabilities needed for the task. For example,
the file-agent fixture confines file reads to one manifest-relative directory:

```json
"providers": {
  "workflow": [
    {"name": "llm", "config": {"model": "deepseek", "cache": false}}
  ],
  "mission": [
    {
      "name": "file-read",
      "config": {"root": "files", "max_bytes": 65536, "model_visible": true}
    }
  ]
}
```

The host resolves and validates the root. A manifest cannot choose an absolute
path, traverse out of its directory, register a callback, or invent a network
destination.

## Give the model a small mission API

Prompt-visible mission wrappers make the supported calls and return contracts
clear:

```clojure
(ns my.files "Mission access to the granted file root." {:visibility :prompt})

(defn read-text
  "Read one UTF-8 file beneath the configured root."
  {:signature "(path :string) -> :string"}
  [path]
  (let [response (tool/fs-read {"path" path})]
    (if (= :ok (get response :status))
      (get-in response [:value "content"])
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

Failed turns publish none of their candidate definitions. The Kernel retains
only bounded definition memory and the three most recent ordinary successful
values. The workflow's `max_turns` policy does not expand the Kernel's run,
evaluation, provider, source, heap, result, or event ceilings.

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

The complete live examples are under `examples/kernel-tutorial/`:

- `02-deepseek-extract` uses a model as one bounded capability;
- `03-file-agent` runs model-authored PTC-Lisp with confined file access;
- `04-multi-turn-agent` demonstrates committed definitions across turns.

They currently require the repository's trusted `deepseek` model alias and an
`OPENROUTER_API_KEY` configured outside PTC-Lisp and the manifest.
