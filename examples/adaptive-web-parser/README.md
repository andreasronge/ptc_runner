# Adaptive web parser

A web page changes and an old CSS parser returns no records. One PTC workflow
detects the failure, asks an evidence mission for new selectors, writes a small
`candidate.clj` program, and evaluates it in a browser mission. The program is
accepted only after it works on both the failed page and a held-out page.

The default demo replays a recorded model conversation, so it needs no LLM key.
It still runs a real local website plus the `ptc-web` and `ptc-fs-mcp` servers:

```console
ptc init adaptive-parser --example adaptive-web-parser
cd adaptive-parser
node run.mjs
```

Node 20+, Playwright Chromium, and `ptc` must be installed. The driver installs
the pinned MCP packages in its private artifact directory. If Chromium is
missing, run `npx -y playwright@1.63.0 install chromium` once.

## What is happening

`workflow.clj` first evaluates the installed parser in the browser mission. That
mission can use only the read-only browser MCP server; it has no model. When the
old selectors return nothing, the same workflow starts an agent in a separate
evidence mission. The agent can see two small functions:

- `repair.evidence/failure` — the failed contract, old selectors, and empty result
- `repair.evidence/current-page` — bounded HTML captured after the failure

The model returns selector data. Trusted workflow code renders it as a small,
terminal PTC-Lisp program. A third mission writes `candidate.clj` through a
`ptc-fs-mcp` server confined to the demo's private temporary directory. The
workflow reads it back, checks it, and evaluates it in the browser mission. A
crash becomes a rejected subordinate evaluation; it cannot escape that mission
or acquire filesystem access. Passing both pages writes the same source as
`accepted.clj`. A second run reads and evaluates that file with zero model calls.

The Node driver only starts the local fixture, installs the two pinned MCP
packages, and invokes the same PTC application twice. The repair decision,
sandboxed candidate execution, verification, and adoption all happen in
PtcRunner.

Replay is exact: if the prompt or model-visible evidence changes, its request hash
no longer matches `replay.jsonl` and the run stops. To try a real model instead:

```console
node run.mjs --live /absolute/path/to/.env
```

The env file must provide `OPENROUTER_API_KEY`. Live output is variable and may
cost money.

This is a toy problem with tiny pages and known answers. It demonstrates the
boundary, not a production self-healing scraper: deterministic code does routine
work, a model is called only after a measurable failure, and untrusted generated
code runs with narrow tools before deterministic checks adopt it. The same
pattern can repair parsers for documents, logs, messages, API payloads, or other
changing semi-structured data.

The larger [`ptc-web` experiment](https://github.com/andreasronge/ptc-web/tree/main/examples/ptc/repair-loop)
uses PTC's private debug navigation over raw run artifacts, multiple layout
changes, retry policy, and detailed measurements.
