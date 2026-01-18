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
      assert preview.user =~ "data/data"
      assert preview.user =~ "data/user_id"
      refute preview.system =~ "data/data"
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

  describe "redact_program/1" do
    test "replaces clojure code block with placeholder" do
      text = """
      Some reasoning here

      ```clojure
      (def x 1)
      (return {:value x})
      ```
      """

      result = Debug.redact_program(text)

      assert result =~ "Some reasoning here"
      assert result =~ "[program: see below]"
      refute result =~ "(def x 1)"
      refute result =~ "(return"
    end

    test "replaces lisp code block with placeholder" do
      text = """
      First I'll analyze the data.

      ```lisp
      (+ 1 2)
      ```
      """

      result = Debug.redact_program(text)

      assert result =~ "First I'll analyze the data."
      assert result =~ "[program: see below]"
      refute result =~ "(+ 1 2)"
    end

    test "replaces unmarked code block with placeholder" do
      text = """
      Here's my solution:

      ```
      (return {:done true})
      ```
      """

      result = Debug.redact_program(text)

      assert result =~ "Here's my solution:"
      assert result =~ "[program: see below]"
      refute result =~ "(return"
    end

    test "preserves text without code blocks" do
      text = "Just some reasoning without any code."

      result = Debug.redact_program(text)

      assert result == text
    end

    test "handles multiple code blocks" do
      text = """
      First attempt:
      ```clojure
      (+ 1 2)
      ```

      Actually, let me try:
      ```clojure
      (return 3)
      ```
      """

      result = Debug.redact_program(text)

      assert result =~ "First attempt:"
      assert result =~ "Actually, let me try:"
      # Both code blocks should be replaced
      refute result =~ "(+ 1 2)"
      refute result =~ "(return 3)"
      # Should have two placeholders
      assert length(String.split(result, "[program: see below]")) == 3
    end

    test "handles code block at start of text" do
      text = """
      ```clojure
      (return {:value 42})
      ```
      """

      result = Debug.redact_program(text)

      assert result =~ "[program: see below]"
      refute result =~ "(return"
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

    test "raw: true includes raw_response with code block redacted" do
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
      # Code block in Raw Response should be replaced with placeholder
      assert output =~ "[program: see below]"
      # The program should NOT appear twice (once in Raw Response, once in Program)
      # Raw Response should not contain the actual code block
      refute Regex.match?(~r/Raw Response:.*\(+ 1 2\)/s, output)
      # But Program section should still have the code
      assert output =~ "Program:"
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
(def expenses (tool/list_expenses))
(return {:total (count expenses)})
```|}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      output = capture_io(fn -> Debug.print_trace(step, view: :compressed) end)

      # Tool namespace should appear in compressed view
      assert output =~ ";; === tools ==="
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

    test "usage: true shows memory and system prompt ratio" do
      turns = [
        Turn.success(1, "```clojure\n(+ 1 2)\n```", "(+ 1 2)", 3, [], [], %{}),
        Turn.success(2, "```clojure\n(+ 3 4)\n```", "(+ 3 4)", 7, [], [], %{})
      ]

      step = %Step{
        return: 7,
        fail: nil,
        memory: %{},
        turns: turns,
        usage: %{
          duration_ms: 250,
          memory_bytes: 1_500_000,
          input_tokens: 1000,
          output_tokens: 200,
          system_prompt_tokens: 400,
          turns: 2
        }
      }

      output = capture_io(fn -> Debug.print_trace(step, usage: true) end)

      # Check memory is shown in human-readable format
      assert output =~ "Memory:"
      assert output =~ "1.4" or output =~ "1.5"
      assert output =~ "MB"

      # Check system prompt shows size and ratio
      # 400 tokens * 2 turns = 800 tokens = 80% of 1000 input tokens
      assert output =~ "System prompt:"
      assert output =~ "400"
      assert output =~ "est. size"
      assert output =~ "~80% of input"
    end

    test "wraps long programs across multiple lines" do
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

      # Should wrap across multiple lines (output contains multiple Program: lines with content)
      program_lines = output |> String.split("\n") |> Enum.filter(&(&1 =~ "(+ 1 2)"))
      assert length(program_lines) > 1
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
        turns: [Turn.success(1, "(* data/value 2)", "(* data/value 2)", 20, [], [], %{})],
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

  describe "print_trace/2 integration" do
    test "raw: true shows Raw Input for turn 1 even with empty context" do
      # Regression test: Turn 1 was missing "Raw Input" when:
      # 1. Single-shot mode (max_turns == 1) with no tools used run_single_shot
      #    which didn't set :current_messages in state
      # 2. Empty context no longer shows "No data available" placeholder
      agent = SubAgent.new(prompt: "Do something useful", max_turns: 1)

      llm = fn _input ->
        {:ok, "```clojure\n(+ 1 2)\n```"}
      end

      # Run with empty context (no context: option)
      {:ok, step} = SubAgent.run(agent, llm: llm)

      output = capture_io(fn -> Debug.print_trace(step, raw: true) end)

      # Turn 1 should show Raw Input
      assert output =~ "Raw Input:"
      assert output =~ "[user]"
      assert output =~ "Do something useful"
      # Empty context should NOT show placeholder text
      refute output =~ "No data available"
    end

    test "raw: true shows Raw Input for turn 1 with tools but empty data context" do
      # Tests the specific scenario from the bug report:
      # tools provided but no context: option
      agent =
        SubAgent.new(
          prompt: "Calculate expenses",
          tools: %{"list_expenses" => fn _ -> [%{amount: 100}] end},
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, "```clojure\n(tool/list_expenses)\n```"}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      output = capture_io(fn -> Debug.print_trace(step, raw: true) end)

      # Should show Raw Input with both mission and tools
      assert output =~ "Raw Input:"
      assert output =~ "Calculate expenses"
    end

    test "usage stats are populated from actual SubAgent run" do
      agent = SubAgent.new(prompt: "Add two numbers", max_turns: 1)

      llm = fn _input ->
        {:ok, %{content: "```clojure\n(+ 1 2)\n```", tokens: %{input: 500, output: 50}}}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      # Verify usage is populated
      assert step.usage.duration_ms >= 0
      assert step.usage.memory_bytes >= 0
      assert step.usage.input_tokens == 500
      assert step.usage.output_tokens == 50

      # Verify print_trace works with real data
      output = capture_io(fn -> Debug.print_trace(step, usage: true) end)

      assert output =~ "Input tokens:"
      assert output =~ "500"
      assert output =~ "Output tokens:"
      assert output =~ "50"
    end

    test "multi-turn agent populates correct usage stats" do
      agent = SubAgent.new(prompt: "Calculate sum", max_turns: 3)

      # Simulate multi-turn: first turn returns value, second turn uses *1
      llm = fn %{turn: turn} ->
        response =
          case turn do
            1 -> "(do 42)"
            2 -> "(return *1)"
            _ -> "(fail \"unexpected\")"
          end

        {:ok, %{content: "```clojure\n#{response}\n```", tokens: %{input: 600, output: 30}}}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      # Verify multi-turn stats
      assert step.usage.turns == 2
      assert step.usage.input_tokens == 1200
      assert step.usage.output_tokens == 60
      assert step.usage.llm_requests == 2
      assert step.usage.system_prompt_tokens > 0

      # Verify ratio calculation works with multiple turns
      output = capture_io(fn -> Debug.print_trace(step, usage: true) end)

      assert output =~ "Turns:"
      assert output =~ "2"
      # Should show ratio since we have system_prompt_tokens and multiple turns
      assert output =~ "% of input"
    end

    test "print_trace shows memory when present" do
      agent = SubAgent.new(prompt: "Return a list", max_turns: 1)

      llm = fn _input ->
        # Return something that uses some memory
        {:ok, %{content: "```clojure\n(range 100)\n```", tokens: %{input: 400, output: 20}}}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      # Memory should be captured from sandbox execution
      assert step.usage.memory_bytes >= 0

      output = capture_io(fn -> Debug.print_trace(step, usage: true) end)

      # Memory line should appear if memory_bytes > 0
      if step.usage.memory_bytes > 0 do
        assert output =~ "Memory:"
      end
    end

    test "usage: true shows tool call statistics" do
      # Create turns with tool calls
      turns = [
        Turn.success(
          1,
          "```clojure\n(tool/search \"foo\")\n```",
          "(tool/search \"foo\")",
          %{},
          [],
          [%{name: "search", args: %{query: "foo"}, result: ["result1"]}],
          %{}
        ),
        Turn.success(
          2,
          "```clojure\n(tool/search \"bar\")\n```",
          "(tool/search \"bar\")",
          %{},
          [],
          [
            %{name: "search", args: %{query: "bar"}, result: ["result2"]},
            %{name: "fetch", args: %{url: "http://example.com"}, result: "html"}
          ],
          %{}
        )
      ]

      step = %Step{
        return: %{done: true},
        fail: nil,
        memory: %{},
        turns: turns,
        usage: %{duration_ms: 100, memory_bytes: 0, input_tokens: 500, output_tokens: 50}
      }

      output = capture_io(fn -> Debug.print_trace(step, usage: true) end)

      # Should show Tool Calls section
      assert output =~ "Tool Calls"
      # Should show search was called 2 times
      assert output =~ "search"
      assert output =~ "× 2"
      # Should show fetch was called 1 time
      assert output =~ "fetch"
      assert output =~ "× 1"
      # Should show sample arguments in Clojure format (what LLM sees)
      assert output =~ ":query"
    end

    test "usage: true shows tool stats in Clojure format" do
      # Tool stats uses Clojure format to match what LLM sees
      turns = [
        Turn.success(
          1,
          "...",
          "...",
          %{},
          [],
          [%{name: "process", args: %{query: "test", limit: 10}, result: "ok"}],
          %{}
        )
      ]

      step = %Step{
        return: %{done: true},
        fail: nil,
        memory: %{},
        turns: turns,
        usage: %{duration_ms: 100, memory_bytes: 0}
      }

      output = capture_io(fn -> Debug.print_trace(step, usage: true) end)

      # Should show Tool Calls section with args in Clojure format
      assert output =~ "Tool Calls"
      assert output =~ "process"
      # Args shown in Clojure format (same as what LLM sees)
      assert output =~ ":query"
      assert output =~ ":limit"
    end

    test "usage: true does not show tool section when no tools called" do
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

      output = capture_io(fn -> Debug.print_trace(step, usage: true) end)

      # Should show Usage section but not Tool Calls section
      assert output =~ "Usage"
      refute output =~ "Tool Calls"
    end
  end
end
