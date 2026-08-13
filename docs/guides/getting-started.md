# Getting started

This guide runs a complete PtcRunner workflow and reads its main files. It
starts credential-free and ends with a live model call.

If you would rather see that model call first and read afterwards, the
[Quickstart](quickstart.md) gets there in four commands.

PTC-Lisp is an eager, bounded Clojure subset with agent additions such as
`return`, `fail`, `tool/...` capability calls, and `*1`/`*2`/`*3` continuation
history. It excludes arbitrary JVM access, macros, lazy or infinite sequences,
and unsupported Clojure APIs. The
[language specification](../ptc-lisp-specification.md) is authoritative.

The Kernel product runs from a source checkout through `mix ptc` and from a
runtime-included release through `bin/ptc`.

## Create a minimal application

`ptc init DIRECTORY` creates an empty application. From a source checkout:

```console
mix ptc init hello-ptc
```

Initialization creates `main.clj` and `ptc.json`:

```clojure
(ns main)

(defn run [input]
  (return input))
```

```json
{
  "version": 1,
  "workflow": {
    "components": [
      {
        "id": "main",
        "path": "main.clj"
      }
    ],
    "entry": "main/run"
  },
  "input": {
    "value": {}
  }
}
```

Initialization refuses to merge with or overwrite an existing path.
[Running and debugging](running-and-debugging.md#choose-a-command) lists the command
and failure behavior.

## Run the example

From the repository root:

```console
mix deps.get
mix ptc run examples/kernel-tutorial/01-orders/ptc.json
```

The command prints the compact JSON result value (expanded here for reading):

```json
{
  "order_count": 3,
  "paid_count": 2,
  "paid_total": 335.75,
  "pending_ids": ["A-101"]
}
```

Use `--envelope FILE` when a caller also needs stable command metadata and
runtime usage. [Running and debugging](running-and-debugging.md#read-results-and-failures)
explains results, errors, and envelopes.

## Read the project

The example has three files:

```text
examples/kernel-tutorial/01-orders/
├── ptc.json
├── orders.clj
└── orders.json
```

The manifest selects a PTC-Lisp component, its public entry function, and the
input file:

```json
{
  "version": 1,
  "workflow": {
    "components": [
      {"id": "tutorial.orders", "path": "orders.clj"}
    ],
    "entry": "tutorial.orders/summarize"
  },
  "input": {"path": "orders.json"}
}
```

The entry is an ordinary public PTC-Lisp function. `data/input` supplies the
decoded manifest input:

```clojure
(ns tutorial.orders "Deterministic order aggregation." {:visibility :prompt})

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

`return` marks intentional successful completion. `fail` marks an intentional
workflow failure. A function that finishes normally without either still
produces a normal Lisp value, which is useful for intermediate REPL-style
agent turns.

## Record a trace

Canonical traces contain bounded operational facts, not prompts, capability
payloads, or generated source:

```console
mkdir -p tmp/tutorial-traces
mix ptc run examples/kernel-tutorial/01-orders/ptc.json \
  --trace-dir tmp/tutorial-traces
```

The JSON Lines file records the run, workflow evaluation, outcome, usage, and
limits. Query the captured directory through the fixed run-analysis profile:

```console
mix ptc repl \
  --profile run-analysis-v1 \
  --resource traces=tmp/tutorial-traces \
  -e '(analysis/runs {"limit" 50})'
```

The profile queries one frozen capture and has no filesystem, network, model,
private-inspection, or nested-evaluation authority. The
[Kernel REPL guide](kernel-repl.md#query-public-traces) defines its
result fields.

## Try the language directly

Use the bounded REPL for small expressions and definitions:

```console
mix ptc repl \
  -e '(def tax-rate 0.2)' \
  -e '(* 100 tax-rate)' \
  -e '(+ *1 5)'
```

Successful definitions and the three most recent values persist for one
session, and a failed form leaves that state untouched. The
[Kernel REPL guide](kernel-repl.md) covers the other session modes.

## Call a model

Everything above is deterministic. Adding a model takes one credential and one
extra flag.

Copy `.env.example` to the Git-ignored `.env` and set `OPENROUTER_API_KEY` to
your [OpenRouter](https://openrouter.ai/keys) key. Pass `--env-file .env` to
load that exact file; PtcRunner does not search for it implicitly.
[Host configuration](host-configuration.md#declare-credentials-once) documents the three
declaration forms and how to move off `.env` for a real deployment.

```console
mix ptc run examples/kernel-tutorial/02-deepseek-extract/ptc.json \
  --env-file .env \
  --host-config examples/kernel-tutorial/ptc-host.json
```

```json
{"model_output":"{\"project\":\"Atlas\",\"owner\":\"Priya\",\"risk\":\"delayed vendor security approval\"}","note":"model_output is model text; validate or parse it before production use"}
```

The model's exact wording varies between runs; the result shape does not.

`--host-config` names the operator document that gives the manifest's
`deepseek` alias a model and credential. The manifest may select and narrow the
alias, but cannot name a model, endpoint, or key. The model output remains
untrusted text until the workflow parses and validates it.

Let the model write the program instead:

```console
mix ptc run examples/kernel-tutorial/04-multi-turn-agent/ptc.json \
  --env-file .env \
  --host-config examples/kernel-tutorial/ptc-host.json
```

```json
{"ok":true,"value":42}
```

The model authored PTC-Lisp across two turns and the runtime evaluated it in
the confined mission environment.

## Next steps

Continue in this order:

1. [Building agents](building-agents.md) explains the agent loop, the
   correction protocol, and confined model-authored mission programs.
   The [agent library reference](../agent-library-reference.md) holds its exact
   entries, options, and retry contract.
2. [Manifests and capabilities](manifests-and-capabilities.md) documents the
   declarative authority boundary — components, input, contracts, providers,
   limits, and event policy.
3. [Host configuration](host-configuration.md) is the operator document that
   installs providers, supplies credentials, and sets ceilings.
4. [Running and debugging](running-and-debugging.md) covers commands, traces,
   private inspection, and the development Viewer.

The [PTC-Lisp specification](../ptc-lisp-specification.md) and
[function reference](../function-reference.md) define the language surface.
