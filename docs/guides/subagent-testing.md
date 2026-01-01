# Testing SubAgents

Strategies for testing SubAgent-based code: mocking LLMs, testing tools, and integration testing.

## Prerequisites

- Basic familiarity with [SubAgents](subagent-getting-started.md)
- ExUnit testing knowledge

## Overview

SubAgents have three testable layers:

| Layer | What to Test | Approach |
|-------|--------------|----------|
| **Tools** | Business logic | Unit tests, no LLM needed |
| **Prompts** | Template expansion | Snapshot with `preview_prompt/2` |
| **Integration** | Full agent behavior | Mock or real LLM (gated) |

Test tools extensively, snapshot prompts for regression, use integration tests sparingly.

## Mocking the LLM Callback

The LLM callback is a function. Create mocks in a test helper module:

```elixir
defmodule MyApp.TestHelpers do
  @doc "Mock LLM that returns a fixed PTC-Lisp program"
  def mock_llm(program) do
    fn _input -> {:ok, "```clojure\n#{program}\n```"} end
  end

  @doc "Mock LLM that returns programs in sequence (for multi-turn)"
  def scripted_llm(programs) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    fn _input ->
      turn = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      program = Enum.at(programs, turn, List.last(programs))
      {:ok, "```clojure\n#{program}\n```"}
    end
  end
end
```

Usage:

```elixir
test "finds maximum value" do
  mock = TestHelpers.mock_llm("(return {:max 42})")

  {:ok, step} = SubAgent.run(
    "Find the maximum",
    signature: "{max :int}",
    llm: mock
  )

  assert step.return.max == 42
end

test "multi-turn agent" do
  mock = TestHelpers.scripted_llm([
    "(call \"search\" {:query \"test\"})",
    "(return {:count (count ctx/results)})"
  ])

  {:ok, step} = SubAgent.run(
    "Search and count",
    signature: "{count :int}",
    tools: %{"search" => fn _ -> [%{id: 1}, %{id: 2}] end},
    llm: mock
  )

  assert step.return.count == 2
end
```

## Testing Tools in Isolation

Tools are regular functions—test them directly without SubAgent:

```elixir
describe "search/1" do
  test "returns matching items" do
    result = MyApp.Tools.search(%{query: "urgent", limit: 5})

    assert is_list(result)
    assert length(result) <= 5
  end

  test "returns empty list for no matches" do
    assert MyApp.Tools.search(%{query: "nonexistent"}) == []
  end
end
```

## Snapshot Testing with preview_prompt/2

Test prompt generation without calling the LLM:

```elixir
test "system prompt includes expected sections" do
  agent = SubAgent.new(
    prompt: "Find urgent emails for {{user}}",
    signature: "{count :int}",
    tools: %{"list_emails" => &MyApp.Email.list/1}
  )

  preview = SubAgent.preview_prompt(agent, context: %{user: "alice@example.com"})

  assert preview.system =~ "list_emails"
  assert preview.user =~ "alice@example.com"
end
```

For regression testing, compare against stored snapshots. See `PtcRunner.SubAgent.preview_prompt/2` for details.

## Integration Testing

Gate real LLM tests—they're slow and non-deterministic:

```elixir
defmodule MyApp.SubAgentIntegrationTest do
  use ExUnit.Case

  @moduletag :e2e

  setup do
    case System.get_env("OPENROUTER_API_KEY") do
      nil -> {:ok, skip: true}
      key -> {:ok, llm: MyApp.LLM.openrouter(key)}
    end
  end

  @tag :e2e
  test "email finder returns valid structure", %{llm: llm} do
    {:ok, step} = SubAgent.run(
      "Find the most recent email",
      signature: "{subject :string, from :string}",
      tools: %{"list_emails" => &MyApp.Email.list_mock/1},
      llm: llm
    )

    assert is_binary(step.return.subject)
  end
end
```

Run with `mix test --include e2e`. Use `temperature: 0.0` for more deterministic results.

## Testing Error Paths

```elixir
test "returns error when agent calls fail" do
  mock = TestHelpers.mock_llm("(fail {:reason :not_found})")

  {:error, step} = SubAgent.run("Find something", signature: "{id :int}", llm: mock)

  assert step.fail.reason == :not_found
end

test "fails when max_turns exceeded" do
  mock = TestHelpers.mock_llm("(+ 1 1)")  # Never returns

  {:error, step} = SubAgent.run(
    "Loop forever",
    signature: "{result :int}",
    max_turns: 3,
    llm: mock
  )

  assert step.fail.reason == :max_turns_exceeded
end
```

Other error scenarios follow the same pattern: validation errors (wrong return type), tool errors (`{:error, reason}`). The agent receives error feedback and can retry or fail gracefully.

## See Also

- [Getting Started](subagent-getting-started.md) - Build your first SubAgent
- `PtcRunner.SubAgent` - API reference (all options)
- `PtcRunner.Step` - Result struct reference
