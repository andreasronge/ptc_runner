# Gap Analyzer Example, work in progress

A compliance gap analysis tool demonstrating **Elixir-driven investigation** with single-shot SubAgents and workspace-based state management.

## The Pattern

```
┌─────────────────────────────────────────────────────────────┐
│                    Elixir Investigation Loop                 │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│  │ Discovery │───►│Investigate│───►│ Summarize│              │
│  │  Agent   │    │   Agent   │    │   Agent  │              │
│  │(single)  │    │ (batch)   │    │ (single) │              │
│  └──────────┘    └────┬─────┘    └──────────┘              │
│                       │                                      │
│                       ▼                                      │
│              ┌────────────────┐                             │
│              │   Workspace    │  ← State persists here      │
│              │  (Elixir Agent)│    not in LLM context       │
│              └────────────────┘                             │
└─────────────────────────────────────────────────────────────┘
```

## Why This Pattern?

| Problem | Solution |
|---------|----------|
| Multi-turn fills context with old programs | Single-shot agents, fresh context each call |
| Can't fit large documents in context | Search/retrieve pattern (summaries vs full text) |
| State lost between agents | Workspace stores findings in Elixir |
| Unpredictable LLM orchestration | Elixir controls the loop, LLM does focused analysis |

## Key Concepts

### 1. Elixir Drives the Loop

```elixir
def investigate_loop(remaining, batch_size, llm) do
  pending = Workspace.get_pending(batch_size)

  case investigate_batch(pending, llm) do
    {:ok, findings, follow_ups} ->
      Workspace.save_findings(findings)
      Workspace.add_pending(discover_follow_ups(follow_ups, llm))
      investigate_loop(remaining - 1, batch_size, llm)
    ...
  end
end
```

### 2. Single-Shot SubAgents

Each agent does one focused task with fresh context:

```elixir
# No history accumulation - max_turns: 1
SubAgent.new(
  prompt: "Investigate these requirements: {{pending}}",
  max_turns: 1,  # Single shot
  tools: search_tools
)
```

### 3. Workspace State Management

```elixir
# State lives in Elixir, not LLM context
Workspace.add_pending(requirements)
Workspace.save_findings(findings)
Workspace.get_pending(batch_size)
```

### 4. Search/Retrieve Pattern

Simulates large documents with limited context access:

```elixir
# Search returns summaries (small)
search_regulations(%{query: "encryption"})
#=> [%{id: "REQ-1.1", title: "...", summary: "..."}]

# Retrieve returns full text (one at a time)
get_regulation(%{id: "REQ-1.1"})
#=> %{id: "REQ-1.1", full_text: "... detailed requirements ..."}
```

## Installation

```bash
cd examples/gap_analyzer
mix deps.get
```

## Usage

```bash
# Analyze requirements starting from a topic
mix gap.analyze --topic encryption

# Analyze all requirements
mix gap.analyze --all

# With debug output
mix gap.analyze --debug

# Control iterations and batch size
mix gap.analyze --iterations 5 --batch 2
```

## Project Structure

```
gap_analyzer/
├── lib/
│   ├── gap_analyzer.ex         # Main API + Elixir investigation loop
│   └── gap_analyzer/
│       ├── workspace.ex        # Agent-based state storage
│       ├── data.ex             # Simulated large documents (chunked)
│       ├── tools.ex            # Search/retrieve tools
│       ├── sub_agents.ex       # Single-shot SubAgent definitions
│       └── env.ex              # .env loader
└── mix.exs
```

## How It Works

### Phase 1: Discovery
```
SubAgent searches for requirements related to topic
  → Returns list of {id, title, summary}
  → Added to Workspace.pending
```

### Phase 2: Investigation Loop
```
While pending items exist:
  1. Get batch of pending items from Workspace
  2. SubAgent investigates (search policy, retrieve details, analyze)
  3. Returns findings + follow-up topics
  4. Workspace.save_findings(findings)
  5. Workspace.add_pending(follow_ups)
  6. Repeat until done or max iterations
```

### Phase 3: Summary
```
SubAgent compiles findings into executive report
  → Critical gaps, recommendations, stats
```

## When to Use This Pattern

✅ **Good fit:**
- Processing many items in batches
- Large documents requiring search/retrieve
- State needs to persist across many LLM calls
- Predictable, controlled workflow

❌ **Use multi-turn PTC-Lisp instead when:**
- Workflow must adapt based on LLM reasoning
- Single task requiring back-and-forth exploration
- Small context, no state persistence needed
