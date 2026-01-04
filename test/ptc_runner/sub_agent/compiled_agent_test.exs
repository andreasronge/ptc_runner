defmodule PtcRunner.SubAgent.CompiledAgentTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.{CompiledAgent, LLMTool}

  doctest CompiledAgent
  doctest PtcRunner.SubAgent.Compiler

  describe "SubAgent.compile/2" do
    test "returns {:ok, CompiledAgent} on successful compilation" do
      tools = %{"double" => fn %{n: n} -> n * 2 end}

      agent =
        SubAgent.new(
          prompt: "Double the input number {{n}}",
          signature: "(n :int) -> {result :int}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn _ ->
        {:ok, ~S|(call "return" {:result (call "double" {:n ctx/n})})|}
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm, sample: %{n: 5})

      assert %CompiledAgent{} = compiled
      assert is_binary(compiled.source)
      assert compiled.signature == "(n :int) -> {result :int}"
      assert is_function(compiled.execute, 1)
      assert %{compiled_at: _, tokens_used: _, turns: _, llm_model: _} = compiled.metadata
    end

    test "returns {:error, Step} if agent execution fails" do
      agent =
        SubAgent.new(
          prompt: "This will fail",
          signature: "() -> :int",
          max_turns: 1
        )

      # Mock LLM that returns invalid PTC-Lisp
      mock_llm = fn _ -> {:ok, "invalid lisp code"} end

      assert {:error, step} = SubAgent.compile(agent, llm: mock_llm)
      assert step.fail != nil
    end

    test "raises ArgumentError if agent has LLMTool" do
      llm_tool =
        LLMTool.new(prompt: "Classify {{x}}", signature: "(x :string) -> :string")

      tools = %{"classify" => llm_tool}

      agent =
        SubAgent.new(
          prompt: "Process {{item}}",
          signature: "(item :string) -> {category :string}",
          tools: tools
        )

      assert_raise ArgumentError, ~r/LLM-dependent tool: classify/, fn ->
        SubAgent.compile(agent, llm: fn _ -> {:ok, ""} end)
      end
    end

    test "raises ArgumentError if agent has SubAgentTool" do
      child = SubAgent.new(prompt: "Child agent")
      sub_agent_tool = SubAgent.as_tool(child)
      tools = %{"child" => sub_agent_tool}

      agent =
        SubAgent.new(
          prompt: "Parent agent",
          signature: "() -> :string",
          tools: tools
        )

      assert_raise ArgumentError, ~r/LLM-dependent tool: child/, fn ->
        SubAgent.compile(agent, llm: fn _ -> {:ok, ""} end)
      end
    end

    test "compiled.source contains valid PTC-Lisp" do
      tools = %{"triple" => fn %{n: n} -> n * 3 end}

      agent =
        SubAgent.new(
          prompt: "Triple {{n}}",
          signature: "(n :int) -> {result :int}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn _ ->
        {:ok, ~S|(call "return" {:result (call "triple" {:n ctx/n})})|}
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm, sample: %{n: 5})

      assert compiled.source =~ "call"
      assert compiled.source =~ "triple"
    end

    test "compiled.execute runs the stored program" do
      tools = %{"add_ten" => fn %{n: n} -> n + 10 end}

      agent =
        SubAgent.new(
          prompt: "Add 10 to {{n}}",
          signature: "(n :int) -> {result :int}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn _ ->
        {:ok, ~S|(call "return" {:result (call "add_ten" {:n ctx/n})})|}
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm, sample: %{n: 5})

      # Execute multiple times without LLM
      result1 = compiled.execute.(%{n: 10})
      assert result1.return.result == 20

      result2 = compiled.execute.(%{n: 100})
      assert result2.return.result == 110

      result3 = compiled.execute.(%{n: 1})
      assert result3.return.result == 11
    end

    test "compiled.execute calls tools at runtime with correct args" do
      call_log = :ets.new(:calls, [:set, :public])

      tools = %{
        "log_and_double" => fn %{n: n} ->
          :ets.insert(call_log, {:called, n})
          n * 2
        end
      }

      agent =
        SubAgent.new(
          prompt: "Process {{n}}",
          signature: "(n :int) -> {result :int}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn _ ->
        {:ok, ~S|(call "return" {:result (call "log_and_double" {:n ctx/n})})|}
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm, sample: %{n: 1})

      compiled.execute.(%{n: 42})

      assert [{:called, 42}] = :ets.lookup(call_log, :called)
      :ets.delete(call_log)
    end

    test "compiled.metadata contains required fields" do
      tools = %{"noop" => fn _ -> :ok end}

      agent =
        SubAgent.new(
          prompt: "Test",
          signature: "() -> {status :string}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn _ -> {:ok, ~S|(call "return" {:status "done"})|} end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm)

      assert %DateTime{} = compiled.metadata.compiled_at
      assert is_integer(compiled.metadata.tokens_used)
      assert compiled.metadata.tokens_used >= 0
      assert is_integer(compiled.metadata.turns)
      assert compiled.metadata.turns >= 1
      assert is_nil(compiled.metadata.llm_model) or is_binary(compiled.metadata.llm_model)
    end

    test "metadata.llm_model is extracted from atom llm" do
      tools = %{"noop" => fn _ -> :ok end}
      agent = SubAgent.new(prompt: "Test", max_turns: 1, tools: tools)

      mock_registry = %{
        test_model: fn _ -> {:ok, ~S|(call "return" {:status "done"})|} end
      }

      {:ok, compiled} = SubAgent.compile(agent, llm: :test_model, llm_registry: mock_registry)

      assert compiled.metadata.llm_model == "test_model"
    end

    test "metadata.llm_model is nil for function llm" do
      tools = %{"noop" => fn _ -> :ok end}
      agent = SubAgent.new(prompt: "Test", max_turns: 1, tools: tools)
      mock_llm = fn _ -> {:ok, ~S|(call "return" {:status "done"})|} end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm)

      assert compiled.metadata.llm_model == nil
    end

    test "accepts empty tools map (pure computation)" do
      tools = %{"noop" => fn _ -> :ok end}

      agent =
        SubAgent.new(
          prompt: "Return 42",
          signature: "() -> {value :int}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn _ -> {:ok, ~S|(call "return" {:value 42})|} end

      assert {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm)
      result = compiled.execute.(%{})
      assert result.return.value == 42
    end

    test "uses sample data during compilation" do
      tools = %{"process" => fn %{data: data} -> String.upcase(data) end}

      agent =
        SubAgent.new(
          prompt: "Process {{data}}",
          signature: "(data :string) -> {result :string}",
          tools: tools,
          max_turns: 1
        )

      # LLM receives the sample data in context
      mock_llm = fn %{messages: messages} ->
        user_msg = Enum.find(messages, fn m -> m.role == :user end)
        assert user_msg.content =~ "sample text"
        {:ok, ~S|(call "return" {:result (call "process" {:data ctx/data})})|}
      end

      {:ok, _compiled} =
        SubAgent.compile(agent, llm: mock_llm, sample: %{data: "sample text"})
    end
  end

  describe "CompiledAgent.as_tool/1" do
    test "returns a function that executes the compiled agent" do
      tools = %{"double" => fn %{n: n} -> n * 2 end}

      agent =
        SubAgent.new(
          prompt: "Double {{n}}",
          signature: "(n :int) -> {result :int}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn _ ->
        {:ok, ~S|(call "return" {:result (call "double" {:n ctx/n})})|}
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm, sample: %{n: 1})

      tool = CompiledAgent.as_tool(compiled)

      assert tool.type == :compiled
      assert is_function(tool.execute, 1)

      result = tool.execute.(%{n: 5})
      assert result.return.result == 10
    end

    test "tool executes without LLM" do
      tools = %{"add" => fn %{a: a, b: b} -> a + b end}

      agent =
        SubAgent.new(
          prompt: "Add {{a}} and {{b}}",
          signature: "(a :int, b :int) -> {sum :int}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn _ ->
        {:ok, ~S|(call "return" {:sum (call "add" {:a ctx/a :b ctx/b})})|}
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm, sample: %{a: 1, b: 1})

      tool = CompiledAgent.as_tool(compiled)

      # Execute tool multiple times - no LLM needed
      assert tool.execute.(%{a: 1, b: 2}).return.sum == 3
      assert tool.execute.(%{a: 10, b: 20}).return.sum == 30
      assert tool.execute.(%{a: 100, b: 200}).return.sum == 300
    end
  end

  describe "field_descriptions propagation" do
    test "compiled agent inherits field_descriptions from source agent" do
      fd = %{result: "The doubled value"}
      tools = %{"double" => fn %{n: n} -> n * 2 end}

      agent =
        SubAgent.new(
          prompt: "Double {{n}}",
          signature: "(n :int) -> {result :int}",
          tools: tools,
          max_turns: 1,
          field_descriptions: fd
        )

      mock_llm = fn _ ->
        {:ok, ~S|(call "return" {:result (call "double" {:n ctx/n})})|}
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm, sample: %{n: 1})

      assert compiled.field_descriptions == fd
      assert compiled.field_descriptions[:result] == "The doubled value"
    end

    test "compiled agent has nil field_descriptions when source has none" do
      tools = %{"double" => fn %{n: n} -> n * 2 end}

      agent =
        SubAgent.new(
          prompt: "Double {{n}}",
          signature: "(n :int) -> {result :int}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn _ ->
        {:ok, ~S|(call "return" {:result (call "double" {:n ctx/n})})|}
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm, sample: %{n: 1})

      assert compiled.field_descriptions == nil
    end
  end

  describe "end-to-end workflow" do
    test "compile and execute many times without LLM" do
      tools = %{
        "calculate_score" => fn %{value: value, threshold: threshold} ->
          if value > threshold, do: 0.9, else: 0.1
        end
      }

      agent =
        SubAgent.new(
          prompt: "Calculate anomaly score for value {{value}} with threshold {{threshold}}",
          signature: "(value :float, threshold :float) -> {score :float, anomalous :bool}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn _ ->
        {:ok,
         ~S|(call "return" {:score (call "calculate_score" {:value ctx/value :threshold ctx/threshold}) :anomalous (> (call "calculate_score" {:value ctx/value :threshold ctx/threshold}) 0.5)})|}
      end

      # Compile once
      {:ok, compiled} =
        SubAgent.compile(agent, llm: mock_llm, sample: %{value: 100.0, threshold: 50.0})

      # Execute many times without LLM
      result1 = compiled.execute.(%{value: 80.0, threshold: 50.0})
      assert result1.return.score == 0.9
      assert result1.return.anomalous == true

      result2 = compiled.execute.(%{value: 30.0, threshold: 50.0})
      assert result2.return.score == 0.1
      assert result2.return.anomalous == false

      result3 = compiled.execute.(%{value: 100.0, threshold: 90.0})
      assert result3.return.score == 0.9
      assert result3.return.anomalous == true
    end

    test "compiled agent handles runtime tool errors gracefully" do
      tools = %{
        "divide" => fn %{a: a, b: b} ->
          if b == 0, do: raise(ArithmeticError, "division by zero"), else: div(a, b)
        end
      }

      agent =
        SubAgent.new(
          prompt: "Divide {{a}} by {{b}}",
          signature: "(a :int, b :int) -> {result :int}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn _ ->
        {:ok, ~S|(call "return" {:result (call "divide" {:a ctx/a :b ctx/b})})|}
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm, sample: %{a: 10, b: 2})

      # Valid execution
      result1 = compiled.execute.(%{a: 10, b: 2})
      assert result1.return.result == 5

      # Runtime error
      result2 = compiled.execute.(%{a: 10, b: 0})
      assert result2.fail != nil
      assert result2.fail.reason == :execution_error
    end
  end
end
