# Tool-compiler lab

A maintainer lab, not a shipped example. It measures what a model spends when
it drives raw MCP tools itself, so that a compiled domain tool has a baseline to
beat.

The question is whether compiling a domain tool from observed usage pays for
itself. Arm A here is the control: the model gets the six raw `ptc-web` page
tools and no domain knowledge at all. Arm B, when it exists, replaces the one
mission component with a compiled tool and runs the same tasks.

## What it measures

Per page, from the canonical trace and the V4 command envelope:

- `calls` — `capability-started` events for `web.*`, so how many round trips the
  page cost.
- `model` — `llm-request` capability events, so how many turns the loop took.
- `in_tokens` / `out_tokens` — from `usage.llm_usage`. Input tokens are the
  honest measure of how much page noise reached the model's context.
- `correct` — whether the records match the fixture exactly.

`arm-a-results.json` keeps the same rows for comparison against Arm B.

## The fixture

`fixture.mjs` serves a quotation board on loopback with three pages:

- `/quotes` — records as `article.entry > p.words` plus a sibling `span.speaker`.
- `/held-out` — the same records nested under `header`/`section`, so a selector
  learned from `/quotes` does not transfer.
- `/ledger` — the `/quotes` shape behind forty filler rows, long enough that one
  `page_read` cannot return the whole page.

Every page carries a `<nav>` with a decoy `.speaker`, so the obvious selector is
wrong.

## Arm A

`passthrough/web.clj` wraps each `ptc-web` tool and nothing else: no
orchestration, selectors, or cursor handling. Its extraction wrapper preserves
the upstream field options (`text`, `html`, attributes, multiple values, and
required fields), caller-selected limits, and pagination cursor. The model must
open, capture, inspect, choose extraction options, follow cursors, extract, and
close. The mission grant in `passthrough/ptc.json` exposes exactly those six
functions.

The result contract requires `{"records": [{"text", "author"}]}`, so an answer
in the wrong shape is a recorded failure rather than a judgement call.

## Running it

```console
node run.mjs --env-file /absolute/path/to/.env
```

Needs Node 20+, npm, `ptc` on PATH, and an `OPENROUTER_API_KEY` in the
environment or that file. The driver installs `ptc-web@0.1.0` into a private
directory under this one and starts the fixture on a random loopback port, so
nothing reaches the public internet.

The model is `openrouter:deepseek/deepseek-v4-flash`, pinned in `ptc-host.json`.
Runs cost real tokens.

The credential-free boundary check installs the same pinned upstream release,
extracts inner HTML through the wrapper, and follows its extraction cursor:

```console
node measurement-check.mjs
node boundary-check.mjs
```
