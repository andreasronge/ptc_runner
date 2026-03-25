# Trace Analyzer

An agentic tool that uses ptc_runner to investigate its own execution traces. Ask natural language questions about agent runs and get explanations backed by structured trace data.

## Quick Start

```bash
# From demo/
mix trace_analyze "Which traces are available and which ones failed?"

# Point at a specific trace directory
mix trace_analyze "Why did the planned condition use more tokens?" --trace-dir traces

# Verbose mode shows turns and token usage
mix trace_analyze "Compare the two most recent traces" -v
```

## Usage

```
mix trace_analyze "your question" [options]

Options:
  --trace-dir, -d   Directory containing .jsonl traces (default: traces)
  --max-turns        Maximum agent turns (default: 8)
  --verbose, -v      Show debug output (turns, tokens)
```

### Programmatic

```elixir
{:ok, step} = PtcDemo.TraceAnalyzer.Agent.ask(
  "Find traces where budget was exhausted",
  trace_dir: "traces"
)

IO.puts(step.return)
```

## How It Works

The trace analyzer is a multi-turn SubAgent (PTC-Lisp mode) with four tools. The agent writes PTC-Lisp code to call tools, inspect results, and build an answer across multiple turns.

### Tool Layers

**Cheap metadata tools** — use these first to orient:

| Tool | Purpose |
|------|---------|
| `list_traces` | List available traces with status, turns, tokens. Filter by status, filename substring, or limit. |
| `trace_summary` | Per-turn breakdown of a trace: programs, results, tool calls, errors, token usage. |

**Expensive inspection tools** — drill down when needed:

| Tool | Purpose |
|------|---------|
| `turn_detail` | Full detail for one turn: program code, tool call args, prints, result. Optional `include_messages: true` for full LLM prompts. |
| `diff_traces` | Compare two traces: token/turn deltas, tool sequence match, first point of divergence. |

The tools call `PtcRunner.TraceLog.Analyzer` under the hood — the LLM never parses raw JSONL.

### Investigation Flow

The system prompt guides the agent toward a cheap-first exploration strategy:

1. `list_traces` to find relevant files
2. `trace_summary` for overview
3. `turn_detail` only when specific code or errors matter
4. `diff_traces` for comparing runs

### Example Questions

```bash
# Overview
mix trace_analyze "List all traces and summarize pass/fail rates"

# Debugging
mix trace_analyze "Why did this run take 3 turns instead of 1?"
mix trace_analyze "Show me what happened on turn 2 of the latest failed trace"

# Comparison
mix trace_analyze "Compare the planned and direct executor traces"
mix trace_analyze "What's different between the planner trace and the executor trace?"

# Efficiency
mix trace_analyze "Which trace used the most tokens and why?"
mix trace_analyze "Find traces where the same tool was called multiple times"
```

## Trace Files

Traces are JSONL files written by `PtcRunner.TraceLog`. Each line is a JSON event:

- `trace.start` / `trace.stop` — envelope with metadata and total duration
- `run.start` / `run.stop` — agent execution with final status and usage
- `turn.start` / `turn.stop` — per-turn program, result, token counts
- `llm.start` / `llm.stop` — LLM call with messages and response
- `tool.start` / `tool.stop` — tool invocations with args and results

The trace analyzer generates its own traces (prefixed `analyzer_`) so you can inspect how the analyzer itself works.

## Generating Traces

Any SubAgent run wrapped in `TraceLog.with_trace` produces traces. The demo benchmark generates them automatically:

```bash
# Run planning benchmark (generates traces in demo/traces/)
mix planning --conditions=direct,planned,specified --tests=25 --runs=1

# Then analyze
mix trace_analyze "Summarize what happened in each trace" --trace-dir traces
```
