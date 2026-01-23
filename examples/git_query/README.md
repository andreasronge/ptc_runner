# Git Query

Query git repositories with natural language questions using PtcRunner.

## Overview

This example demonstrates PtcRunner's two-agent composition pattern:

```
User Question → Explorer Agent (PTC-Lisp) → Synthesizer Agent (JSON) → Answer
                      ↓
              Git Tools (Elixir)
```

**Why this demonstrates PTC-Lisp value:**
- Explorer agent decides tool strategy based on question semantics
- Combines/filters results programmatically (not just single tool calls)
- Structured output feeds into synthesis agent
- Composition over multi-turn - clean, predictable pipeline

## Setup

```bash
cd examples/git_query
mix deps.get
```

Ensure you have an `OPENROUTER_API_KEY` in your `.env` file at the ptc_runner root.

## Usage

### Command Line

```bash
# Query the current repository
mix git.query "Who contributed most this month?"

# Query a specific repository
mix git.query "What files changed the most?" --repo /path/to/repo

# Enable debug output to see agent traces
mix git.query "Show commits from last week" --debug
```

### Programmatic

```elixir
# Query with defaults
{:ok, answer} = GitQuery.query("Who contributed most this month?")

# With options
{:ok, answer} = GitQuery.query("What changed in lib/auth?",
  repo: "/path/to/repo",
  debug: true
)
```

## Example Questions

- "Who contributed most this month?"
- "What files changed the most recently?"
- "Show Alice's recent commits"
- "What's the history of lib/sub_agent.ex?"
- "What changed last week?"
- "Who worked on tests this month?"

## Architecture

### Tools (`lib/git_query/tools.ex`)

Safe, read-only git command wrappers:

| Tool | Purpose |
|------|---------|
| `get_commits` | Commit history with filters |
| `get_author_stats` | Commit counts by author |
| `get_file_stats` | Most frequently changed files |
| `get_file_history` | History for a specific file |
| `get_diff_stats` | Line changes between refs |

### SubAgents (`lib/git_query/sub_agents.ex`)

**Explorer (PTC-Lisp, max_turns: 3)**
- Analyzes question to determine tool strategy
- Calls tools and combines results
- Returns structured findings

**Synthesizer (JSON, max_turns: 1)**
- Converts findings to natural language
- No tools - pure synthesis
