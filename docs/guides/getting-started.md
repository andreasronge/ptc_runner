# Getting started

This guide runs a complete credential-free PtcRunner workflow. The workflow is
written in PTC-Lisp, receives JSON input, and returns a bounded JSON value plus
runtime usage. No model key and no host code are required.

PTC-Lisp is a small, eager, bounded subset of Clojure, with a few additions for
agent execution such as `return`, `fail`, `tool/...` capability calls, and the
`*1`/`*2`/`*3` continuation history. Most supported collection and data
expressions are ordinary Clojure; arbitrary JVM access, macros, lazy or
infinite sequences, and unsupported Clojure APIs are not part of the language.
The [language specification](../ptc-lisp-specification.md) is authoritative.

The Kernel product is currently run from a source checkout with Elixir and Mix.
A standalone macOS command and Docker image are planned for a later 0.x release
from `main`.

## Create a minimal application

The shared command surface accepts `ptc init DIRECTORY`. From a source checkout,
invoke that same command boundary in `iex -S mix`:

```elixir
{:ok, outcome} =
  PtcRunner.Kernel.CommandEngine.dispatch(["init", "hello-ptc"])
```

Initialization publishes exactly `main.clj` and `ptc.json`. Their bytes are a
stable contract:

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

The complete scaffold is validated in memory and assembled in an owner-only
sibling directory. Publication uses an atomic no-replace rename, so an
existing directory or symlink is never merged, overwritten, or removed. A
failed initialization returns the path-free `initialization_failed` diagnostic;
a clean pre-publication failure can be retried.

## Run the example

From the repository root:

```console
mix deps.get
mix ptc.run examples/kernel-tutorial/01-orders/ptc.json
```

The command prints one JSON object. Its `value` is:

```json
{
  "order_count": 3,
  "paid_count": 2,
  "paid_total": 335.75,
  "pending_ids": ["A-101"]
}
```

The rest of the result reports remaining time, capability calls, subordinate
evaluations, protocol errors, retained continuation state, and dropped events.
Values such as remaining time vary between runs.

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

Canonical traces contain bounded operational facts rather than prompts,
capability payloads, or generated source:

```console
mkdir -p tmp/tutorial-traces
mix ptc.run examples/kernel-tutorial/01-orders/ptc.json \
  --trace-dir tmp/tutorial-traces
```

The JSON Lines file records the run, workflow evaluation, outcome, usage, and
limits. Query the captured directory through the fixed log-analysis profile:

```console
mix ptc.repl \
  --profile log-analysis-v2 \
  --resource traces=tmp/tutorial-traces \
  -e '(log.analysis/all-runs {"limit" 50} 10)'
```

The profile receives an immutable capture and has no filesystem, network,
model, private-inspection, or nested-evaluation authority. The final argument
is a page bound. The result carries the immutable source's `snapshot_hash`.
The returned `complete?` field is `false` if that bound stops the traversal
before the captured source is exhausted.

## Try the language directly

Use the bounded REPL for small expressions and definitions:

```console
mix ptc.repl \
  -e '(def tax-rate 0.2)' \
  -e '(* 100 tax-rate)' \
  -e '(+ *1 5)'
```

Successful definitions and the three most recent ordinary values persist for
one session. Failed forms do not publish their candidate definitions.

## Next steps

Continue in this order:

1. [Manifests and capabilities](manifests-and-capabilities.md) documents the
   declarative authority boundary — components, input, contracts, providers,
   limits, and event policy.
2. [Host configuration](host-configuration.md) is the operator document that
   installs providers and supplies credentials. You need it before any example
   that calls a model.
3. [Building agents](building-agents.md) explains model calls and confined
   model-authored mission programs.
4. [Running and debugging](running-and-debugging.md) covers commands, traces,
   private inspection, and the development Viewer.

The [PTC-Lisp specification](../ptc-lisp-specification.md) and
[function reference](../function-reference.md) define the language surface.
