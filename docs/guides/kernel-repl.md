# Kernel REPL

`mix ptc.repl` is a small direct PTC-Lisp frontend. Successful evaluations
retain definitions and the last one to three results for `*1`, `*2`, and `*3`.
Failed evaluations do not commit memory.

```bash
mix ptc.repl
mix ptc.repl -e '(def x 40)' -e '(+ x 2)' -e '(+ *1 1)'
mix ptc.repl -l setup.lisp
mix ptc.repl script.lisp
mix ptc.repl - < script.lisp
```

Use the same strict manifest as `mix ptc.run` to attach a frozen workflow
bundle, workflow capabilities, limits, input, labels, and event policy:

```bash
mix ptc.repl --manifest ptc.json
mix ptc.repl --manifest ptc.json -e '(workflow/helper data/input)'
```

The REPL does not accept legacy upstream catalogs, mutable prelude selections,
or a special log prelude. Providers and component sources are selected only by
the manifest and trusted provider registry.

Every session emits canonical Kernel events. Persist them as bounded,
append-only JSONL with:

```bash
mix ptc.repl --trace trace.jsonl
mix ptc.repl --manifest ptc.json --trace trace.jsonl
```

Private event policies require an explicit private manifest selection; the
REPL requires the reserved `.private.jsonl` suffix and restricts the file to
owner read/write permissions before appending event data. Normal directory
grants and the viewer do not discover private-suffixed traces.
The resulting file uses the same `Kernel.TraceLog` loader and query semantics
as `log.core` and the viewer integration.
