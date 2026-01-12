defmodule PtcRunner.SubAgent.LoopTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop

  import PtcRunner.TestSupport.SubAgentTestHelpers

  doctest Loop
  doctest Loop.LLMRetry
  doctest Loop.ResponseHandler

  describe "run/2 with successful execution" do
    test "single turn with explicit return" do
      agent =
        SubAgent.new(
          prompt: "Calculate {{x}} + {{y}}",
          tools: %{},
          max_turns: 5
        )

      llm = fn %{messages: _} ->
        {:ok, ~S|```clojure
(return {:result (+ ctx/x ctx/y)})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{x: 5, y: 3})

      assert step.return == %{result: 8}
      assert step.fail == nil
      assert length(step.trace) == 1
      assert step.usage.turns == 1
    end

    test "multi-turn loop accumulates trace" do
      turn_counter = :counters.new(1, [:atomics])

      agent =
        SubAgent.new(
          prompt: "Do calculation",
          tools: %{},
          max_turns: 5
        )

      llm = fn %{turn: turn} ->
        :counters.put(turn_counter, 1, turn)

        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          2 -> {:ok, ~S|```clojure
(return {:result 42})
```|}
          _ -> {:ok, "```clojure\n99\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{result: 42}
      assert length(step.trace) == 2
      assert step.usage.turns == 2
    end

    test "expands template placeholders in prompt" do
      agent =
        SubAgent.new(
          prompt: "Process {{name}} with {{value}}",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{messages: messages} ->
        first_message = hd(messages)
        assert first_message.role == :user
        assert first_message.content =~ "Process alice with 42"
        {:ok, ~S|```clojure
(return {:value 100})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{name: "alice", value: 42})

      assert step.return == %{value: 100}
    end
  end

  describe "run/2 with max_turns exceeded" do
    test "returns error when max_turns exceeded" do
      agent = test_agent()

      # LLM that causes errors, forcing retries
      llm = fn %{turn: _} ->
        {:ok, "```clojure\n(int Double/POSITIVE_INFINITY)\n```"}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.fail.reason == :max_turns_exceeded
      assert step.fail.message =~ "Exceeded max_turns limit of 2"
      assert step.return == nil
      assert step.usage.turns == 2
    end
  end

  describe "run/2 with LLM errors" do
    test "returns error when LLM call fails" do
      agent = test_agent(max_turns: 3)

      llm = fn _ ->
        {:error, :network_timeout}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.fail.reason == :llm_error
      assert step.fail.message =~ "LLM call failed"
      assert step.fail.message =~ ":network_timeout"
    end
  end

  describe "response parsing" do
    test "extracts code from clojure code block" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|Here is the code:
```clojure
(return {:value 42})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.trace |> hd() |> Map.get(:program) == ~S|(return {:value 42})|
    end

    test "extracts code from lisp code block" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|```lisp
(return {:value 42})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.trace |> hd() |> Map.get(:program) == ~S|(return {:value 42})|
    end

    test "falls back to raw s-expression" do
      agent = test_agent()

      llm = fn _ -> {:ok, ~S|(return {:value 42})|} end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.trace |> hd() |> Map.get(:program) == ~S|(return {:value 42})|
    end
  end

  describe "run/2 with execution errors" do
    test "feeds error back to LLM on Lisp execution failure" do
      turn_counter = :counters.new(1, [:atomics])

      agent =
        SubAgent.new(
          prompt: "Do calculation",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{turn: turn, messages: messages} ->
        :counters.put(turn_counter, 1, turn)

        case turn do
          1 ->
            {:ok, "```clojure\n(int Double/POSITIVE_INFINITY)\n```"}

          2 ->
            # Verify error was fed back
            last_message = List.last(messages)
            assert last_message.role == :user
            assert last_message.content =~ "Error:"

            {:ok, ~S|```clojure
(return {:value 42})
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{value: 42}
      assert :counters.get(turn_counter, 1) == 2
    end

    test "feeds no-code error back to LLM" do
      turn_counter = :counters.new(1, [:atomics])

      agent =
        SubAgent.new(
          prompt: "Do calculation",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{turn: turn, messages: messages} ->
        :counters.put(turn_counter, 1, turn)

        case turn do
          1 ->
            {:ok, "I cannot do that."}

          2 ->
            # Verify error was fed back
            last_message = List.last(messages)
            assert last_message.role == :user
            assert last_message.content =~ "No valid PTC-Lisp code found"

            {:ok, ~S|```clojure
(return {:value 100})
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{value: 100}
      assert :counters.get(turn_counter, 1) == 2
    end
  end

  describe "run/2 with tools" do
    test "multi-turn with tool execution" do
      turn_counter = :counters.new(1, [:atomics])

      tools = %{
        "get-value" => fn %{key: _k} -> %{value: 42} end
      }

      agent =
        SubAgent.new(
          prompt: "Get the value and return it",
          tools: tools,
          max_turns: 5
        )

      llm = fn %{turn: turn} ->
        :counters.put(turn_counter, 1, turn)

        case turn do
          1 -> {:ok, ~S|```clojure
(ctx/get-value {:key "x"})
```|}
          2 -> {:ok, ~S|```clojure
(return {:result {:value 42}})
```|}
          _ -> {:ok, "Should not reach here"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{result: %{value: 42}}
      assert :counters.get(turn_counter, 1) == 2
    end
  end

  describe "run/2 with context and memory" do
    test "provides context via ctx/ namespace" do
      agent =
        SubAgent.new(
          prompt: "Use context",
          tools: %{},
          max_turns: 2
        )

      llm = fn _ ->
        {:ok, ~S|```clojure
(return {:value (get ctx/data "key")})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{data: %{"key" => "value"}})

      assert step.return == %{value: "value"}
    end

    test "makes previous turn error available as ctx/fail" do
      turn_counter = :counters.new(1, [:atomics])

      agent =
        SubAgent.new(
          prompt: "Handle error",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{turn: turn} ->
        :counters.put(turn_counter, 1, turn)

        case turn do
          1 ->
            {:ok, "```clojure\n(int Double/POSITIVE_INFINITY)\n```"}

          2 ->
            # On turn 2, ctx/fail should be available
            {:ok, ~S|```clojure
(return {:fail ctx/fail})
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      # The second turn should successfully access ctx/fail
      assert is_map(step.return)
      assert Map.has_key?(step.return, :fail)
      assert is_map(step.return.fail)
      assert Map.has_key?(step.return.fail, :reason)
      assert :counters.get(turn_counter, 1) == 2
    end
  end

  describe "run/2 message history" do
    test "builds message history across turns" do
      messages_log = Agent.start_link(fn -> [] end) |> elem(1)

      agent =
        SubAgent.new(
          prompt: "Initial prompt",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{messages: messages, turn: turn} ->
        Agent.update(messages_log, fn log -> [{turn, messages} | log] end)

        case turn do
          1 ->
            # Turn 1 should have just the user message
            assert length(messages) == 1
            assert hd(messages).role == :user
            {:ok, "```clojure\n(int Double/POSITIVE_INFINITY)\n```"}

          2 ->
            # Turn 2 should have: user, assistant, user (error feedback)
            assert length(messages) == 3
            {:ok, ~S|```clojure
(return {:value 42})
```|}
        end
      end

      {:ok, _step} = Loop.run(agent, llm: llm, context: %{})

      log = Agent.get(messages_log, & &1) |> Enum.reverse()
      assert length(log) == 2

      # Verify turn 1 messages
      {1, turn1_messages} = Enum.at(log, 0)
      assert length(turn1_messages) == 1

      # Verify turn 2 messages
      {2, turn2_messages} = Enum.at(log, 1)
      assert length(turn2_messages) == 3
      assert Enum.at(turn2_messages, 1).role == :assistant
      assert Enum.at(turn2_messages, 2).role == :user
    end
  end

  describe "run/2 trace entries" do
    test "builds trace entries correctly" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|```clojure
(return {:value (+ 1 2)})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert length(step.trace) == 1

      trace_entry = hd(step.trace)
      assert trace_entry.turn == 1
      assert trace_entry.program == ~S|(return {:value (+ 1 2)})|
      assert trace_entry.result == %{value: 3}
      assert trace_entry.tool_calls == []
    end
  end

  describe "run/2 usage metrics" do
    test "includes duration_ms in usage" do
      agent = test_agent()
      llm = simple_return_llm()

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert is_integer(step.usage.duration_ms)
      assert step.usage.duration_ms >= 0
    end

    test "includes turn count in usage" do
      agent = test_agent(max_turns: 3)
      llm = simple_return_llm()

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.usage.turns == 1
    end
  end

  describe "run/2 with llm_input structure" do
    test "provides system prompt in llm_input" do
      agent = test_agent()

      llm = fn %{system: system} ->
        assert is_binary(system)
        assert system =~ "PTC-Lisp"
        {:ok, ~S|```clojure
(return {:value 42})
```|}
      end

      {:ok, _step} = Loop.run(agent, llm: llm, context: %{})
    end

    test "provides turn number in llm_input" do
      agent = test_agent(max_turns: 3)

      llm = fn %{turn: turn} ->
        assert is_integer(turn)
        assert turn >= 1
        {:ok, ~S|```clojure
(return {:value 42})
```|}
      end

      {:ok, _step} = Loop.run(agent, llm: llm, context: %{})
    end

    test "provides tool_names in llm_input" do
      tools = %{
        "get-value" => fn _ -> 42 end,
        "set-value" => fn _ -> :ok end
      }

      agent = test_agent(tools: tools)

      llm = fn %{tool_names: tool_names} ->
        assert is_list(tool_names)
        assert "get-value" in tool_names
        assert "set-value" in tool_names
        {:ok, ~S|```clojure
(return {:value 42})
```|}
      end

      {:ok, _step} = Loop.run(agent, llm: llm, context: %{})
    end
  end

  describe "(return value) syntactic sugar" do
    test "return shorthand works same as call return" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|```clojure
(return {:result 42})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{result: 42}
      assert step.fail == nil
    end

    test "return with expression value" do
      agent = test_agent(prompt: "Add numbers")

      llm = fn _ ->
        {:ok, ~S|```clojure
(return {:sum (+ ctx/x ctx/y)})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{x: 10, y: 5})

      assert step.return == %{sum: 15}
    end

    test "return in let binding" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|```clojure
(let [x (+ 1 2)]
  (return {:value x}))
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{value: 3}
    end

    test "return in conditional" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|```clojure
(if (> ctx/n 0)
  (return {:sign :positive})
  (return {:sign :non-positive}))
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{n: 5})

      assert step.return == %{sign: :positive}
    end
  end

  describe "(fail error) syntactic sugar" do
    test "fail shorthand produces user error" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|```clojure
(fail {:reason :bad-input})
```|}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.fail.reason == :failed
    end

    test "fail with expression value" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|```clojure
(fail {:error (str "code: " ctx/code)})
```|}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{code: 500})

      assert step.fail.reason == :failed
    end

    test "fail alone in code" do
      agent = test_agent()

      # Test fail without return in the same code
      llm = fn _ ->
        {:ok, ~S|```clojure
(fail {:reason :missing-data})
```|}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.fail.reason == :failed
    end

    test "fail in unevaluated conditional branch does not cause failure" do
      # Regression test for bug where (fail ...) in unevaluated branch
      # was detected by static code analysis and incorrectly caused failure
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|```clojure
(if true
  (return "success")
  (fail {:reason :never-called :message "This should never be reached"}))
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == "success"
    end

    test "return in unevaluated conditional branch does not trigger return" do
      # Regression test for symmetric bug with (return ...) in unevaluated branch
      agent = test_agent(max_turns: 2)
      call_count = :counters.new(1, [:atomics])

      llm = fn _ ->
        count = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, count)

        if count == 1 do
          # First call: return in unevaluated branch, else returns 42
          {:ok, ~S|(if false (return "wrong") 42)|}
        else
          # Second call: explicit return
          {:ok, ~S|(return 42)|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == 42
      # Should have taken 2 turns (first turn didn't trigger return)
      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "memory limit configuration" do
    test "memory_limit field can be set" do
      agent = test_agent(memory_limit: 1000)

      assert agent.memory_limit == 1000
    end

    test "memory_limit defaults to 1MB" do
      agent = test_agent()

      assert agent.memory_limit == 1_048_576
    end

    test "memory_limit can be nil" do
      agent = test_agent(memory_limit: nil)

      assert agent.memory_limit == nil
    end

    test "memory_limit is enforced during execution" do
      turn_counter = :counters.new(1, [:atomics])

      tools = %{
        "get-large" => fn %{} ->
          # Return a large string that will exceed 200 bytes when stored via def
          "this is a very long string designed to exceed the memory limit when stored in memory along with the erlang encoding overhead so we can test that the memory limit enforcement is working correctly"
        end
      }

      agent =
        SubAgent.new(
          prompt: "Store large data",
          tools: tools,
          memory_limit: 200,
          max_turns: 3
        )

      llm = fn %{turn: turn} ->
        :counters.put(turn_counter, 1, turn)

        case turn do
          1 ->
            # V2: Use def to explicitly store data in memory
            # This will exceed the memory limit
            {:ok, ~S|```clojure
(def large-data (ctx/get-large {}))
```|}

          _ ->
            {:ok, "Should not reach here"}
        end
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.fail.reason == :memory_limit_exceeded
      assert step.fail.message =~ "Memory limit exceeded"
      assert step.usage.turns == 1
    end
  end

  describe "turn feedback format" do
    test "shows correct turn number and remaining count" do
      agent =
        SubAgent.new(
          prompt: "Multi-turn task",
          tools: %{},
          max_turns: 5
        )

      llm = fn %{turn: turn, messages: messages} ->
        case turn do
          1 ->
            {:ok, "```clojure\n(+ 1 2)\n```"}

          2 ->
            # After turn 1, feedback should say "Turn 2 of 5 (4 remaining)"
            last_message = List.last(messages)
            assert last_message.content =~ "Turn 2 of 5 (4 remaining)"
            {:ok, "```clojure\n(+ 3 4)\n```"}

          3 ->
            # After turn 2, feedback should say "Turn 3 of 5 (3 remaining)"
            last_message = List.last(messages)
            assert last_message.content =~ "Turn 3 of 5 (3 remaining)"
            {:ok, "```clojure\n(return 42)\n```"}

          _ ->
            {:ok, "```clojure\n(return 99)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.return == 42
      assert step.usage.turns == 3
    end

    test "shows FINAL TURN warning on last turn" do
      agent =
        SubAgent.new(
          prompt: "Multi-turn task",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{turn: turn, messages: messages} ->
        case turn do
          1 ->
            {:ok, "```clojure\n(+ 1 2)\n```"}

          2 ->
            {:ok, "```clojure\n(+ 3 4)\n```"}

          3 ->
            # After turn 2 with max_turns=3, should show FINAL TURN warning
            last_message = List.last(messages)
            assert last_message.content =~ "FINAL TURN"
            {:ok, "```clojure\n(return 42)\n```"}

          _ ->
            {:ok, "```clojure\n(return 99)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.return == 42
    end

    test "feedback shows only println output, not expression results" do
      agent =
        SubAgent.new(
          prompt: "Search task",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{turn: turn, messages: messages} ->
        case turn do
          1 ->
            # Return a large list without println - should NOT appear in feedback
            {:ok, "```clojure\n[1 2 3 4 5 6 7 8 9 10]\n```"}

          2 ->
            # After turn 1, feedback should NOT contain the list result
            last_message = List.last(messages)
            refute last_message.content =~ "[1 2 3"
            # Use println to see output
            {:ok, "```clojure\n(println \"count:\" 42)\n:done\n```"}

          3 ->
            # After turn 2, feedback should contain println output but not :done
            last_message = List.last(messages)
            assert last_message.content =~ "count: 42"
            refute last_message.content =~ ":done"
            {:ok, "```clojure\n(return :finished)\n```"}

          _ ->
            {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.return == :finished
    end

    test "println output is truncated when exceeding feedback_max_chars" do
      agent =
        SubAgent.new(
          prompt: "Test task",
          tools: %{},
          max_turns: 3,
          # Small limit to trigger truncation
          format_options: [feedback_max_chars: 50]
        )

      llm = fn %{turn: turn, messages: messages} ->
        case turn do
          1 ->
            # Print a lot of output that exceeds 50 chars
            {:ok,
             ~S"""
             ```clojure
             (println "Line 1: some text here")
             (println "Line 2: more text here")
             (println "Line 3: even more text")
             :done
             ```
             """}

          2 ->
            # Verify truncation hint appears
            last_message = List.last(messages)
            assert last_message.content =~ "Line 1"
            assert last_message.content =~ "truncated"
            {:ok, "```clojure\n(return :done)\n```"}

          _ ->
            {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.return == :done
    end
  end

  describe "collect_messages option" do
    test "collect_messages: false (default) returns nil messages" do
      agent = test_agent()
      llm = simple_return_llm()

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.messages == nil
    end

    test "collect_messages: true returns messages with system prompt" do
      agent = test_agent()
      llm = simple_return_llm()

      {:ok, step} = Loop.run(agent, llm: llm, context: %{}, collect_messages: true)

      assert is_list(step.messages)
      assert length(step.messages) == 3

      # First message is system prompt
      [system_msg, user_msg, assistant_msg] = step.messages
      assert system_msg.role == :system
      assert system_msg.content =~ "PTC-Lisp"

      # Second is user (prompt)
      assert user_msg.role == :user

      # Third is assistant (response)
      assert assistant_msg.role == :assistant
    end

    test "multi-turn conversation captures full history" do
      agent =
        SubAgent.new(
          prompt: "Multi-turn test",
          tools: %{},
          max_turns: 5
        )

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          2 -> {:ok, "```clojure\n(return {:result 42})\n```"}
          _ -> {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{}, collect_messages: true)

      # System + user + assistant + user (feedback) + assistant (return)
      assert length(step.messages) == 5

      roles = Enum.map(step.messages, & &1.role)
      assert roles == [:system, :user, :assistant, :user, :assistant]
    end

    test "single-shot mode with collect_messages: true works" do
      agent = test_agent(max_turns: 1)
      llm = simple_return_llm()

      {:ok, step} = Loop.run(agent, llm: llm, context: %{}, collect_messages: true)

      assert is_list(step.messages)
      assert length(step.messages) == 3

      [system_msg, user_msg, assistant_msg] = step.messages
      assert system_msg.role == :system
      assert user_msg.role == :user
      assert assistant_msg.role == :assistant
    end

    test "error path (max_turns exceeded) collects messages" do
      agent = test_agent(max_turns: 2)

      llm = fn _ ->
        {:ok, "```clojure\n(+ 1 2)\n```"}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{}, collect_messages: true)

      assert step.fail.reason == :max_turns_exceeded
      assert is_list(step.messages)
      # System + user + assistant + user (feedback) + assistant + user (feedback)
      # = 6 messages (turn 1 and turn 2 both complete with assistant + feedback)
      assert length(step.messages) == 6
    end

    test "error path (LLM error) collects messages" do
      agent = test_agent()

      llm = fn _ ->
        {:error, :network_timeout}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{}, collect_messages: true)

      assert step.fail.reason == :llm_error
      assert is_list(step.messages)
      # User only (LLM failed before responding, system prompt not captured yet)
      assert length(step.messages) == 1
    end

    test "error path (explicit fail) collects messages" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, "```clojure\n(fail {:reason :bad-input})\n```"}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{}, collect_messages: true)

      assert step.fail.reason == :failed
      assert is_list(step.messages)
      # System + user + assistant
      assert length(step.messages) == 3
    end
  end

  describe "compression option" do
    test "compression: nil (default) uses uncompressed messages" do
      agent = test_agent(max_turns: 3)

      messages_log = Agent.start_link(fn -> [] end) |> elem(1)

      llm = fn %{turn: turn, messages: messages} ->
        Agent.update(messages_log, fn log -> [{turn, messages} | log] end)

        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          2 -> {:ok, "```clojure\n(return {:result 42})\n```"}
          _ -> {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{result: 42}

      # Check that turn 2 has accumulated messages (uncompressed)
      log = Agent.get(messages_log, & &1)
      {2, turn2_messages} = Enum.find(log, fn {turn, _} -> turn == 2 end)
      # Uncompressed: user, assistant, user (feedback)
      assert length(turn2_messages) == 3
    end

    test "compression: true uses SingleUserCoalesced on turn > 1" do
      agent =
        SubAgent.new(
          prompt: "Multi-turn task",
          tools: %{},
          max_turns: 3,
          compression: true
        )

      messages_log = Agent.start_link(fn -> [] end) |> elem(1)

      llm = fn %{turn: turn, messages: messages} ->
        Agent.update(messages_log, fn log -> [{turn, messages} | log] end)

        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          2 -> {:ok, "```clojure\n(return {:result 42})\n```"}
          _ -> {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{result: 42}

      log = Agent.get(messages_log, & &1)

      # Turn 1 should have 1 message (first user message)
      {1, turn1_messages} = Enum.find(log, fn {turn, _} -> turn == 1 end)
      assert length(turn1_messages) == 1

      # Turn 2 should have only 1 message (compressed USER message)
      # because compression coalesces history into a single user message
      {2, turn2_messages} = Enum.find(log, fn {turn, _} -> turn == 2 end)
      assert length(turn2_messages) == 1
      assert hd(turn2_messages).role == :user
    end

    test "compression: {Strategy, opts} passes custom options" do
      agent =
        SubAgent.new(
          prompt: "Multi-turn task",
          tools: %{},
          max_turns: 3,
          compression: {PtcRunner.SubAgent.Compression.SingleUserCoalesced, println_limit: 5}
        )

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          2 -> {:ok, "```clojure\n(return {:result 42})\n```"}
          _ -> {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{result: 42}
    end

    test "compression: false disables compression" do
      agent =
        SubAgent.new(
          prompt: "Multi-turn task",
          tools: %{},
          max_turns: 3,
          compression: false
        )

      messages_log = Agent.start_link(fn -> [] end) |> elem(1)

      llm = fn %{turn: turn, messages: messages} ->
        Agent.update(messages_log, fn log -> [{turn, messages} | log] end)

        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          2 -> {:ok, "```clojure\n(return {:result 42})\n```"}
          _ -> {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{result: 42}

      log = Agent.get(messages_log, & &1)

      # Turn 2 should have accumulated messages (uncompressed)
      {2, turn2_messages} = Enum.find(log, fn {turn, _} -> turn == 2 end)
      # Uncompressed: user, assistant, user (feedback)
      assert length(turn2_messages) == 3
    end

    test "compression is skipped for max_turns: 1 (SS-001)" do
      # Even with compression enabled, single-shot mode should skip it
      agent =
        SubAgent.new(
          prompt: "Single-shot task",
          tools: %{},
          max_turns: 1,
          compression: true
        )

      messages_log = Agent.start_link(fn -> [] end) |> elem(1)

      llm = fn %{messages: messages} ->
        Agent.update(messages_log, fn log -> [messages | log] end)
        {:ok, "```clojure\n(return {:result 42})\n```"}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{result: 42}

      # Single turn - only 1 user message
      log = Agent.get(messages_log, & &1)
      assert length(log) == 1
      assert length(hd(log)) == 1
    end

    test "compression includes turns indicator" do
      agent =
        SubAgent.new(
          prompt: "Multi-turn task",
          tools: %{},
          max_turns: 5,
          compression: true
        )

      messages_log = Agent.start_link(fn -> [] end) |> elem(1)

      llm = fn %{turn: turn, messages: messages} ->
        Agent.update(messages_log, fn log -> [{turn, messages} | log] end)

        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          2 -> {:ok, "```clojure\n(return {:result 42})\n```"}
          _ -> {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, _step} = Loop.run(agent, llm: llm, context: %{})

      log = Agent.get(messages_log, & &1)
      {2, turn2_messages} = Enum.find(log, fn {turn, _} -> turn == 2 end)

      # Compressed message should include turns indicator
      user_message = hd(turn2_messages)
      assert user_message.content =~ "Turns left:"
    end

    test "compressed view includes execution history" do
      tools = %{
        "get-value" => {fn _ -> 42 end, description: "Gets a value"}
      }

      agent =
        SubAgent.new(
          prompt: "Multi-turn task with tools",
          tools: tools,
          max_turns: 3,
          compression: true
        )

      messages_log = Agent.start_link(fn -> [] end) |> elem(1)

      llm = fn %{turn: turn, messages: messages} ->
        Agent.update(messages_log, fn log -> [{turn, messages} | log] end)

        case turn do
          1 -> {:ok, "```clojure\n(ctx/get-value {})\n```"}
          2 -> {:ok, "```clojure\n(return {:result 42})\n```"}
          _ -> {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{result: 42}

      log = Agent.get(messages_log, & &1)
      {2, turn2_messages} = Enum.find(log, fn {turn, _} -> turn == 2 end)

      # Compressed message should include execution history with tool call
      user_message = hd(turn2_messages)
      assert user_message.content =~ "get-value"
    end
  end
end
