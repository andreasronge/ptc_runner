# Getting started

The [Quickstart](quickstart.md) already took the shortest useful path: create a
provider-free hello world, then let a live model write and run a program. This
guide slows down and explains the files, result, trace, and REPL without making
another model request.

PTC-Lisp is an eager, bounded Clojure subset with additions such as `return`,
`fail`, capability calls, and `*1`/`*2`/`*3` continuation history. It excludes
arbitrary JVM access, macros, lazy or infinite sequences, and ambient file,
network, or process access. The
[language specification](../ptc-lisp-specification.md) is authoritative.

The checkout command is `mix ptc`; a runtime-included release uses `bin/ptc`.

## Create the three application files

If you completed the Quickstart, `hello-ptc` already exists and you can skip
this setup block. When starting here from a fresh clone, fetch dependencies
before the first Mix command:

```console
mix deps.get
mix ptc init hello-ptc
```

Initialization creates `main.clj`, the application manifest `ptc.json`, and an
operator-owned `ptc-project.json` that remembers paths and local artifact
choices. It refuses to merge with or overwrite an existing path.

Run the generated project:

```console
mix ptc run hello-ptc/ptc-project.json
```

```json
{}
```

The entry function simply returns its input:

```clojure
(ns main)

(defn run [input]
  (return input))
```

The application manifest selects that component and entry and supplies an empty
input object:

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

The project document points at the manifest and enables a private local `.ptc`
artifact layout. [Project configuration](project-configuration.md) documents
its host, environment, artifact, override, and Viewer fields.

## Run a workflow with data

The credential-free orders example uses the same file roles with a more useful
input and result:

<!-- ptc-guide-e2e: id=getting-started-orders project=examples/kernel-tutorial/01-orders.ptc-project.json -->
```console
mix ptc run examples/kernel-tutorial/01-orders.ptc-project.json
```

```json
{"order_count":3,"paid_count":2,"paid_total":335.75,"pending_ids":["A-101"]}
```

Its project document points to three application files:

```text
examples/kernel-tutorial/
├── 01-orders.ptc-project.json
└── 01-orders/
    ├── ptc.json
    ├── orders.clj
    └── orders.json
```

The manifest selects the component, public entry, and input file:

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
workflow failure. A function that finishes normally without either produces an
ordinary Lisp value, which is useful during intermediate agent turns and in the
REPL.

## Read the result and trace

The project enables a command envelope and canonical trace named with the
unique run reference. They appear under
`examples/kernel-tutorial/01-orders/.ptc`; a later run does not replace an
earlier one.

Open the local Viewer:

```console
mix ptc.viewer examples/kernel-tutorial/01-orders.ptc-project.json
```

Or query one frozen trace-directory capture through the public analysis
profile:

```console
mix ptc repl \
  --profile run-analysis-v1 \
  --resource traces=examples/kernel-tutorial/01-orders/.ptc/traces \
  -e '(analysis/runs {"limit" 50})'
```

The profile can discover runs and page sanitized canonical activity. It has no
filesystem, network, model, private-inspection, or nested-evaluation authority.
The [Kernel REPL guide](kernel-repl.md#query-public-traces) owns the complete
analysis walkthrough.

## Try the language directly

Use the bounded REPL for small expressions and definitions:

```console
mix ptc repl \
  -e '(def tax-rate 0.2)' \
  -e '(* 100 tax-rate)' \
  -e '(+ *1 5)'
```

Successful definitions and the three most recent values persist for one
session. A failed form leaves that state untouched.

## Next steps

Continue in this order:

1. [Building agents](building-agents.md) starts with the shipped working loop,
   then explains workflow/mission separation and replaceable prompt policy.
2. [Connecting tools with MCP](connecting-tools-with-mcp.md) gives generated
   programs one narrow external tool.
3. [Manifests and capabilities](manifests-and-capabilities.md) defines the
   declarative application boundary.
4. [Host configuration](host-configuration.md) defines the operator-owned
   provider installation behind selected aliases.
5. [Running and debugging](running-and-debugging.md) covers every command,
   failure contract, private inspection, and the development Viewer.

The [function reference](../function-reference.md) inventories the complete
PTC-Lisp surface.
