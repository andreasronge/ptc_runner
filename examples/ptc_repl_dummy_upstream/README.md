# Dummy Upstream For `mix ptc.repl`

This example runs a tiny local HTTP JSON server and exposes it to PTC-Lisp
through the root upstream runtime using the OpenAPI transport.

## 1. Start The Dummy Server

From the repository root:

```bash
mix run examples/ptc_repl_dummy_upstream/server.exs
```

The server listens on `http://127.0.0.1:4017` and implements:

```http
GET /echo?message=hello
```

## 2. Start The REPL

In another terminal, from the repository root:

```bash
mix ptc.repl --upstreams-config examples/ptc_repl_dummy_upstream/upstreams.json
```

Try these forms:

```clojure
(tool/servers)
(dir 'dummy)
(doc 'dummy/echo)
(tool/call 'dummy/echo {:message "hello from ptc"})
```

The tool call should return a tagged PTC-Lisp value similar to:

```clojure
{:ok true :value {"echo" "hello from ptc" "path" "/echo"} :value_kind :json}
```

## One-Shot Eval

You can also call the upstream without opening the interactive REPL:

```bash
mix ptc.repl --upstreams-config examples/ptc_repl_dummy_upstream/upstreams.json \
  -e "(tool/call 'dummy/echo {:message \"hello\"})"
```

## Files

- `server.exs` is the local dummy HTTP server.
- `openapi.json` describes the single `echo` operation.
- `upstreams.json` configures the root upstream runtime.
