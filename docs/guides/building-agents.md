# Building agents in PTC-Lisp

PtcRunner does not prescribe one agent loop. The Kernel provides bounded
execution and explicit authority; PTC-Lisp libraries define prompts, retries,
feedback, continuation, and completion policy.

Start with [Getting started](getting-started.md). The examples below live in
[`examples/kernel-tutorial/`](https://github.com/andreasronge/ptc_runner/tree/main/examples/kernel-tutorial) and use
the repository's trusted `deepseek` host alias.

## Use the shipped loop

A local workflow can delegate the loop to `agent.core`:

```clojure
(ns my.agent)

(defn run [input]
  (agent.core/run (get input "task")
                  {"max_turns" 4 "mission" "research"}))
```

Select the library and declare the dependency:

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

The installed dependency closure supplies the provider-neutral prompt,
feedback, retry, result, and evaluation helpers. The host freezes the exact
sources before execution.

Choose the entry that matches the caller:

| Entry | Use it when |
| --- | --- |
| `agent.core/run` | The agent is the terminal workflow entry. It returns `{:ok true :value ...}` by default. |
| `agent.core/run-value` | The outer workflow must validate, compare, or score the returned value. Subject failure calls `fail`. |
| `agent.core/run-outcome` | An evaluator must retain subject failures as data. Host and provider failures still fail the workflow. |
| `agent.main/run` | A manifest should use the generic wrapper and validate terminal values against its result contract. |

All entries select the mission independently of the model. Missing or `nil`
`mission` means `default`; an empty, non-string, or unknown name fails rather
than falling back.

The [agent library reference](../agent-library-reference.md) defines every
entry, option, default, outcome, and correction rule.

## Understand the two environments

Every run separates trusted orchestration from model-authored task work:

| Environment | Contains | Does not inherit |
| --- | --- | --- |
| Workflow | Agent policy and workflow-only model access | Mission capabilities |
| Mission | The small API granted to generated programs | Model access or ambient host state |

The shipped loop follows this sequence:

1. The host freezes the workflow and mission bundles and installs explicit
   capabilities.
2. The workflow asks a model for one `run_ptc_lisp` tool call.
3. The Kernel compiles and evaluates that source in the selected mission.
4. An ordinary value becomes an observation for another turn. `(return value)`
   completes the agent; `(fail value)` reports a model-program failure.

Generated code cannot call the model, recursively cross the evaluation
boundary, or access ungranted filesystem, network, or process state.
[Manifests and capabilities](manifests-and-capabilities.md) defines the
declarative boundary; [Host configuration](host-configuration.md) defines the
operator-owned installation behind each selected alias.

## Write bounded PTC-Lisp

PTC-Lisp is an eager, bounded Clojure subset with agent-oriented additions:
`return`, `fail`, `tool/...` calls, and the `*1`, `*2`, and `*3` continuation
values. It excludes arbitrary JVM access, macros, `eval`, lazy or infinite
sequences, and unsupported Clojure APIs.

Use the [PTC-Lisp specification](../ptc-lisp-specification.md) and
[function reference](../function-reference.md) for the exact language surface.
[Clojure conformance gaps](../clojure-conformance-gaps.md) records deliberate
differences.

### Keep source separate from runtime data

Pass evidence through `data/params` instead of interpolating it into source:

```clojure
(kernel/eval-with
  "default"
  (program
    (return (workspace/read {"path" (get data/params "path")})))
  {"path" selected-path})
```

Use `kernel/eval-source-with` when the source itself is generated. Parameters
must be JSON values and remain subject to the capability argument limit. This
keeps the code digest stable and prevents incidental data from becoming code.

For advisory validation before evaluation:

```clojure
(kernel/check-source "default" generated-source)
```

The check uses the live mission bundle and committed definitions but does not
execute code or consume an evaluation. Evaluation compiles the source again
and can still fail. The subordinate-evaluation contract is normative in
[the specification](../ptc-lisp-specification.md#16-2-environment-structure).

### Configure the loop

`agent.core` defaults to four turns and accepts bounded options for the model,
mission, turn count, program size, observation size, transcript size, and when
to encourage consolidation. `agent.main/run` reads the same options from the
input's `agent` map.

The loop tells the model its remaining budget and requires `return` or `fail`
on the final turn. Loop settings never increase Kernel limits. Concurrent
agents can overlap provider calls, but their mission evaluations share the
run's bounded admission queue.

Use the [agent library reference](../agent-library-reference.md#configuration)
for exact defaults and validation. Use
[the limits reference](../kernel-limits-reference.md)
for Kernel ceilings.

## Select model access separately

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

The trusted host document resolves the alias to a model, credential, sampling
policy, executable, working directory, and tool mapping. A manifest cannot
invent those values. Live and replayed models are workflow-only; MCP and
snapshot sources are mission-only.

Credentials never belong in PTC-Lisp, manifests, traces, or committed project
files. The [Quickstart credential step](quickstart.md#2-supply-a-model-credential)
creates the tutorial's explicitly named environment file. See
[Host configuration](host-configuration.md#declare-credentials-once) for
deployment-safe credential sources.

## Use a model as a capability

Not every workflow needs model-authored code. A custom workflow can call the
workflow-only `llm-request` capability directly:

```clojure
(tool/llm-request
  {"system" "Extract project metadata as one compact JSON object."
   "messages" [{"role" "user" "content" text}]})
```

Raw capabilities return an envelope:

```clojure
{:status :ok
 :value {"content" "{\"project\":\"Atlas\",...}" ...}}
```

Failures, timeouts, denied calls, invalid arguments, and quota exhaustion use
bounded error envelopes. Do not treat an error envelope as content. Model text
is also untrusted: parse it with `json/parse-string`, validate its shape, then
correct or fail.

The shipped `llm/request` wrapper unwraps success and preserves recoverable
errors. With several selected model aliases, either name one or mark one
manifest selection as the default. There is no fallback for an unknown alias.
The [provider-neutral request reference](../agent-library-reference.md#provider-neutral-requests)
defines the request and response fields.

[`02-deepseek-extract`](https://github.com/andreasronge/ptc_runner/blob/main/examples/kernel-tutorial/02-deepseek-extract/extract.clj)
shows this pattern end to end.

## Expose a small mission API

Prompt-visible wrappers make supported calls and return contracts clear:

```clojure
(ns my.files "Mission access to the granted file root." {:visibility :prompt})

(defn read-page
  "Read one bounded UTF-8 page. Pass nil first, then next_cursor."
  {:signature "(path :string, cursor :string?) -> :any"}
  [path cursor]
  (let [arguments (if cursor {"path" path "cursor" cursor} {"path" path})
        response (tool/workspace.read arguments)]
    (if (= :ok (get response :status))
      (get response :value)
      (fail response))))
```

The signature validates the public function boundary. The capability still
enforces its own schema, byte ceiling, timeout, quota, and environment grant.
Concatenate each page's item `text` exactly, and pass `next_cursor` into the
next call until it is nil. Do not collect an unbounded file into one evaluation;
reduce pages into bounded state or resume in a later evaluation.

## Continue across turns

An ordinary successful mission form commits definitions and continues:

```clojure
(defn normalize-name [value] (clojure.string/trim value))
```

A later turn can use the definition and complete:

```clojure
(return (normalize-name "  Ada  "))
```

Successful ordinary values enter a three-item history as `*1` through `*3`.
Terminal `return` commits definitions but does not add its value to history.
Failed evaluations preserve the previous definitions and history.

[`04-multi-turn-agent`](https://github.com/andreasronge/ptc_runner/blob/main/examples/kernel-tutorial/04-multi-turn-agent/ptc.json)
demonstrates a two-turn definition and call:

```console
mix ptc run examples/kernel-tutorial/04-multi-turn-agent.ptc-project.json
```

## Handle failures without repeating effects

`agent.core` correlates each assistant tool call with a provider-valid tool
result. Successful nonterminal programs receive a bounded, escaped observation;
failed pure evaluations receive bounded correction feedback. The complete
prospective transcript remains bounded.

Retryability depends on effects:

| Failed evaluation observed | Automatic correction turn |
| --- | --- |
| No capability call | yes |
| Only capabilities declared `effect: "read"` | yes |
| A `write` or undeclared effect | no repeat; one closing turn may summarize existing evidence |

External effects are not rolled back with Lisp memory. A timed-out write may
have happened and is reported with indeterminate mutation state. Missing effect
metadata is treated conservatively as unsafe. MCP write installations require
an explicit non-empty manifest `allow` list.

An explicit `(fail value)` is terminal except for a narrowly proven read-only
capability failure. Correction feedback is bounded and does not echo submitted
values or undeclared keys. If host-side validation itself becomes unavailable,
the workflow fails instead of blaming the model or spending another turn.

Public errors and canonical traces never copy the outer `fail` value, prompt,
model response, generated source, or capability payload. Use an explicitly
enabled private inspection artifact when those details are required. See
[Running and debugging](running-and-debugging.md#inspect-a-private-model-conversation).
The [agent library reference](../agent-library-reference.md#retry-and-effect-safety)
contains the complete correction and retry contract.

## Run the file-agent example

The checked-in example combines the shipped loop, a model alias, and one
prompt-visible read facade:

```text
examples/kernel-tutorial/03-file-agent/
├── ptc.json
├── agent.clj
├── files.clj
└── files/
    └── brief.txt
```

Run it from the repository root:

```console
mix ptc run examples/kernel-tutorial/03-file-agent.ptc-project.json
```

This example requires Node.js 22 or newer. It runs the committed MCP server
bundle, so readers do not need `npm install` or `npm run build`.

The model sees `tutorial.files/read-page`, not the host credential or an
unrestricted filesystem. The project records a sanitized trace under
`03-file-agent/.ptc/traces`; inspect it with the Viewer or fixed run-analysis
profile described in [Running and debugging](running-and-debugging.md).

## Replace prompt policy after the loop works

`agent.prompt` owns the system prompt separately from `agent.core`. Its
`initial-state`, `render`, and `transition` functions are the seam to replace
when a different prompt policy is required. Keep the loop and its failure rules
unchanged while experimenting with how the model is instructed.

Evaluate a replacement for the selected `agent.prompt` component with a
hash-checked component override. Ordinary manifests cannot permanently shadow
that shipped ID. For permanent application-specific composition, create custom
loop and prompt components under new IDs. The
[shipped prelude reference](../prelude-reference.md#customize-or-replace-a-component)
distinguishes those paths.

Prompt-visible mission functions form a facade: when any exist, they suppress
raw `tool/...` entries. Without a facade, the prompt lists direct mission
capabilities. Numeric limits remain enforced but are not rendered into the
default prompt; trusted workflow code can inspect the frozen structured
inventory through `kernel/mission-inventory`.

Keep prompts domain-blind. Describe the language, mission API, current task,
and generic correction policy, never benchmark fixtures or expected answers.
The [Components and preludes](components-and-preludes.md) guide owns exact
composition and dependency rules.

## Next steps

- [Components and preludes](components-and-preludes.md) covers reusable
  namespaces, dependencies, exports, signatures, and tool requirements.
- [Manifests and capabilities](manifests-and-capabilities.md) covers providers,
  limits, contracts, and event policy.
- [Running and debugging](running-and-debugging.md) covers traces, private
  inspection, and the Viewer.
- [Kernel REPL](kernel-repl.md) covers interactive development and analysis.
