# Agentic Aggregator Spike

## Goal

Get a quick signal on whether an MCP-server-internal planner LLM is
worth pursuing. The question is not "can we ship multi-turn memory
now?" It is:

> Given plain English plus the aggregator catalog, can a cheap model
> generate executable PTC-Lisp that reduces large upstream MCP results
> better than asking the MCP client model to do it?

## Spike artifact

Runnable harness:

```bash
cd mcp_server
mix run --no-start bench/agentic_aggregator_spike.exs \
  --runs=3 \
  --model=gemini-flash-lite \
  --report=../tmp/agentic-aggregator-spike.md
```

The harness loads the nearest `.env` via `PtcRunner.Dotenv.load/0`.
`gemini-flash-lite` is the existing alias for
`openrouter:google/gemini-3.1-flash-lite-preview`; the provider call
uses OpenRouter and `OPENROUTER_API_KEY`.

Local harness smoke test, no network/model:

```bash
cd mcp_server
mix run --no-start bench/agentic_aggregator_spike.exs --provider=stub
```

The harness uses a deterministic in-process fake GitHub MCP upstream.
That isolates the variable we care about first: planner-generated
PTC-Lisp quality. Real GitHub/network behavior should be a second
spike only if this clears the basic bar.

## What It Measures

- planner call latency
- planner prompt bytes
- generated program bytes
- execution status
- upstream call count
- result bytes
- rough token usage if the provider returns usage metadata
- simple answer quality checks for the GitHub auth/OAuth task

## Pass Bar

Run the same task 3-5 times with the candidate cheap model. Continue
only if most runs satisfy:

- generated PTC-Lisp executes without repair
- final answer includes the expected auth/OAuth issues
- noisy body-only matches are excluded
- result stays under 1 KB
- upstream calls are used
- trace/report contains the generated program for debugging

## Interpretation

Positive signal means an opt-in `ptc_task` mode is worth a real design:
plain-English task in, internal model generates PTC-Lisp, server
executes through the existing sandbox, and returns compact result plus
trace/program metadata.

Negative signal means keep investing in deterministic code mode:
better catalog response hints, better schema guidance, and fewer
first-call repair loops for client-authored PTC-Lisp.

## Boundaries

This spike deliberately avoids:

- production MCP tool changes
- persistent memory
- real upstream network calls
- hidden global session state
- sending real user/upstream secrets to the model

Those are design questions after the first signal, not prerequisites
for the signal.

## First Result

Run:

```bash
cd mcp_server
mix run --no-start bench/agentic_aggregator_spike.exs \
  --runs=3 \
  --model=gemini-flash-lite \
  --report=../tmp/agentic-aggregator-spike.md
```

Result with `OPENROUTER_API_KEY` loaded from `.env`:

- provider: `openrouter`
- alias: `gemini-flash-lite`
- resolved model: `openrouter:google/gemini-3.1-flash-lite-preview`
- pass rate: `3/3`
- planner latency: roughly `1.2-1.8s`
- generated programs: `430-925` bytes
- upstream calls: `1-2`
- final result preview: `309` bytes

Initial runs failed until the fake GitHub upstream sort was fixed. The
failure was in the harness, not the model: ISO timestamp strings were
being sorted with a `DateTime` sorter. After changing that to string
descending sort, the same strict prompt produced passing runs.

Signal: worth continuing to a real design spike, but keep it opt-in.
The planner needed hard guidance to use
`(json/parse-string (mcp/text r))` for `search_issues`; broad guidance
around `(mcp/json r)` was not enough.
