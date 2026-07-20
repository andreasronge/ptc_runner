# Getting started

This guide runs a complete credential-free PtcRunner workflow. The workflow is
written in PTC-Lisp, receives JSON input, and returns a bounded JSON value plus
runtime usage. No model key or Elixir source code is required.

The Kernel product is currently run from a source checkout with Elixir and Mix.
A standalone macOS command and Docker image are planned for a later 0.x release
from `main`.

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
├── orders.lisp
└── orders.json
```

The manifest selects a PTC-Lisp component, its public entry function, and the
input file:

```json
{
  "version": 1,
  "workflow": {
    "components": [
      {"id": "tutorial.orders", "path": "orders.lisp"}
    ],
    "entry": "tutorial.orders/summarize"
  },
  "input": {"path": "orders.json"},
  "labels": {
    "name": "tutorial-orders",
    "tags": {"mode": "deterministic"}
  }
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
  --trace tmp/tutorial-traces/orders.jsonl
```

The JSON Lines file records the run, workflow evaluation, outcome, usage, and
limits. Query the captured directory through the fixed log-analysis profile:

```console
mix ptc.repl \
  --profile log-analysis-v1 \
  --resource traces=tmp/tutorial-traces \
  -e '(log/runs {})'
```

The profile receives an immutable capture and has no filesystem, network,
model, private-inspection, or nested-evaluation authority.

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

- [Building agents](building-agents.md) explains model calls and confined
  model-authored mission programs.
- [Manifests and capabilities](manifests-and-capabilities.md) documents the
  declarative authority boundary.
- [Running and debugging](running-and-debugging.md) covers traces, private
  inspection, the REPL, and the development Viewer.
- [PTC-Lisp specification](../ptc-lisp-specification.md) and
  [function reference](../function-reference.md) define the language surface.
