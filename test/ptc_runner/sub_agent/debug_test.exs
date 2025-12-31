defmodule PtcRunner.SubAgent.DebugTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias PtcRunner.{Step, SubAgent}
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
      assert preview.user == "Find emails for alice"
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
      assert preview.user == "Do something"
      assert preview.tool_schemas == []
    end

    test "generates system prompt with data inventory" do
      agent = SubAgent.new(prompt: "Process {{data}}")

      preview =
        SubAgent.preview_prompt(agent, context: %{data: [1, 2, 3], user_id: 123})

      assert preview.system =~ "ctx/data"
      assert preview.system =~ "ctx/user_id"
    end
  end

  describe "debug mode" do
    test "captures execution with debug: true" do
      agent = SubAgent.new(prompt: "Test", max_turns: 2)

      llm = fn %{turn: t} ->
        case t do
          1 -> {:ok, ~S|```clojure
{:intermediate "value"}
```|}
          2 -> {:ok, ~S|```clojure
(call "return" {:done true})
```|}
        end
      end

      output =
        capture_io(fn ->
          {:ok, _step} = SubAgent.run(agent, llm: llm, context: %{}, debug: true)
        end)

      # Debug mode should print turn information
      assert output =~ "[Turn 1]"
      assert output =~ "LLM response"
      assert output =~ "Execution result"
    end

    test "does not log when debug: false" do
      agent = SubAgent.new(prompt: "Test", max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|```clojure
(call "return" {:done true})
```|}
      end

      output =
        capture_io(fn ->
          {:ok, _step} = SubAgent.run(agent, llm: llm, context: %{}, debug: false)
        end)

      # Should not contain debug output
      refute output =~ "[Turn"
    end

    test "debug: true captures extra trace fields" do
      agent = SubAgent.new(prompt: "Test", max_turns: 2)
      llm = fn _ -> {:ok, ~S|(call "return" {:done true})|} end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{foo: 1}, debug: true)

      [turn1] = step.trace
      assert Map.has_key?(turn1, :context_snapshot)
      assert Map.has_key?(turn1, :memory_snapshot)
      assert Map.has_key?(turn1, :full_prompt)
      assert turn1.context_snapshot == %{foo: 1}
    end
  end

  describe "trace filtering" do
    test "trace: true captures all traces" do
      agent = SubAgent.new(prompt: "Test", max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|```clojure
(call "return" {:value 42})
```|}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm, trace: true)

      assert is_list(step.trace)
      assert length(step.trace) == 1
    end

    test "trace: false disables tracing" do
      agent = SubAgent.new(prompt: "Test", max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|```clojure
(call "return" {:value 42})
```|}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm, trace: false)

      assert step.trace == nil
    end

    test "trace: :on_error keeps trace only on failure" do
      agent = SubAgent.new(prompt: "Test", max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|```clojure
(call "return" {:value 42})
```|}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm, trace: :on_error)

      # Success - no trace
      assert step.trace == nil
    end

    test "trace: :on_error keeps trace when execution fails" do
      agent = SubAgent.new(prompt: "Test", max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|```clojure
(call "fail" {:reason :test :message "Test error"})
```|}
      end

      {:error, step} = SubAgent.run(agent, llm: llm, trace: :on_error)

      # Failure - trace should be present
      assert is_list(step.trace)
      assert length(step.trace) == 1
    end
  end

  describe "Debug.print_trace/1" do
    test "prints trace for successful execution" do
      trace = [
        %{
          turn: 1,
          program: "(+ 1 2)",
          result: 3,
          tool_calls: []
        }
      ]

      step = %Step{
        return: 3,
        fail: nil,
        memory: %{},
        trace: trace,
        usage: %{duration_ms: 100, memory_bytes: 0}
      }

      output = capture_io(fn -> Debug.print_trace(step) end)

      assert output =~ "Turn 1"
      assert output =~ "(+ 1 2)"
      assert output =~ "Result:"
    end

    test "handles step with no trace" do
      step = %Step{
        return: 3,
        fail: nil,
        memory: %{},
        trace: nil,
        usage: %{duration_ms: 100, memory_bytes: 0}
      }

      output = capture_io(fn -> Debug.print_trace(step) end)

      assert output =~ "No trace available"
    end

    test "handles empty trace" do
      step = %Step{
        return: 3,
        fail: nil,
        memory: %{},
        trace: [],
        usage: %{duration_ms: 100, memory_bytes: 0}
      }

      output = capture_io(fn -> Debug.print_trace(step) end)

      assert output =~ "Empty trace"
    end

    test "truncates long programs" do
      long_program = String.duplicate("(+ 1 2) ", 50)

      trace = [
        %{
          turn: 1,
          program: long_program,
          result: 3,
          tool_calls: []
        }
      ]

      step = %Step{
        return: 3,
        fail: nil,
        memory: %{},
        trace: trace,
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
        trace: [%{turn: 1, program: "(+ 5 5)", result: 10, tool_calls: []}],
        usage: %{duration_ms: 50, memory_bytes: 0}
      }

      step2 = %Step{
        return: %{value: 20},
        fail: nil,
        memory: %{},
        trace: [%{turn: 1, program: "(* ctx/value 2)", result: 20, tool_calls: []}],
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
        trace: [],
        usage: %{duration_ms: 50, memory_bytes: 0}
      }

      step2 = %Step{
        return: nil,
        fail: %{reason: :test_error, message: "Test failure"},
        memory: %{},
        trace: [],
        usage: %{duration_ms: 75, memory_bytes: 0}
      }

      output = capture_io(fn -> Debug.print_chain([step1, step2]) end)

      assert output =~ "✓"
      assert output =~ "✗"
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
