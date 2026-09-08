# Adaptive web parser

A web page changes and an old CSS parser returns no records. A small PTC agent
reads the failure evidence, proposes new selectors, and PtcRunner renders those
selectors into a fixed parser component. The candidate is accepted only after it
works on both the failed page and a second, held-out page.

The default demo replays a recorded model conversation, so it needs no LLM key.
It still runs a real local website, `ptc-web`, component materialization, and the
browser checks:

```console
ptc init adaptive-parser --example adaptive-web-parser
cd adaptive-parser
node run.mjs
```

Node 20+, Playwright Chromium, and `ptc` must be installed. The driver installs
the pinned `ptc-web@0.1.0` package in its private artifact directory. If Chromium is missing, run
`npx -y playwright@1.63.0 install chromium` once.

## What is happening

`query.ptc.json` is the normal path. It can use only the read-only browser MCP
server; it has no model. Its initial `site.recipe` contains selectors for the old
page. When those selectors return nothing, `repair.ptc.json` starts an agent in a
separate evidence mission. The agent can see two small functions:

- `repair.evidence/failure` — the failed contract, old selectors, and empty result
- `repair.evidence/current-page` — bounded HTML captured after the failure

The model returns selector data, not executable code. `workflow.clj` inserts that
data into a fixed component template. `ptc materialize` checks the replacement
against the original component hash, and the driver validates it before running
the original and held-out pages. Later queries use the accepted component and
make zero model calls.

Replay is exact: if the prompt or model-visible evidence changes, its request hash
no longer matches `replay.jsonl` and the run stops. To try a real model instead:

```console
node run.mjs --live /absolute/path/to/.env
```

The env file must provide `OPENROUTER_API_KEY`. Live output is variable and may
cost money.

This is a toy problem with tiny pages and known answers. It demonstrates the
boundary, not a production self-healing scraper: deterministic code does routine
work, a model is called only after a measurable failure, and deterministic checks
decide whether its proposal is promoted. The same pattern can repair parsers for
documents, logs, messages, API payloads, or other changing semi-structured data.

The larger [`ptc-web` experiment](https://github.com/andreasronge/ptc-web/tree/main/examples/ptc/repair-loop)
uses PTC's private debug navigation over raw run artifacts, multiple layout
changes, retry policy, and detailed measurements.
