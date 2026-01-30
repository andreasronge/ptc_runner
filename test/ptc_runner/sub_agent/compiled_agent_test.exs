defmodule PtcRunner.SubAgent.CompiledAgentTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.{CompiledAgent, LLMTool}

  doctest CompiledAgent
  doctest PtcRunner.SubAgent.Compiler

  describe "SubAgent.compile/2" do
    test "returns {:ok, CompiledAgent} on successful compilation" do
      tools = %{"double" => fn %{"n" => n} -> n * 2 end}

      agent =
        SubAgent.new(
          prompt: "Double the input number {{n}}",
          signature: "(n :int) -> {result :int}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn _ ->
        {:ok, ~S|(return {:result (tool/double {:n data/n})})|}
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm, sample: %{n: 5})

      assert %CompiledAgent{} = compiled
      assert is_binary(compiled.source)
      assert compiled.signature == "(n :int) -> {result :int}"
      assert is_function(compiled.execute, 2)
      assert compiled.llm_required? == false
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

    test "compiles agent with LLMTool and sets llm_required?" do
      llm_tool =
        LLMTool.new(prompt: "Classify {{x}}", signature: "(x :string) -> :string")

      tools = %{"classify" => llm_tool}

      agent =
        SubAgent.new(
          prompt: "Process {{item}}",
          signature: "(item :string) -> {category :string}",
          tools: tools,
          max_turns: 1
        )

      {:ok, compiled} =
        SubAgent.compile(agent,
          llm: fn _ -> {:ok, ~S|(return {:category "test"})|} end
        )

      assert compiled.llm_required? == true
    end

    test "raises ArgumentError if agent has SubAgentTool with mission_timeout" do
      child =
        SubAgent.new(
          prompt: "Child agent",
          description: "A child agent",
          mission_timeout: 5000
        )

      sub_agent_tool = SubAgent.as_tool(child)
      tools = %{"child" => sub_agent_tool}

      agent =
        SubAgent.new(
          prompt: "Parent agent",
          signature: "() -> :string",
          tools: tools,
          max_turns: 1
        )

      assert_raise ArgumentError, ~r/mission_timeout: child/, fn ->
        SubAgent.compile(agent, llm: fn _ -> {:ok, ""} end)
      end
    end

    test "allows SubAgentTool without mission_timeout" do
      child =
        SubAgent.new(
          prompt: "Echo {{msg}}",
          signature: "(msg :string) -> {echo :string}",
          description: "Echo agent",
          max_turns: 1
        )

      sub_agent_tool = SubAgent.as_tool(child)
      tools = %{"echo" => sub_agent_tool}

      agent =
        SubAgent.new(
          prompt: "Use echo tool for {{input}}",
          signature: "(input :string) -> {result :string}",
          tools: tools,
          max_turns: 1
        )

      # Context-aware mock LLM - returns different responses for parent vs child
      mock_llm = fn %{messages: messages} ->
        user_msg = Enum.find(messages, fn m -> m.role == :user end)

        if String.contains?(user_msg.content, "tool/echo") do
          # This is the parent orchestrator
          {:ok, ~S|(return {:result (get (tool/echo {:msg data/input}) :echo)})|}
        else
          # This is the child echo agent
          {:ok, ~S|(return {:echo "mocked echo"})|}
        end
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm)
      assert compiled.llm_required? == true
    end

    test "raises ArgumentError if max_turns > 1" do
      agent =
        SubAgent.new(
          prompt: "Test",
          signature: "() -> :string",
          max_turns: 3
        )

      assert_raise ArgumentError, ~r/only single-shot agents/, fn ->
        SubAgent.compile(agent, llm: fn _ -> {:ok, ""} end)
      end
    end

    test "raises ArgumentError if output: :json" do
      agent =
        SubAgent.new(
          prompt: "Test",
          signature: "() -> :string",
          output: :json,
          max_turns: 1
        )

      assert_raise ArgumentError, ~r/only PTC-Lisp agents/, fn ->
        SubAgent.compile(agent, llm: fn _ -> {:ok, ""} end)
      end
    end

    test "compiled.execute runs the stored program" do
      tools = %{"add_ten" => fn %{"n" => n} -> n + 10 end}

      agent =
        SubAgent.new(
          prompt: "Add 10 to {{n}}",
          signature: "(n :int) -> {result :int}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn _ ->
        {:ok, ~S|(return {:result (tool/add_ten {:n data/n})})|}
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm, sample: %{n: 5})

      result = compiled.execute.(%{n: 10}, [])
      assert result.return.result == 20
    end

    test "compiled.execute calls tools at runtime with correct args" do
      call_log = :ets.new(:calls, [:set, :public])

      tools = %{
        "log_and_double" => fn %{"n" => n} ->
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
        {:ok, ~S|(return {:result (tool/log_and_double {:n data/n})})|}
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm, sample: %{n: 1})

      compiled.execute.(%{n: 42}, [])

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

      mock_llm = fn _ -> {:ok, ~S|(return {:status "done"})|} end

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
        test_model: fn _ -> {:ok, ~S|(return {:status "done"})|} end
      }

      {:ok, compiled} = SubAgent.compile(agent, llm: :test_model, llm_registry: mock_registry)

      assert compiled.metadata.llm_model == "test_model"
    end

    test "metadata.llm_model is nil for function llm" do
      tools = %{"noop" => fn _ -> :ok end}
      agent = SubAgent.new(prompt: "Test", max_turns: 1, tools: tools)
      mock_llm = fn _ -> {:ok, ~S|(return {:status "done"})|} end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm)

      assert compiled.metadata.llm_model == nil
    end

    test "uses sample data during compilation" do
      tools = %{"process" => fn %{"data" => data} -> String.upcase(data) end}

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
        {:ok, ~S|(return {:result (tool/process {:data data/data})})|}
      end

      {:ok, _compiled} =
        SubAgent.compile(agent, llm: mock_llm, sample: %{data: "sample text"})
    end
  end

  describe "CompiledAgent.as_tool/1" do
    test "returns a function that executes the compiled agent" do
      tools = %{"double" => fn %{"n" => n} -> n * 2 end}

      agent =
        SubAgent.new(
          prompt: "Double {{n}}",
          signature: "(n :int) -> {result :int}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn _ ->
        {:ok, ~S|(return {:result (tool/double {:n data/n})})|}
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm, sample: %{n: 1})

      tool = CompiledAgent.as_tool(compiled)

      assert tool.type == :compiled
      assert is_function(tool.execute, 1)

      result = tool.execute.(%{n: 5})
      assert result.return.result == 10
    end

    test "as_tool raises error for compiled agents with SubAgentTools" do
      child =
        SubAgent.new(
          prompt: "Echo {{msg}}",
          signature: "(msg :string) -> {echo :string}",
          description: "Echo agent",
          max_turns: 1
        )

      tools = %{"echo" => SubAgent.as_tool(child)}

      agent =
        SubAgent.new(
          prompt: "Use echo",
          signature: "(input :string) -> {result :string}",
          tools: tools,
          max_turns: 1
        )

      # Context-aware mock LLM for compilation
      mock_llm = fn %{messages: messages} ->
        user_msg = Enum.find(messages, fn m -> m.role == :user end)

        if String.contains?(user_msg.content, "tool/echo") do
          {:ok, ~S|(return {:result (get (tool/echo {:msg data/input}) :echo)})|}
        else
          {:ok, ~S|(return {:echo "mock"})|}
        end
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm)
      assert compiled.llm_required? == true

      tool = CompiledAgent.as_tool(compiled)

      assert_raise ArgumentError, ~r/cannot be used as a tool in dynamic agents/, fn ->
        tool.execute.(%{input: "test"})
      end
    end
  end

  describe "SubAgent.run/2 with CompiledAgent" do
    test "runs CompiledAgent without SubAgentTools (no LLM required)" do
      tools = %{"double" => fn %{"n" => n} -> n * 2 end}

      agent =
        SubAgent.new(
          prompt: "Double {{n}}",
          signature: "(n :int) -> {result :int}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn _ ->
        {:ok, ~S|(return {:result (tool/double {:n data/n})})|}
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm, sample: %{n: 1})

      # Run via unified API - no LLM needed since no SubAgentTools
      {:ok, step} = SubAgent.run(compiled, context: %{n: 5})
      assert step.return.result == 10
    end

    test "run/2 with CompiledAgent returns error when llm required but not provided" do
      child =
        SubAgent.new(
          prompt: "Echo {{msg}}",
          signature: "(msg :string) -> {echo :string}",
          description: "Echo agent",
          max_turns: 1
        )

      tools = %{"echo" => SubAgent.as_tool(child)}

      agent =
        SubAgent.new(
          prompt: "Use echo",
          signature: "(input :string) -> {result :string}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn %{messages: messages} ->
        user_msg = Enum.find(messages, fn m -> m.role == :user end)

        if String.contains?(user_msg.content, "tool/echo") do
          {:ok, ~S|(return {:result (get (tool/echo {:msg data/input}) :echo)})|}
        else
          {:ok, ~S|(return {:echo "mock"})|}
        end
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm)

      # Should return error, not raise
      {:error, step} = SubAgent.run(compiled, context: %{input: "test"})
      assert step.fail.reason == :llm_required
    end

    test "run/2 with CompiledAgent works when LLM provided" do
      child =
        SubAgent.new(
          prompt: "Echo {{msg}}",
          signature: "(msg :string) -> {echo :string}",
          description: "Echo agent",
          max_turns: 1
        )

      tools = %{"echo" => SubAgent.as_tool(child)}

      agent =
        SubAgent.new(
          prompt: "Use echo",
          signature: "(input :string) -> {result :string}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn %{messages: messages} ->
        user_msg = Enum.find(messages, fn m -> m.role == :user end)

        if String.contains?(user_msg.content, "tool/echo") do
          {:ok, ~S|(return {:result (get (tool/echo {:msg data/input}) :echo)})|}
        else
          {:ok, ~S|(return {:echo "echoed"})|}
        end
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm)

      runtime_llm = fn _ -> {:ok, ~S|(return {:echo "runtime echo"})|} end
      {:ok, step} = SubAgent.run(compiled, context: %{input: "test"}, llm: runtime_llm)
      assert step.return.result == "runtime echo"
    end
  end

  describe "SubAgent.then/3 (non-bang)" do
    test "chains SubAgent results through CompiledAgent" do
      # First agent - dynamic
      doubler =
        SubAgent.new(
          prompt: "Double {{n}}",
          signature: "(n :int) -> {result :int}",
          max_turns: 1
        )

      # Second agent - compiled (pure, no LLM needed at runtime)
      tripler_def =
        SubAgent.new(
          prompt: "Triple {{result}}",
          signature: "(result :int) -> {final :int}",
          tools: %{"triple" => fn %{"n" => n} -> n * 3 end},
          max_turns: 1
        )

      mock_llm = fn _ ->
        {:ok, ~S|(return {:final (tool/triple {:n data/result})})|}
      end

      {:ok, tripler} = SubAgent.compile(tripler_def, llm: mock_llm, sample: %{result: 10})

      # Chain
      result =
        SubAgent.run(doubler,
          llm: fn _ -> {:ok, ~S|(return {:result (* 2 data/n)})|} end,
          context: %{n: 5}
        )
        |> SubAgent.then(tripler)

      assert {:ok, step} = result
      # CompiledAgent returns atom keys
      assert step.return.final == 30
    end

    test "then/3 short-circuits on error" do
      compiled_tools = %{"double" => fn %{"n" => n} -> n * 2 end}

      compiled_agent =
        SubAgent.new(
          prompt: "Double {{n}}",
          signature: "(n :int) -> {result :int}",
          tools: compiled_tools,
          max_turns: 1
        )

      mock_llm = fn _ ->
        {:ok, ~S|(return {:result (tool/double {:n data/n})})|}
      end

      {:ok, compiled} = SubAgent.compile(compiled_agent, llm: mock_llm, sample: %{n: 1})

      # Start with an error
      error_step = PtcRunner.Step.error(:test_error, "test failure", %{})

      result = SubAgent.then({:error, error_step}, compiled)

      assert {:error, step} = result
      assert step.fail.reason == :test_error
    end

    test "then/3 returns chain_error on missing keys" do
      agent =
        SubAgent.new(
          prompt: "Process {{missing_key}}",
          signature: "(missing_key :string) -> {result :string}",
          max_turns: 1
        )

      # Previous step has wrong keys
      prev_step = %PtcRunner.Step{return: %{wrong_key: "value"}, fail: nil}

      result = SubAgent.then({:ok, prev_step}, agent)

      assert {:error, step} = result
      assert step.fail.reason == :chain_error
      assert step.fail.message =~ "missing_key"
    end

    test "then/3 works with CompiledAgent chaining" do
      # Two compiled agents chained
      first_def =
        SubAgent.new(
          prompt: "Double {{n}}",
          signature: "(n :int) -> {doubled :int}",
          tools: %{"double" => fn %{"n" => n} -> n * 2 end},
          max_turns: 1
        )

      second_def =
        SubAgent.new(
          prompt: "Add 10 to {{doubled}}",
          signature: "(doubled :int) -> {final :int}",
          tools: %{"add10" => fn %{"n" => n} -> n + 10 end},
          max_turns: 1
        )

      mock_llm1 = fn _ -> {:ok, ~S|(return {:doubled (tool/double {:n data/n})})|} end
      mock_llm2 = fn _ -> {:ok, ~S|(return {:final (tool/add10 {:n data/doubled})})|} end

      {:ok, first} = SubAgent.compile(first_def, llm: mock_llm1, sample: %{n: 5})
      {:ok, second} = SubAgent.compile(second_def, llm: mock_llm2, sample: %{doubled: 10})

      result =
        SubAgent.run(first, context: %{n: 5})
        |> SubAgent.then(second)

      assert {:ok, step} = result
      assert step.return.final == 20
    end
  end

  describe "field_descriptions propagation" do
    test "compiled agent inherits field_descriptions from source agent" do
      fd = %{result: "The doubled value"}
      tools = %{"double" => fn %{"n" => n} -> n * 2 end}

      agent =
        SubAgent.new(
          prompt: "Double {{n}}",
          signature: "(n :int) -> {result :int}",
          tools: tools,
          max_turns: 1,
          field_descriptions: fd
        )

      mock_llm = fn _ ->
        {:ok, ~S|(return {:result (tool/double {:n data/n})})|}
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm, sample: %{n: 1})

      assert compiled.field_descriptions == fd
      assert compiled.field_descriptions[:result] == "The doubled value"
    end
  end

  describe "end-to-end workflow" do
    test "compile and execute many times without LLM" do
      tools = %{
        "calculate_score" => fn %{"value" => value, "threshold" => threshold} ->
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
         ~S|(return {:score (tool/calculate_score {:value data/value :threshold data/threshold}) :anomalous (> (tool/calculate_score {:value data/value :threshold data/threshold}) 0.5)})|}
      end

      # Compile once
      {:ok, compiled} =
        SubAgent.compile(agent, llm: mock_llm, sample: %{value: 100.0, threshold: 50.0})

      # Execute multiple times without LLM
      result1 = compiled.execute.(%{value: 80.0, threshold: 50.0}, [])
      assert result1.return.score == 0.9
      assert result1.return.anomalous == true

      result2 = compiled.execute.(%{value: 30.0, threshold: 50.0}, [])
      assert result2.return.score == 0.1
      assert result2.return.anomalous == false
    end

    test "compiled agent handles runtime tool errors gracefully" do
      tools = %{
        "divide" => fn %{"a" => a, "b" => b} ->
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
        {:ok, ~S|(return {:result (tool/divide {:a data/a :b data/b})})|}
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm, sample: %{a: 10, b: 2})

      # Valid execution
      result1 = compiled.execute.(%{a: 10, b: 2}, [])
      assert result1.return.result == 5

      # Runtime error - tool exceptions return :tool_error
      result2 = compiled.execute.(%{a: 10, b: 0}, [])
      assert result2.fail != nil
      assert result2.fail.reason == :tool_error
    end

    test "compiled.execute respects timeout option" do
      tools = %{
        "slow_op" => fn %{"n" => n} ->
          Process.sleep(100)
          n * 2
        end
      }

      agent =
        SubAgent.new(
          prompt: "Double {{n}} slowly",
          signature: "(n :int) -> {result :int}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn _ ->
        {:ok, ~S|(return {:result (tool/slow_op {:n data/n})})|}
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm, sample: %{n: 1})

      # With short timeout, should fail
      result_timeout = compiled.execute.(%{n: 5}, timeout: 10)
      assert result_timeout.fail != nil
      assert result_timeout.fail.reason == :timeout

      # With longer timeout, should succeed
      result_ok = compiled.execute.(%{n: 5}, timeout: 500)
      assert result_ok.return.result == 10
    end

    test "compiled.execute respects max_heap option" do
      tools = %{
        "make_list" => fn %{"size" => size} ->
          Enum.to_list(1..size)
        end
      }

      agent =
        SubAgent.new(
          prompt: "Make a list of size {{size}}",
          signature: "(size :int) -> {count :int}",
          tools: tools,
          max_turns: 1
        )

      mock_llm = fn _ ->
        {:ok, ~S|(return {:count (count (tool/make_list {:size data/size}))})|}
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm, sample: %{size: 10})

      # With tiny heap, large list should fail
      result_fail = compiled.execute.(%{size: 100_000}, max_heap: 1000)
      assert result_fail.fail != nil
      assert result_fail.fail.reason == :memory_exceeded

      # With default heap, should succeed
      result_ok = compiled.execute.(%{size: 100}, [])
      assert result_ok.return.count == 100
    end
  end

  describe "compile with SubAgentTools (orchestrator pattern)" do
    test "compiled orchestrator with recursive loop and multiple SubAgentTools" do
      # This test mimics the joke_workflow.livemd scenario exactly
      #
      # Child agent: generate_joke (SubAgentTool - requires LLM)
      joke_agent =
        SubAgent.new(
          prompt: "Generate a short joke about {{topic}}. Just the joke.",
          signature: "(topic :string) -> {joke :string}",
          description: "Generate a joke about the given topic",
          max_turns: 1
        )

      generate_joke_tool = SubAgent.as_tool(joke_agent)

      # Pure Elixir tool: check_punchline (no LLM)
      check_punchline_tool =
        {fn %{"joke" => joke} ->
           String.contains?(joke, "?") or String.contains?(joke, "!")
         end, signature: "(joke :string) -> :bool", description: "Check if joke has punchline"}

      # Child agent: improve_joke (SubAgentTool - requires LLM)
      improve_joke_agent =
        SubAgent.new(
          prompt: "Improve this joke: {{joke}}. Return only the improved joke.",
          signature: "(joke :string) -> {improved_joke :string}",
          description: "Improve a joke with wordplay or twist",
          max_turns: 1
        )

      improve_joke_tool = SubAgent.as_tool(improve_joke_agent)

      tools = %{
        "generate_joke" => generate_joke_tool,
        "check_punchline" => check_punchline_tool,
        "improve_joke" => improve_joke_tool
      }

      # Orchestrator with the same signature as the livebook
      orchestrator =
        SubAgent.new(
          prompt: """
          Create a joke about {{topic}} using the available tools.
          1. Generate a joke
          2. Check if it has a good punchline
          3. If not, improve it (max 3 times)
          4. Return the final joke
          """,
          signature: "(topic :string) -> {joke :string, iterations :int, was_improved :bool}",
          tools: tools,
          max_turns: 1
        )

      # Mock LLM that returns the exact PTC-Lisp from the livebook example
      compile_llm = fn %{messages: messages} ->
        user_msg = Enum.find(messages, fn m -> m.role == :user end)

        cond do
          String.contains?(user_msg.content, "tool/generate_joke") and
              String.contains?(user_msg.content, "tool/improve_joke") ->
            # This is the orchestrator - use defn for recursive function (defn supports recursion, let does not)
            {:ok,
             """
             (defn improvement-loop [joke iteration-count]
               (if (tool/check_punchline {:joke joke})
                 {:final-joke joke :iterations iteration-count :was-improved (> iteration-count 1)}
                 (if (>= iteration-count 3)
                   {:final-joke joke :iterations iteration-count :was-improved (> iteration-count 1)}
                   (let [improved (:improved_joke (tool/improve_joke {:joke joke}))]
                     (improvement-loop improved (inc iteration-count))))))

             (let [topic data/topic
                   initial-joke (:joke (tool/generate_joke {:topic topic}))
                   result (improvement-loop initial-joke 1)]
               (return {:joke (:final-joke result)
                        :iterations (:iterations result)
                        :was_improved (:was-improved result)}))
             """}

          String.contains?(user_msg.content, "Improve this joke") ->
            # This is the improve_joke agent
            {:ok,
             ~S|(return {:improved_joke "Why do programmers love dark mode? Because bugs hate the light!"})|}

          true ->
            # This is the generate_joke agent
            {:ok, ~S|(return {:joke "Why do programmers wear glasses"})|}
        end
      end

      # Compile the orchestrator
      {:ok, compiled} = SubAgent.compile(orchestrator, llm: compile_llm)

      assert compiled.llm_required? == true

      # Runtime LLM for the SubAgentTools
      runtime_llm = fn %{messages: messages} ->
        user_msg = Enum.find(messages, fn m -> m.role == :user end)

        if String.contains?(user_msg.content, "Improve this joke") do
          {:ok,
           ~S|(return {:improved_joke "Why do programmers love dark mode? Because bugs hate the light!"})|}
        else
          {:ok, ~S|(return {:joke "Why do programmers wear glasses"})|}
        end
      end

      # Execute and verify
      result = compiled.execute.(%{topic: "programmers"}, llm: runtime_llm, timeout: 10_000)

      # This is the key assertion - return should NOT be nil
      assert result.return != nil,
             "Expected return value but got nil. Fail: #{inspect(result.fail)}"

      assert result.return.joke != nil
      assert is_integer(result.return.iterations)
      assert is_boolean(result.return.was_improved)
    end

    test "compiles orchestrator with SubAgentTools, executing them at runtime" do
      # Child agent that generates a joke (requires LLM at runtime)
      joke_agent =
        SubAgent.new(
          prompt: "Generate a short joke about {{topic}}. Just the joke.",
          signature: "(topic :string) -> {joke :string}",
          description: "Generate a joke about the given topic",
          max_turns: 1
        )

      generate_joke_tool = SubAgent.as_tool(joke_agent)

      # Pure Elixir tool (no LLM needed)
      check_punchline_tool =
        {fn %{"joke" => joke} ->
           String.contains?(joke, "?") or String.contains?(joke, "!")
         end, signature: "(joke :string) -> :bool", description: "Check if joke has punchline"}

      tools = %{
        "generate_joke" => generate_joke_tool,
        "check_punchline" => check_punchline_tool
      }

      # Orchestrator that uses these tools
      orchestrator =
        SubAgent.new(
          prompt: """
          Create a joke about {{topic}}.
          1. Generate a joke
          2. Check if it has a good punchline
          3. Return the joke and whether it passed the check
          """,
          signature: "(topic :string) -> {joke :string, has_punchline :bool}",
          tools: tools,
          max_turns: 1
        )

      # Context-aware mock LLM for compilation
      # Returns different responses for orchestrator vs child agents
      compile_llm = fn %{messages: messages} ->
        user_msg = Enum.find(messages, fn m -> m.role == :user end)

        if String.contains?(user_msg.content, "tool/generate_joke") do
          # This is the orchestrator - return the orchestration logic
          {:ok,
           """
           (let [joke-result (tool/generate_joke {:topic data/topic})
                 joke (get joke-result :joke)
                 has-punchline (tool/check_punchline {:joke joke})]
             (return {:joke joke :has_punchline has-punchline}))
           """}
        else
          # This is the joke_agent - return a mock joke
          {:ok, ~S|(return {:joke "Why did the mock cross the road? To test the other side!"})|}
        end
      end

      # Compile the orchestrator - should NOT reject SubAgentTools
      {:ok, compiled} = SubAgent.compile(orchestrator, llm: compile_llm)

      assert compiled.llm_required? == true

      # Mock LLM for execution - used by the SubAgentTool at runtime
      # Child agent uses PTC-Lisp output mode, so return valid PTC-Lisp
      runtime_llm = fn _ ->
        {:ok,
         ~S|(return {:joke "Why do programmers prefer dark mode? Because light attracts bugs!"})|}
      end

      # Execute with runtime LLM for SubAgentTools
      result = compiled.execute.(%{topic: "programmers"}, llm: runtime_llm)

      assert result.return.joke =~ "programmer"
      assert result.return.has_punchline == true
    end

    test "compiled orchestrator can be executed multiple times with different LLMs" do
      # Simple child agent
      echo_agent =
        SubAgent.new(
          prompt: "Echo back: {{msg}}",
          signature: "(msg :string) -> {echo :string}",
          description: "Echoes the message",
          max_turns: 1
        )

      tools = %{"echo" => SubAgent.as_tool(echo_agent)}

      orchestrator =
        SubAgent.new(
          prompt: "Echo {{message}} using the echo tool",
          signature: "(message :string) -> {result :string}",
          tools: tools,
          max_turns: 1
        )

      # Context-aware mock LLM for compilation
      compile_llm = fn %{messages: messages} ->
        user_msg = Enum.find(messages, fn m -> m.role == :user end)

        if String.contains?(user_msg.content, "tool/echo") do
          # This is the orchestrator
          {:ok, ~S|(return {:result (get (tool/echo {:msg data/message}) :echo)})|}
        else
          # This is the echo agent
          {:ok, ~S|(return {:echo "mock echo"})|}
        end
      end

      {:ok, compiled} = SubAgent.compile(orchestrator, llm: compile_llm)

      # Execute with different LLMs - child agents use PTC-Lisp mode
      llm1 = fn _ -> {:ok, ~S|(return {:echo "Hello from LLM1"})|} end
      llm2 = fn _ -> {:ok, ~S|(return {:echo "Hello from LLM2"})|} end

      result1 = compiled.execute.(%{message: "test"}, llm: llm1)
      result2 = compiled.execute.(%{message: "test"}, llm: llm2)

      assert result1.return.result == "Hello from LLM1"
      assert result2.return.result == "Hello from LLM2"
    end

    test "compile retries when LLM produces invalid tool call syntax" do
      tools = %{
        "classify" =>
          {fn %{"text" => text} ->
             if String.contains?(text, "good"), do: "positive", else: "negative"
           end, signature: "(text :string) -> :string", description: "Classify sentiment"}
      }

      orchestrator =
        SubAgent.new(
          prompt: "Classify the sentiment of {{text}}",
          signature: "(text :string) -> {sentiment :string}",
          tools: tools,
          max_turns: 1
        )

      # Track call count to simulate LLM fixing its mistake on retry
      call_count = :counters.new(1, [:atomics])

      mock_llm = fn _params ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          # First attempt: invalid syntax (missing map wrapper)
          {:ok, ~S|(return {:sentiment (tool/classify data/text)})|}
        else
          # Retry: correct syntax
          {:ok, ~S|(return {:sentiment (tool/classify {:text data/text})})|}
        end
      end

      # Should succeed thanks to return_retries: 2 set by compiler
      assert {:ok, compiled} =
               SubAgent.compile(orchestrator, llm: mock_llm, sample: %{text: "good"})

      assert :counters.get(call_count, 1) > 1, "Expected LLM to be called more than once (retry)"

      # Verify the compiled agent works
      result = compiled.execute.(%{text: "good stuff"}, [])
      assert result.return.sentiment == "positive"
    end

    test "raises error if llm not provided at execute time with SubAgentTools" do
      child =
        SubAgent.new(
          prompt: "Echo {{msg}}",
          signature: "(msg :string) -> {echo :string}",
          description: "Echo agent",
          max_turns: 1
        )

      tools = %{"echo" => SubAgent.as_tool(child)}

      agent =
        SubAgent.new(
          prompt: "Use echo",
          signature: "(input :string) -> {result :string}",
          tools: tools,
          max_turns: 1
        )

      # Context-aware mock LLM for compilation
      mock_llm = fn %{messages: messages} ->
        user_msg = Enum.find(messages, fn m -> m.role == :user end)

        if String.contains?(user_msg.content, "tool/echo") do
          {:ok, ~S|(return {:result (get (tool/echo {:msg data/input}) :echo)})|}
        else
          {:ok, ~S|(return {:echo "mock"})|}
        end
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm)

      assert_raise ArgumentError, ~r/llm required for compiled agents/, fn ->
        compiled.execute.(%{input: "test"}, [])
      end
    end

    test "raises error if runtime LLM is atom not in registry" do
      child =
        SubAgent.new(
          prompt: "Echo {{msg}}",
          signature: "(msg :string) -> {echo :string}",
          description: "Echo agent",
          max_turns: 1
        )

      tools = %{"echo" => SubAgent.as_tool(child)}

      agent =
        SubAgent.new(
          prompt: "Use echo",
          signature: "(input :string) -> {result :string}",
          tools: tools,
          max_turns: 1
        )

      # Context-aware mock LLM for compilation
      mock_llm = fn %{messages: messages} ->
        user_msg = Enum.find(messages, fn m -> m.role == :user end)

        if String.contains?(user_msg.content, "tool/echo") do
          {:ok, ~S|(return {:result (get (tool/echo {:msg data/input}) :echo)})|}
        else
          {:ok, ~S|(return {:echo "mock"})|}
        end
      end

      {:ok, compiled} = SubAgent.compile(agent, llm: mock_llm)

      # Pass atom LLM without registry
      assert_raise ArgumentError, ~r/Runtime LLM :my_atom is not in llm_registry/, fn ->
        compiled.execute.(%{input: "test"}, llm: :my_atom)
      end
    end

    test "raises error if child agent's atom LLM not in registry" do
      child =
        SubAgent.new(
          prompt: "Echo {{msg}}",
          signature: "(msg :string) -> {echo :string}",
          description: "Echo agent",
          max_turns: 1,
          llm: :child_llm
        )

      tools = %{"echo" => SubAgent.as_tool(child)}

      agent =
        SubAgent.new(
          prompt: "Use echo",
          signature: "(input :string) -> {result :string}",
          tools: tools,
          max_turns: 1
        )

      # Context-aware mock LLM for compilation
      mock_llm = fn %{messages: messages} ->
        user_msg = Enum.find(messages, fn m -> m.role == :user end)

        if String.contains?(user_msg.content, "tool/echo") do
          {:ok, ~S|(return {:result (get (tool/echo {:msg data/input}) :echo)})|}
        else
          {:ok, ~S|(return {:echo "mock"})|}
        end
      end

      {:ok, compiled} =
        SubAgent.compile(agent, llm: mock_llm, llm_registry: %{child_llm: mock_llm})

      # Provide runtime LLM but not the registry
      runtime_llm = fn _ -> {:ok, ~S|(return {:echo "test"})|} end

      assert_raise ArgumentError, ~r/requires LLM :child_llm which is not in llm_registry/, fn ->
        compiled.execute.(%{input: "test"}, llm: runtime_llm)
      end
    end

    test "atom LLM works when provided in registry" do
      child =
        SubAgent.new(
          prompt: "Echo {{msg}}",
          signature: "(msg :string) -> {echo :string}",
          description: "Echo agent",
          max_turns: 1,
          llm: :child_llm
        )

      tools = %{"echo" => SubAgent.as_tool(child)}

      agent =
        SubAgent.new(
          prompt: "Use echo",
          signature: "(input :string) -> {result :string}",
          tools: tools,
          max_turns: 1
        )

      # Context-aware mock LLM for compilation
      mock_llm = fn %{messages: messages} ->
        user_msg = Enum.find(messages, fn m -> m.role == :user end)

        if String.contains?(user_msg.content, "tool/echo") do
          {:ok, ~S|(return {:result (get (tool/echo {:msg data/input}) :echo)})|}
        else
          {:ok, ~S|(return {:echo "mock"})|}
        end
      end

      {:ok, compiled} =
        SubAgent.compile(agent, llm: mock_llm, llm_registry: %{child_llm: mock_llm})

      # Provide LLM in registry
      runtime_llm = fn _ -> {:ok, ~S|(return {:echo "test"})|} end
      child_llm = fn _ -> {:ok, ~S|(return {:echo "from child_llm"})|} end

      result =
        compiled.execute.(%{input: "test"},
          llm: runtime_llm,
          llm_registry: %{child_llm: child_llm}
        )

      assert result.return.result == "from child_llm"
    end
  end
end
