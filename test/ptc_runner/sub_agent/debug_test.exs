defmodule PtcRunner.SubAgent.DebugTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias PtcRunner.{Step, SubAgent, Turn}
  alias PtcRunner.SubAgent.Debug

  describe "preview_prompt/2" do
    test "returns system prompt, user message, and tool schemas" do
      agent =
        SubAgent.new(
          prompt: "Find emails for {{user}}",
          signature: "(user :string) -> {count :int}",
          tools: %{"list_emails" => fn _ -> [] end}
        )

      preview = SubAgent.preview_prompt(agent, context: %{user: "alice"})

      assert is_binary(preview.system)
      assert preview.system =~ "PTC-Lisp"
      # System prompt is cacheable - does NOT include mission
      refute preview.system =~ "# Mission"
      # User message includes context sections + mission
      assert preview.user =~ "# Mission"
      assert preview.user =~ "Find emails for alice"
      assert length(preview.tool_schemas) == 1
      assert hd(preview.tool_schemas).name == "list_emails"
    end

    test "expands template placeholders correctly" do
      agent =
        SubAgent.new(
          prompt: "Analyze {{items}} for user {{user}}",
          signature: "(items [:int], user :string) -> {count :int}"
        )

      preview = SubAgent.preview_prompt(agent, context: %{items: [1, 2, 3], user: "bob"})

      # Template expansion converts lists to strings - check it contains the expected parts
      assert preview.user =~ "Analyze"
      assert preview.user =~ "for user bob"
      assert is_binary(preview.user)
    end

    test "works with empty context" do
      agent = SubAgent.new(prompt: "Do something")
      preview = SubAgent.preview_prompt(agent)

      assert is_binary(preview.system)
      # User message includes context sections + mission
      assert preview.user =~ "# Mission"
      assert preview.user =~ "Do something"
      assert preview.tool_schemas == []
    end

    test "generates user message with data inventory" do
      agent = SubAgent.new(prompt: "Process {{data}}")

      preview =
        SubAgent.preview_prompt(agent, context: %{data: [1, 2, 3], user_id: 123})

      # Data inventory is in user message (not system) for cacheability
      assert preview.user =~ "ctx/data"
      assert preview.user =~ "ctx/user_id"
      refute preview.system =~ "ctx/data"
    end
  end

  describe "raw_response always captured in turns" do
    test "turns always contain raw_response" do
      agent = SubAgent.new(prompt: "Test", max_turns: 2)

      llm = fn %{turn: t} ->
        case t do
          1 ->
            {:ok, ~S|Some reasoning here

```clojure
{:intermediate "value"}
```|}

          2 ->
            {:ok, ~S|Final reasoning

```clojure
(return {:done true})
```|}
        end
      end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{})

      # Turns should always contain raw_response (no debug: true needed)
      [turn1, turn2] = step.turns
      assert turn1.raw_response =~ "intermediate"
      assert turn1.raw_response =~ "Some reasoning here"
      assert turn2.raw_response =~ "return"
      assert turn2.raw_response =~ "Final reasoning"
    end

    test "debug: option is no longer required" do
      agent = SubAgent.new(prompt: "Test", max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|```clojure
(return {:done true})
```|}
      end

      # With or without debug:, turns capture raw_response
      {:ok, step_no_debug} = SubAgent.run(agent, llm: llm, context: %{})
      {:ok, step_with_debug} = SubAgent.run(agent, llm: llm, context: %{}, debug: true)

      [turn_no_debug] = step_no_debug.turns
      [turn_with_debug] = step_with_debug.turns

      # Both have raw_response
      assert turn_no_debug.raw_response != nil
      assert turn_with_debug.raw_response != nil
      assert turn_no_debug.raw_response == turn_with_debug.raw_response
    end
  end

  describe "trace filtering" do
    test "trace: true captures all traces" do
      agent = SubAgent.new(prompt: "Test", max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|```clojure
(return {:value 42})
```|}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm, trace: true)

      assert is_list(step.turns)
      assert length(step.turns) == 1
    end

    test "trace: false disables tracing" do
      agent = SubAgent.new(prompt: "Test", max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|```clojure
(return {:value 42})
```|}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm, trace: false)

      assert step.turns == nil
    end

    test "trace: :on_error keeps trace only on failure" do
      agent = SubAgent.new(prompt: "Test", max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|```clojure
(return {:value 42})
```|}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm, trace: :on_error)

      # Success - no trace
      assert step.turns == nil
    end

    test "trace: :on_error keeps trace when execution fails" do
      agent = SubAgent.new(prompt: "Test", max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|```clojure
(fail {:reason :test :message "Test error"})
```|}
      end

      {:error, step} = SubAgent.run(agent, llm: llm, trace: :on_error)

      # Failure - trace should be present
      assert is_list(step.turns)
      assert length(step.turns) == 1
    end
  end

  describe "Debug.print_trace/2 with turns" do
    test "prints trace for successful execution" do
      turns = [
        Turn.success(1, "```clojure\n(+ 1 2)\n```", "(+ 1 2)", 3, [], [], %{})
      ]

      step = %Step{
        return: 3,
        fail: nil,
        memory: %{},
        turns: turns,
        usage: %{duration_ms: 100, memory_bytes: 0}
      }

      output = capture_io(fn -> Debug.print_trace(step) end)

      assert output =~ "Turn 1"
      assert output =~ "(+ 1 2)"
      assert output =~ "Result:"
    end

    test "handles step with no turns" do
      step = %Step{
        return: 3,
        fail: nil,
        memory: %{},
        turns: nil,
        usage: %{duration_ms: 100, memory_bytes: 0}
      }

      output = capture_io(fn -> Debug.print_trace(step) end)

      assert output =~ "No trace available"
    end

    test "handles empty turns" do
      step = %Step{
        return: 3,
        fail: nil,
        memory: %{},
        turns: [],
        usage: %{duration_ms: 100, memory_bytes: 0}
      }

      output = capture_io(fn -> Debug.print_trace(step) end)

      assert output =~ "Empty trace"
    end

    test "raw: true includes raw_response" do
      turns = [
        Turn.success(
          1,
          "Some reasoning here\n\n```clojure\n(+ 1 2)\n```",
          "(+ 1 2)",
          3,
          [],
          [],
          %{}
        )
      ]

      step = %Step{
        return: 3,
        fail: nil,
        memory: %{},
        turns: turns,
        usage: %{duration_ms: 100, memory_bytes: 0}
      }

      output = capture_io(fn -> Debug.print_trace(step, raw: true) end)

      assert output =~ "Raw Response:"
      assert output =~ "Some reasoning here"
    end

    test "raw: false (default) omits raw_response" do
      turns = [
        Turn.success(
          1,
          "Some reasoning here\n\n```clojure\n(+ 1 2)\n```",
          "(+ 1 2)",
          3,
          [],
          [],
          %{}
        )
      ]

      step = %Step{
        return: 3,
        fail: nil,
        memory: %{},
        turns: turns,
        usage: %{duration_ms: 100, memory_bytes: 0}
      }

      output = capture_io(fn -> Debug.print_trace(step) end)

      refute output =~ "Raw Response:"
      refute output =~ "Some reasoning here"
    end

    test "view: :compressed shows compressed format" do
      turns = [
        Turn.success(1, "```clojure\n(+ 1 2)\n```", "(+ 1 2)", 3, [], [], %{})
      ]

      step = %Step{
        return: 3,
        fail: nil,
        memory: %{},
        turns: turns,
        usage: %{duration_ms: 100, memory_bytes: 0}
      }

      output = capture_io(fn -> Debug.print_trace(step, view: :compressed) end)

      assert output =~ "Compressed View"
      assert output =~ "[system]"
      assert output =~ "[user]"
    end

    test "view: :compressed includes actual mission text (MSG-007)" do
      # This tests the spec requirement that the mission is NEVER removed
      # See docs/specs/message-history-optimization.md line 450:
      # "CRITICAL: The mission is NEVER removed."
      agent = SubAgent.new(prompt: "What is the sum of the first 5 prime numbers?")

      llm = fn _ ->
        {:ok, ~S|```clojure
(return {:sum 28, :primes [2 3 5 7 11]})
```|}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      output = capture_io(fn -> Debug.print_trace(step, view: :compressed) end)

      # The actual mission text should appear in the compressed view,
      # not a placeholder like "(mission)"
      assert output =~ "What is the sum of the first 5 prime numbers?"
      refute output =~ "(mission)"
    end

    test "view: :compressed includes tool definitions" do
      # This tests that tool/ namespace appears in compressed view
      # See docs/specs/message-history-optimization.md lines 258-259
      agent =
        SubAgent.new(
          prompt: "List the expenses",
          tools: %{"list_expenses" => fn _ -> [%{amount: 100}] end}
        )

      llm = fn _ ->
        {:ok, ~S|```clojure
(def expenses (ctx/list_expenses))
(return {:total (count expenses)})
```|}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      output = capture_io(fn -> Debug.print_trace(step, view: :compressed) end)

      # Tool namespace should appear in compressed view
      assert output =~ ";; === tool/ ==="
      assert output =~ "tool/list_expenses"
    end

    test "usage: true shows token stats" do
      turns = [
        Turn.success(1, "```clojure\n(+ 1 2)\n```", "(+ 1 2)", 3, [], [], %{})
      ]

      step = %Step{
        return: 3,
        fail: nil,
        memory: %{},
        turns: turns,
        usage: %{
          duration_ms: 100,
          memory_bytes: 0,
          input_tokens: 500,
          output_tokens: 100,
          total_tokens: 600
        }
      }

      output = capture_io(fn -> Debug.print_trace(step, usage: true) end)

      assert output =~ "Usage"
      assert output =~ "Input tokens:"
      assert output =~ "500"
    end

    test "truncates long programs" do
      long_program = String.duplicate("(+ 1 2) ", 50)

      turns = [
        Turn.success(1, "```clojure\n#{long_program}\n```", long_program, 3, [], [], %{})
      ]

      step = %Step{
        return: 3,
        fail: nil,
        memory: %{},
        turns: turns,
        usage: %{duration_ms: 100, memory_bytes: 0}
      }

      output = capture_io(fn -> Debug.print_trace(step) end)

      # Should contain truncation indicator
      assert output =~ "..."
    end
  end

  describe "Debug.print_chain/1" do
    test "prints multiple steps in chain" do
      step1 = %Step{
        return: %{value: 10},
        fail: nil,
        memory: %{},
        turns: [Turn.success(1, "(+ 5 5)", "(+ 5 5)", 10, [], [], %{})],
        usage: %{duration_ms: 50, memory_bytes: 0}
      }

      step2 = %Step{
        return: %{value: 20},
        fail: nil,
        memory: %{},
        turns: [Turn.success(1, "(* ctx/value 2)", "(* ctx/value 2)", 20, [], [], %{})],
        usage: %{duration_ms: 75, memory_bytes: 0}
      }

      output = capture_io(fn -> Debug.print_chain([step1, step2]) end)

      assert output =~ "Agent Chain"
      assert output =~ "Step 1/2"
      assert output =~ "Step 2/2"
      assert output =~ "50ms"
      assert output =~ "75ms"
    end

    test "shows failure status in chain" do
      step1 = %Step{
        return: %{value: 10},
        fail: nil,
        memory: %{},
        turns: [],
        usage: %{duration_ms: 50, memory_bytes: 0}
      }

      step2 = %Step{
        return: nil,
        fail: %{reason: :test_error, message: "Test failure"},
        memory: %{},
        turns: [],
        usage: %{duration_ms: 75, memory_bytes: 0}
      }

      output = capture_io(fn -> Debug.print_chain([step1, step2]) end)

      assert output =~ "ok"
      assert output =~ "X"
      assert output =~ "test_error"
      assert output =~ "Test failure"
    end

    test "handles empty chain" do
      output = capture_io(fn -> Debug.print_chain([]) end)

      # Should not crash, just return empty
      assert output == ""
    end
  end
end
