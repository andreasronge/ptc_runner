# Parallel Search Example

A minimal example demonstrating parallel tool execution in PTC-Lisp.

## Concept: Parallel Execution with `pcalls`

PTC-Lisp's `pcalls` executes thunks concurrently:

```clojure
(let [results (pcalls #(ctx/grep {:pattern "defmodule"})
                      #(ctx/grep {:pattern "defstruct"}))]
  (apply concat results))
```

This runs both grep searches in parallel, then combines the results.

## Key Differences from code_scout

| Aspect | code_scout | parallel_search |
|--------|-----------|-----------------|
| Mode | Multi-turn (LLM loop) | Single-shot (no LLM) |
| Execution | Sequential tool calls | Parallel with `pcalls` |
| Complexity | Full SubAgent | Direct `Lisp.run/2` |

## Installation

```bash
cd examples/parallel_search
mix deps.get
```

## Usage

Start IEx:

```bash
iex -S mix
```

Then run searches:

```elixir
# Search for multiple patterns in parallel
ParallelSearch.search(["defmodule", "defstruct", "@spec"])

# Single pattern search
ParallelSearch.grep("eval")
```

Or as a one-liner:

```bash
mix run -e 'ParallelSearch.search(["defmodule", "defstruct"]) |> IO.inspect()'
```

## How It Works

The `search/1` function:

1. Builds a `pcalls` expression dynamically from the pattern list
2. Runs it with `Lisp.run/2` (no LLM involved)
3. Each grep runs concurrently in the BEAM sandbox
4. Results are combined with `concat`

```clojure
;; For patterns ["defmodule", "defstruct"], generates:
(let [results (pcalls #(ctx/grep {:pattern "defmodule"})
                      #(ctx/grep {:pattern "defstruct"}))]
  (apply concat results))
```

## When to Use Each Approach

- **Single-shot (`Lisp.run/2`)**: When you know the exact operations upfront
- **Multi-turn (`SubAgent.run/2`)**: When the LLM needs to decide what to do next
