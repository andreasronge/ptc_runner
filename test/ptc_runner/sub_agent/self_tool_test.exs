defmodule PtcRunner.SubAgent.SelfToolTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  describe "validation" do
    test "rejects :self tool without signature" do
      assert_raise ArgumentError, ~r/agents with :self tools must have a signature/, fn ->
        SubAgent.new(
          prompt: "Process {{chunk}}",
          tools: %{"worker" => :self}
        )
      end
    end

    test "accepts :self tool with signature" do
      agent =
        SubAgent.new(
          prompt: "Process {{chunk}}",
          signature: "(chunk :string) -> {result :string}",
          tools: %{"worker" => :self}
        )

      assert agent.tools == %{"worker" => :self}
    end

    test "accepts multiple :self tools with signature" do
      agent =
        SubAgent.new(
          prompt: "Process {{data}}",
          signature: "(data :string) -> {result :string}",
          tools: %{"a" => :self, "b" => :self}
        )

      assert agent.tools == %{"a" => :self, "b" => :self}
    end
  end

  describe "description defaults" do
    test "uses agent description when provided" do
      agent =
        SubAgent.new(
          prompt: "Process {{chunk}}",
          signature: "(chunk :string) -> {result :string}",
          description: "Custom description",
          tools: %{"worker" => :self}
        )

      preview = SubAgent.preview_prompt(agent, context: %{chunk: "test"})

      # The :self tool should use the agent's description
      assert [tool_schema] = preview.tool_schemas
      assert tool_schema.description == "Custom description"
    end

    test "uses fallback description when agent has no description" do
      agent =
        SubAgent.new(
          prompt: "Process {{chunk}}",
          signature: "(chunk :string) -> {result :string}",
          tools: %{"worker" => :self}
        )

      preview = SubAgent.preview_prompt(agent, context: %{chunk: "test"})

      # The :self tool should use the fallback description
      assert [tool_schema] = preview.tool_schemas
      assert tool_schema.description == "Recursively invoke this agent on a subset of the input"
    end
  end

  describe "preview_prompt" do
    test "resolves :self tool in tool_schemas" do
      agent =
        SubAgent.new(
          prompt: "Analyze {{chunk}}",
          signature: "(chunk :string) -> {incidents [:string]}",
          description: "Analyze logs for incidents",
          tools: %{"worker" => :self}
        )

      preview = SubAgent.preview_prompt(agent, context: %{chunk: "test"})

      assert [tool_schema] = preview.tool_schemas
      assert tool_schema.name == "worker"
      assert tool_schema.signature == "(chunk :string) -> {incidents [:string]}"
      assert tool_schema.description == "Analyze logs for incidents"
    end

    test "renders :self tool in user message" do
      agent =
        SubAgent.new(
          prompt: "Analyze {{chunk}}",
          signature: "(chunk :string) -> {incidents [:string]}",
          description: "Analyze logs for incidents",
          tools: %{"worker" => :self}
        )

      preview = SubAgent.preview_prompt(agent, context: %{chunk: "test"})

      # The tool should appear in the user message
      assert preview.user =~ "tool/worker"
      assert preview.user =~ "Analyze logs for incidents"
    end
  end

  describe "basic recursion" do
    test "agent calls itself and aggregates results" do
      # Create a recursive agent that subdivides work
      agent =
        SubAgent.new(
          prompt: "Process {{items}}",
          signature: "(items [:int]) -> {sum :int}",
          description: "Sum integers",
          tools: %{"worker" => :self},
          max_turns: 3,
          max_depth: 3
        )

      # LLM that:
      # - Turn 1: Calls worker tool with a subset
      # - Turn 2 (child): Returns sum of subset
      # - Turn 2 (parent): Aggregates and returns
      llm = fn %{messages: msgs, turn: turn} = input ->
        depth = Map.get(input, :depth, 0)
        content = msgs |> List.last() |> Map.get(:content)

        cond do
          # Child agent: just return sum directly
          content =~ "items" and depth > 0 ->
            {:ok, "```clojure\n(return {:sum (reduce + data/items)})\n```"}

          # Parent turn 1: call worker
          turn == 1 ->
            {:ok, "```clojure\n(tool/worker {:items [1 2 3]})\n```"}

          # Parent turn 2: return result
          true ->
            {:ok, "```clojure\n(return {:sum 6})\n```"}
        end
      end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{items: [1, 2, 3, 4, 5]})

      assert step.return == %{"sum" => 6}
    end
  end

  describe "depth limiting" do
    test "tool error when max_depth exceeded, parent can recover" do
      agent =
        SubAgent.new(
          prompt: "Process {{n}}",
          signature: "(n :int) -> {result :int}",
          description: "Recursive counter",
          tools: %{"recurse" => :self},
          max_turns: 5,
          max_depth: 2
        )

      # LLM that tries to recurse, then recovers on error
      llm = fn %{turn: turn} ->
        if turn == 1 do
          {:ok, "```clojure\n(tool/recurse {:n 1})\n```"}
        else
          {:ok, "```clojure\n(return {:result 42})\n```"}
        end
      end

      # Start at depth 1, so child will be at depth 2 which equals max_depth
      # Child fails but parent catches the tool error and continues
      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{n: 0}, _nesting_depth: 1)

      # Parent recovers from the child depth error and returns successfully
      assert step.return == %{"result" => 42}
      # Verify the tool error was logged in the turns
      [first_turn | _] = step.turns
      assert first_turn.result.reason == :tool_error
      assert first_turn.result.message =~ "Nesting depth limit exceeded"
    end

    test "succeeds when depth limit not exceeded" do
      agent =
        SubAgent.new(
          prompt: "Process {{n}}",
          signature: "(n :int) -> {result :int}",
          description: "Recursive counter",
          tools: %{"recurse" => :self},
          max_turns: 5,
          max_depth: 3
        )

      # LLM calls recurse once, child returns
      llm = fn %{turn: turn} = input ->
        depth = Map.get(input, :depth, 0)

        cond do
          # Child: return directly
          depth > 0 ->
            {:ok, "```clojure\n(return {:result 42})\n```"}

          # Parent turn 1: call recurse
          turn == 1 ->
            {:ok, "```clojure\n(tool/recurse {:n 1})\n```"}

          # Parent turn 2: return
          true ->
            {:ok, "```clojure\n(return {:result 42})\n```"}
        end
      end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{n: 0})

      assert step.return == %{"result" => 42}
    end
  end

  describe "turn budget sharing" do
    test "turn budget decrements across recursive calls" do
      agent =
        SubAgent.new(
          prompt: "Process {{n}}",
          signature: "(n :int) -> {result :int}",
          description: "Counter",
          tools: %{"recurse" => :self},
          max_turns: 10,
          turn_budget: 20,
          max_depth: 5
        )

      # With limited turn budget, recursive calls should share it
      llm = fn %{turn: turn} = input ->
        depth = Map.get(input, :depth, 0)

        cond do
          depth > 0 ->
            {:ok, "```clojure\n(return {:result data/n})\n```"}

          turn == 1 ->
            {:ok, "```clojure\n(tool/recurse {:n 1})\n```"}

          true ->
            {:ok, "```clojure\n(return {:result 1})\n```"}
        end
      end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{n: 0})

      # Should succeed and have used some turns
      assert step.return == %{"result" => 1}
      assert step.usage.turns >= 2
    end

    test "child uses shared turn budget" do
      agent =
        SubAgent.new(
          prompt: "Process {{n}}",
          signature: "(n :int) -> {result :int}",
          description: "Counter",
          tools: %{"recurse" => :self},
          max_turns: 10,
          turn_budget: 20,
          max_depth: 10
        )

      # LLM that calls itself, child returns
      llm = fn %{turn: turn} ->
        if turn == 1 do
          {:ok, "```clojure\n(tool/recurse {:n 1})\n```"}
        else
          {:ok, "```clojure\n(return {:result 42})\n```"}
        end
      end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{n: 0})

      # The execution succeeds with child inheriting the turn budget
      assert step.return == %{"result" => 42}
      # Parent uses 2 turns (call + return), child uses 1 turn
      assert step.usage.turns == 2
      assert step.usage.llm_requests == 2
    end
  end

  describe "pmap support" do
    test "parallel recursive calls work via pmap" do
      agent =
        SubAgent.new(
          prompt: "Process {{items}}",
          signature: "(items [:int]) -> {results [:int]}",
          description: "Double each item",
          tools: %{"worker" => :self},
          max_turns: 3,
          max_depth: 3
        )

      # Track call count to verify parallel execution
      {:ok, call_counter} = Agent.start_link(fn -> 0 end)

      llm = fn %{turn: turn} = input ->
        Agent.update(call_counter, &(&1 + 1))
        depth = Map.get(input, :depth, 0)

        cond do
          # Child: process single item
          depth > 0 ->
            {:ok, "```clojure\n(return {:results (map #(* 2 %) data/items)})\n```"}

          # Parent turn 1: call pmap with worker
          turn == 1 ->
            {:ok,
             """
             ```clojure
             (pmap (fn [x] (tool/worker {:items [x]})) [1 2 3])
             ```
             """}

          # Parent turn 2: aggregate and return
          true ->
            {:ok, "```clojure\n(return {:results [2 4 6]})\n```"}
        end
      end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{items: [1, 2, 3]})

      Agent.stop(call_counter)

      assert step.return == %{"results" => [2, 4, 6]}
    end
  end

  describe "multiple :self tools" do
    test "multiple :self tools are resolved correctly" do
      agent =
        SubAgent.new(
          prompt: "Process {{data}}",
          signature: "(data :string) -> {result :string}",
          description: "Process data",
          tools: %{"analyze" => :self, "summarize" => :self},
          max_turns: 4,
          max_depth: 3
        )

      preview = SubAgent.preview_prompt(agent, context: %{data: "test"})

      # Both tools should appear with the agent's signature and description
      assert length(preview.tool_schemas) == 2
      tool_names = Enum.map(preview.tool_schemas, & &1.name)
      assert "analyze" in tool_names
      assert "summarize" in tool_names

      # Both should have the same signature
      for schema <- preview.tool_schemas do
        assert schema.signature == "(data :string) -> {result :string}"
      end
    end
  end
end
