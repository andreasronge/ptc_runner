# Testing Usage Rules

Testing PtcRunner code is straightforward because the LLM is just a 1-arity
function — pass an inline lambda in tests. There is **no** built-in
`stub`/`mock`/`fake` helper, and you don't need one.

## The fundamental pattern

```elixir
test "single-shot returns the program result" do
  llm = fn _request -> {:ok, "(+ 1 2)"} end

  {:ok, step} = PtcRunner.SubAgent.run("Compute", max_turns: 1, llm: llm)

  assert step.return == 3
end
```

The LLM callback receives `%{system: ..., messages: [...]}` and may return
either `{:ok, raw_text}` (wrapped internally) or
`{:ok, %{content: text, tokens: ...}}`. Raw s-expressions parse fine; you can
also wrap in a ```` ```clojure ```` fence (matches what real LLMs emit).

## Scripted (multi-turn) callbacks

For loop-mode tests, script a sequence of responses keyed by turn:

```elixir
defmodule MyApp.TestLLM do
  def scripted(programs) do
    {:ok, agent_pid} = Agent.start_link(fn -> 0 end)

    fn _input ->
      turn = Agent.get_and_update(agent_pid, fn n -> {n, n + 1} end)
      program = Enum.at(programs, turn) || List.last(programs)
      {:ok, "```clojure\n#{program}\n```"}
    end
  end
end

test "agent searches then returns" do
  llm = MyApp.TestLLM.scripted([
    # Turn 1: store results in memory under `results`
    ~S|(def results (tool/search {:query "test"}))|,
    # Turn 2: read from memory and return
    ~S|(return {:count (count results)})|
  ])

  {:ok, step} = PtcRunner.SubAgent.run("Search and count",
    signature: "{count :int}",
    tools:     %{"search" => fn _args -> [%{id: 1}, %{id: 2}] end},
    llm:       llm
  )

  assert step.return["count"] == 2
end
```

Tool results are **not** automatically bound to `data/<name>` — the program
must capture them with `(def ...)` (or just compose them inline in one turn).

Use `Agent` (not `:counters` or `:ets`) so the test cleans up automatically.

## What to test where

| Layer | Approach |
|-------|----------|
| **Tools** | Plain ExUnit. Tools are functions — call them directly. |
| **Prompt expansion** | `SubAgent.preview_prompt(agent, context: %{...})` returns the rendered system + user messages. Snapshot-test these. |
| **Agent end-to-end** | Scripted LLM + real tools. Exercise the loop without paying for tokens. |
| **Provider integration** | `@tag :integration` with a real model alias, gated on env. |

Don't write unit tests that just mirror function bodies. Prefer integration
tests that exercise the loop with a scripted LLM and real tools.

## Inspecting failures

```elixir
{result, step} = PtcRunner.SubAgent.run(agent, llm: llm)

# See every turn — generated program, tool calls, return value
PtcRunner.SubAgent.Debug.print_trace(step)

# Include raw LLM output (commentary outside the fence)
PtcRunner.SubAgent.Debug.print_trace(step, raw: true)

# Show full messages sent to the LLM each turn
PtcRunner.SubAgent.Debug.print_trace(step, messages: true)
```

In assertions, prefer `step.return` and `step.fail.reason` over poking at
internal turn structures — those are not part of the public contract.

## Real LLM tests (gated)

```elixir
@tag :integration
test "real model returns valid JSON" do
  {:ok, step} = PtcRunner.SubAgent.run("Classify: I love it",
    output:    :text,
    signature: "{sentiment :string, score :float}",
    llm:       "haiku"
  )

  assert step.return["sentiment"] in ~w[positive neutral negative]
end
```

Run with `mix test --include integration` and require an env var
(`OPENROUTER_API_KEY`, etc.) to be present.

## Don't

- Don't use `Process.sleep/1` to wait for streaming or async work — use
  `assert_receive` with a timeout.
- Don't `Process.put` test state into the LLM callback closure; pass it via
  the closure or a test-scoped `Agent`.
- Don't mock `PtcRunner.Lisp.run/2` or `PtcRunner.Sandbox.execute/3`. They're
  fast and deterministic — running them is more reliable than mocking them.
- Don't put domain-specific hints in `prompt`/`system_prompt` that "happen to"
  steer the LLM toward the test's expected answer. The orchestration layer
  must be domain-blind.
