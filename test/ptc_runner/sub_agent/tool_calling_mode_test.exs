defmodule PtcRunner.SubAgent.ToolCallingModeTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  import PtcRunner.TestSupport.SubAgentTestHelpers, only: [tool_calling_llm: 1]

  @moduletag :tool_calling

  defp make_agent(opts \\ []) do
    defaults = [
      prompt: "Find information",
      signature: "() -> {answer :string}",
      output: :tool_calling,
      tools: %{
        "search" =>
          {fn args -> "result for #{args["q"]}" end,
           signature: "(q :string) -> :string", description: "Search"}
      },
      max_turns: 5
    ]

    SubAgent.new(Keyword.merge(defaults, opts))
  end

  describe "single tool call, single turn" do
    test "LLM calls tool, gets result, returns JSON answer" do
      llm =
        tool_calling_llm([
          # Turn 1: LLM calls search tool
          %{
            tool_calls: [%{id: "call_1", name: "search", args: %{"q" => "elixir"}}],
            content: nil,
            tokens: %{input: 100, output: 50}
          },
          # Turn 2: LLM returns final answer
          %{
            content: ~S|{"answer": "Elixir is great"}|,
            tokens: %{input: 150, output: 30}
          }
        ])

      agent = make_agent()
      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == %{"answer" => "Elixir is great"}
      assert step.usage.input_tokens == 250
      assert step.usage.output_tokens == 80
    end
  end

  describe "multiple tool calls per turn" do
    test "LLM calls 2 tools in one response, both executed" do
      tools = %{
        "search" =>
          {fn args -> "found #{args["q"]}" end,
           signature: "(q :string) -> :string", description: "Search"},
        "count" => {fn _args -> 42 end, signature: "() -> :int", description: "Count items"}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{id: "c1", name: "search", args: %{"q" => "test"}},
              %{id: "c2", name: "count", args: %{}}
            ],
            content: nil,
            tokens: %{input: 100, output: 50}
          },
          %{content: ~S|{"answer": "found 42 items"}|, tokens: %{input: 200, output: 30}}
        ])

      agent = make_agent(tools: tools)
      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == %{"answer" => "found 42 items"}
    end
  end

  describe "multi-turn tool use" do
    test "multiple turns of tool calls before final answer" do
      call_count = :counters.new(1, [:atomics])

      tools = %{
        "lookup" =>
          {fn args ->
             :counters.add(call_count, 1, 1)
             "data_#{args["id"]}"
           end, signature: "(id :string) -> :string", description: "Look up data"}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [%{id: "c1", name: "lookup", args: %{"id" => "a"}}],
            content: nil,
            tokens: nil
          },
          %{
            tool_calls: [%{id: "c2", name: "lookup", args: %{"id" => "b"}}],
            content: nil,
            tokens: nil
          },
          %{content: ~S|{"answer": "combined"}|, tokens: nil}
        ])

      agent = make_agent(tools: tools)
      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == %{"answer" => "combined"}
      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "unknown tool" do
    test "LLM calls non-existent tool, gets error result, recovers" do
      llm =
        tool_calling_llm([
          %{tool_calls: [%{id: "c1", name: "nonexistent", args: %{}}], content: nil, tokens: nil},
          %{content: ~S|{"answer": "recovered"}|, tokens: nil}
        ])

      agent = make_agent()
      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == %{"answer" => "recovered"}
    end
  end

  describe "tool raises error" do
    test "tool function raises, error fed back, LLM adapts" do
      tools = %{
        "failing" =>
          {fn _args -> raise "boom!" end, signature: "() -> :string", description: "Fails"}
      }

      llm =
        tool_calling_llm([
          %{tool_calls: [%{id: "c1", name: "failing", args: %{}}], content: nil, tokens: nil},
          %{content: ~S|{"answer": "handled error"}|, tokens: nil}
        ])

      agent = make_agent(tools: tools)
      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == %{"answer" => "handled error"}
    end
  end

  describe "max_turns exceeded" do
    test "loop terminates with error when max_turns reached" do
      llm =
        tool_calling_llm([
          %{
            tool_calls: [%{id: "c1", name: "search", args: %{"q" => "a"}}],
            content: nil,
            tokens: nil
          },
          %{
            tool_calls: [%{id: "c2", name: "search", args: %{"q" => "b"}}],
            content: nil,
            tokens: nil
          },
          %{
            tool_calls: [%{id: "c3", name: "search", args: %{"q" => "c"}}],
            content: nil,
            tokens: nil
          }
        ])

      agent = make_agent(max_turns: 2)
      {:error, step} = SubAgent.run(agent, llm: llm)

      assert step.fail.reason == :max_turns_exceeded
    end
  end

  describe "max_tool_calls exceeded" do
    test "tool calls skipped after limit, error sent to LLM" do
      tools = %{
        "ping" => {fn _ -> "pong" end, signature: "() -> :string", description: "Ping"}
      }

      llm =
        tool_calling_llm([
          # Try to call 3 tools but limit is 2
          %{
            tool_calls: [
              %{id: "c1", name: "ping", args: %{}},
              %{id: "c2", name: "ping", args: %{}},
              %{id: "c3", name: "ping", args: %{}}
            ],
            content: nil,
            tokens: nil
          },
          %{content: ~S|{"answer": "done"}|, tokens: nil}
        ])

      agent = make_agent(tools: tools, max_tool_calls: 2)
      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == %{"answer" => "done"}
    end
  end

  describe "signature validation" do
    test "invalid final JSON triggers error" do
      llm =
        tool_calling_llm([
          # Return wrong type (number instead of string)
          %{content: ~S|{"answer": 42}|, tokens: nil},
          # Retry with correct type
          %{content: ~S|{"answer": "correct"}|, tokens: nil}
        ])

      agent = make_agent(max_turns: 3)
      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == %{"answer" => "correct"}
    end
  end

  describe "token accumulation" do
    test "tokens are summed across multiple LLM calls" do
      llm =
        tool_calling_llm([
          %{
            tool_calls: [%{id: "c1", name: "search", args: %{"q" => "a"}}],
            content: nil,
            tokens: %{input: 100, output: 20}
          },
          %{content: ~S|{"answer": "done"}|, tokens: %{input: 200, output: 30}}
        ])

      agent = make_agent()
      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.usage.input_tokens == 300
      assert step.usage.output_tokens == 50
      assert step.usage.total_tokens == 350
      assert step.usage.llm_requests == 2
    end
  end

  describe "Step.tool_calls recording" do
    test "all tool calls appear in final Step" do
      llm =
        tool_calling_llm([
          %{
            tool_calls: [%{id: "c1", name: "search", args: %{"q" => "first"}}],
            content: nil,
            tokens: nil
          },
          %{
            tool_calls: [%{id: "c2", name: "search", args: %{"q" => "second"}}],
            content: nil,
            tokens: nil
          },
          %{content: ~S|{"answer": "done"}|, tokens: nil}
        ])

      agent = make_agent()
      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert length(step.tool_calls) == 2
    end
  end

  describe "collect_messages" do
    test "full message history captured when enabled" do
      llm =
        tool_calling_llm([
          %{
            tool_calls: [%{id: "c1", name: "search", args: %{"q" => "test"}}],
            content: nil,
            tokens: nil
          },
          %{content: ~S|{"answer": "found"}|, tokens: nil}
        ])

      agent = make_agent()
      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)

      assert is_list(step.messages)
      assert step.messages != []

      # First message should be system
      assert hd(step.messages).role == :system

      # Should contain tool result messages
      roles = Enum.map(step.messages, & &1.role)
      assert :tool in roles
    end
  end

  describe "no id field" do
    test "synthetic IDs generated when provider omits id" do
      llm =
        tool_calling_llm([
          # No id field on tool call
          %{tool_calls: [%{name: "search", args: %{"q" => "test"}}], content: nil, tokens: nil},
          %{content: ~S|{"answer": "ok"}|, tokens: nil}
        ])

      agent = make_agent()
      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == %{"answer" => "ok"}
    end
  end

  describe "validation" do
    test "tool_calling mode requires tools" do
      assert_raise ArgumentError, ~r/requires at least one tool/, fn ->
        SubAgent.new(
          prompt: "Test",
          output: :tool_calling,
          signature: "() -> :string",
          tools: %{}
        )
      end
    end

    test "tool_calling mode requires signature" do
      assert_raise ArgumentError, ~r/requires a signature/, fn ->
        SubAgent.new(prompt: "Test", output: :tool_calling, tools: %{"a" => fn _ -> :ok end})
      end
    end
  end
end
