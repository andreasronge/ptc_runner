defmodule PtcRunner.SubAgent.LoopTurnFeedbackTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Step
  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop
  alias PtcRunner.SubAgent.Loop.TurnFeedback

  describe "turn feedback format" do
    test "shows correct turn number, remaining count, and advance warning" do
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
            {:ok, "```clojure\n(+ 5 6)\n```"}

          4 ->
            # After turn 3, should show advance warning about last turn
            last_message = List.last(messages)
            assert last_message.content =~ "next turn is your LAST"
            {:ok, "```clojure\n(+ 7 8)\n```"}

          5 ->
            # After turn 4, should show FINAL WORK TURN
            last_message = List.last(messages)
            assert last_message.content =~ "FINAL WORK TURN"
            {:ok, "```clojure\n(return 42)\n```"}

          _ ->
            {:ok, "```clojure\n(return 99)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.return == 42
      assert step.usage.turns == 5
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
            # After turn 2 with max_turns=3, should show FINAL WORK TURN warning
            last_message = List.last(messages)
            assert last_message.content =~ "FINAL WORK TURN"
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
            # After turn 1, feedback should show a truncated result preview
            last_message = List.last(messages)
            assert last_message.content =~ "user=> [1 2 3"
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

    test "shows FINAL WORK TURN warning with retry info when retry_turns configured" do
      agent =
        SubAgent.new(
          prompt: "Multi-turn task",
          tools: %{},
          max_turns: 2,
          retry_turns: 1
        )

      llm = fn %{turn: turn, messages: messages} ->
        case turn do
          1 ->
            {:ok, "```clojure\n(+ 1 2)\n```"}

          2 ->
            # After turn 1 with max_turns=2, should show FINAL WORK TURN with retry info
            last_message = List.last(messages)
            assert last_message.content =~ "FINAL WORK TURN"
            assert last_message.content =~ "1 correction attempt"
            {:ok, "```clojure\n(return 42)\n```"}

          _ ->
            {:ok, "```clojure\n(return 99)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.return == 42
    end

    test "multiple code blocks returns error feedback" do
      agent =
        SubAgent.new(
          prompt: "Multi-turn task",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{turn: turn, messages: messages} ->
        case turn do
          1 ->
            # Return multiple code blocks - should be rejected
            {:ok,
             """
             ```clojure
             (def x 1)
             ```

             ```clojure
             (def y 2)
             ```
             """}

          2 ->
            # Should see error about multiple code blocks
            last_message = List.last(messages)
            assert last_message.content =~ "exactly ONE is required"
            assert last_message.content =~ "2 code blocks"
            {:ok, "```clojure\n(return 42)\n```"}

          _ ->
            {:ok, "```clojure\n(return 99)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.return == 42
    end
  end

  describe "custom progress_fn" do
    test "receives initial and continuation calls, threads state across turns" do
      {:ok, calls} = Agent.start_link(fn -> [] end)

      progress_fn = fn input, state ->
        count = (state || 0) + 1
        Agent.update(calls, &[{count, input} | &1])
        {"Turn progress ##{count}", count}
      end

      agent =
        SubAgent.new(
          prompt: "Multi-turn task",
          tools: %{},
          max_turns: 3,
          plan: [{"a", "Step A"}],
          progress_fn: progress_fn
        )

      llm = fn %{turn: turn, messages: messages} ->
        case turn do
          1 ->
            # First user message should contain initial progress
            first_msg = hd(messages)
            assert first_msg.content =~ "Turn progress #1"
            {:ok, "```clojure\n(+ 1 2)\n```"}

          2 ->
            # Feedback should contain continuation progress with state=2
            last_msg = List.last(messages)
            assert last_msg.content =~ "Turn progress #2"
            {:ok, "```clojure\n(return :done)\n```"}

          _ ->
            {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.return == :done

      all_calls = Agent.get(calls, & &1) |> Enum.reverse()
      assert length(all_calls) == 2

      # Initial call
      {1, initial} = Enum.at(all_calls, 0)
      assert initial.phase == :initial
      assert initial.turn == 0
      assert initial.plan == [{"a", "Step A"}]
      assert initial.summaries == %{}
      assert initial.tool_calls == []

      # Continuation call
      {2, continuation} = Enum.at(all_calls, 1)
      assert continuation.phase == :continuation
      assert continuation.turn == 1
      assert continuation.plan == [{"a", "Step A"}]
    end

    test "continuation receives tool_calls from execution" do
      {:ok, calls} = Agent.start_link(fn -> [] end)

      progress_fn = fn input, state ->
        Agent.update(calls, &[input | &1])
        {"", state}
      end

      greeting_tool = fn %{"name" => name} -> {:ok, "Hello #{name}"} end

      agent =
        SubAgent.new(
          prompt: "Use tools",
          tools: %{"greet" => greeting_tool},
          max_turns: 3,
          progress_fn: progress_fn
        )

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, ~S|```clojure
(tool/greet {:name "world"})
```|}
          2 -> {:ok, "```clojure\n(return :done)\n```"}
          _ -> {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, _step} = Loop.run(agent, llm: llm, context: %{})

      all_calls = Agent.get(calls, & &1) |> Enum.reverse()
      # Initial (no tool_calls) + continuation (with tool_calls from turn 1)
      assert length(all_calls) == 2

      continuation = Enum.at(all_calls, 1)
      assert continuation.phase == :continuation
      assert continuation.tool_calls != []
      assert hd(continuation.tool_calls).name == "greet"
    end

    test "invalid progress_fn return raises ArgumentError" do
      bad_fn = fn _input, _state -> "not a tuple" end

      agent =
        SubAgent.new(
          prompt: "Task",
          tools: %{},
          max_turns: 2,
          progress_fn: bad_fn
        )

      llm = fn _ -> {:ok, "```clojure\n(return :done)\n```"} end

      assert_raise ArgumentError, ~r/progress_fn must return/, fn ->
        Loop.run(agent, llm: llm, context: %{})
      end
    end
  end

  describe "execution_feedback/3" do
    # Minimal state shape consumed by execution_feedback/3 (only :memory is read).
    # append_turn_info / append_progress are intentionally NOT exercised here —
    # those are layered by format/3 and must not appear in execution_feedback/3
    # output (this is the Phase 4 parity requirement).
    defp build_state(memory \\ %{}) do
      %{
        memory: memory,
        summaries: %{},
        turn: 1,
        work_turns_remaining: 5,
        retry_turns_remaining: 0,
        progress_state: nil
      }
    end

    defp build_lisp_step(opts) do
      %Step{
        return: Keyword.get(opts, :return),
        memory: Keyword.get(opts, :memory, %{}),
        prints: Keyword.get(opts, :prints, []),
        tool_calls: Keyword.get(opts, :tool_calls, []),
        summaries: Keyword.get(opts, :summaries, %{})
      }
    end

    test "returns the documented shape with all keys present" do
      agent = SubAgent.new(prompt: "task", tools: %{}, max_turns: 3)
      state = build_state()

      lisp_step =
        build_lisp_step(
          return: 42,
          memory: %{items: [1, 2, 3]},
          prints: ["hello"]
        )

      result = TurnFeedback.execution_feedback(agent, state, lisp_step)

      assert is_binary(result.feedback)
      assert is_list(result.prints)
      assert Map.has_key?(result, :result)
      assert is_map(result.memory)
      assert Map.has_key?(result.memory, :changed)
      assert Map.has_key?(result.memory, :stored_keys)
      assert Map.has_key?(result.memory, :truncated)
      assert is_boolean(result.truncated)
    end

    test "memory.changed includes only new/changed bindings, not unchanged ones" do
      agent = SubAgent.new(prompt: "task", tools: %{}, max_turns: 3)
      # Previous memory had stable=10; current adds new_var and bumps stable→20.
      state = build_state(%{stable: 10, untouched: "same"})

      lisp_step =
        build_lisp_step(
          return: nil,
          memory: %{stable: 20, untouched: "same", new_var: "fresh"}
        )

      result = TurnFeedback.execution_feedback(agent, state, lisp_step)

      assert Map.has_key?(result.memory.changed, "stable")
      assert Map.has_key?(result.memory.changed, "new_var")
      refute Map.has_key?(result.memory.changed, "untouched")
    end

    test "memory.stored_keys lists every current memory binding, sorted" do
      agent = SubAgent.new(prompt: "task", tools: %{}, max_turns: 3)
      state = build_state()

      lisp_step =
        build_lisp_step(
          return: nil,
          memory: %{zeta: 1, alpha: 2, mu: 3}
        )

      result = TurnFeedback.execution_feedback(agent, state, lisp_step)

      assert result.memory.stored_keys == ["alpha", "mu", "zeta"]
    end

    test "memory.truncated and top-level truncated flag oversize previews" do
      # Force preview_max small so a long binding value triggers truncation.
      agent =
        SubAgent.new(
          prompt: "task",
          tools: %{},
          max_turns: 3,
          format_options: [preview_max_chars: 20]
        )

      state = build_state()
      big_list = Enum.to_list(1..200)

      lisp_step =
        build_lisp_step(
          return: nil,
          memory: %{huge: big_list}
        )

      result = TurnFeedback.execution_feedback(agent, state, lisp_step)

      assert result.memory.truncated == true
      assert result.truncated == true
      assert result.feedback =~ "truncated"
    end

    test "top-level truncated flag also reflects prints truncation" do
      agent =
        SubAgent.new(
          prompt: "task",
          tools: %{},
          max_turns: 3,
          format_options: [feedback_max_chars: 20]
        )

      state = build_state()

      lisp_step =
        build_lisp_step(prints: ["a very long line of printed output that exceeds twenty bytes"])

      result = TurnFeedback.execution_feedback(agent, state, lisp_step)

      assert result.truncated == true
      assert result.feedback =~ "truncated"
    end

    test "feedback string excludes append_turn_info output" do
      # Multi-turn agent — format/3 would append "Turn 2 of 5 ..." style info.
      # execution_feedback/3 must NOT include any of that.
      agent = SubAgent.new(prompt: "task", tools: %{}, max_turns: 5)
      state = build_state()

      lisp_step = build_lisp_step(return: 42)

      result = TurnFeedback.execution_feedback(agent, state, lisp_step)

      refute result.feedback =~ "Turn "
      refute result.feedback =~ "remaining"
      refute result.feedback =~ "FINAL WORK TURN"
      refute result.feedback =~ "next turn is your LAST"
    end

    test "feedback string excludes append_progress output even with custom progress_fn" do
      # This is the Phase 4 parity test: a user-set progress_fn must not leak
      # into execution_feedback/3's output, but format/3 must still include it.
      progress_fn = fn _input, state ->
        {"PROGRESS_MARKER_DO_NOT_LEAK", state}
      end

      agent =
        SubAgent.new(
          prompt: "task",
          tools: %{},
          max_turns: 5,
          progress_fn: progress_fn
        )

      state = build_state()
      lisp_step = build_lisp_step(return: 42)

      # execution_feedback/3 must NOT contain the progress marker.
      execution = TurnFeedback.execution_feedback(agent, state, lisp_step)
      refute execution.feedback =~ "PROGRESS_MARKER_DO_NOT_LEAK"

      # format/3 (the wrapper) MUST contain it — proves the parity gap is real.
      {format_feedback, _truncated, _progress_state} =
        TurnFeedback.format(agent, state, lisp_step)

      assert format_feedback =~ "PROGRESS_MARKER_DO_NOT_LEAK"
    end

    test "result preview is rendered for non-Var return values on multi-turn agents" do
      agent = SubAgent.new(prompt: "task", tools: %{}, max_turns: 3)
      state = build_state()
      lisp_step = build_lisp_step(return: [1, 2, 3])

      result = TurnFeedback.execution_feedback(agent, state, lisp_step)

      assert result.result =~ "user=>"
      assert result.feedback =~ "user=>"
    end

    test ":result is non-nil when prints is non-empty AND return is set (multi-turn)" do
      # Phase 4 needs the structured :result field even when there is println
      # output. format/3's human-readable feedback string still suppresses the
      # "user=> ..." preview in this case (parity preserved by other tests).
      agent = SubAgent.new(prompt: "task", tools: %{}, max_turns: 5)
      state = build_state()
      lisp_step = build_lisp_step(return: 42, prints: ["hello"])

      result = TurnFeedback.execution_feedback(agent, state, lisp_step)

      assert result.result =~ "user=> 42"
    end

    test ":result is non-nil for max_turns: 1 agents that returned a value" do
      # Phase 4 needs the structured :result field even for single-turn agents.
      agent = SubAgent.new(prompt: "task", tools: %{}, max_turns: 1)
      state = build_state()
      lisp_step = build_lisp_step(return: [1, 2, 3])

      result = TurnFeedback.execution_feedback(agent, state, lisp_step)

      assert result.result =~ "user=>"
      assert result.result =~ "[1 2 3]"
    end

    test ":memory.changed is populated for max_turns: 1 agents with changed bindings" do
      # Phase 4 needs the structured :memory.changed field even for single-turn
      # agents. format/3's human-readable feedback string still suppresses the
      # "Stored: ..." hint for max_turns: 1 (parity preserved).
      agent = SubAgent.new(prompt: "task", tools: %{}, max_turns: 1)
      state = build_state()

      lisp_step =
        build_lisp_step(
          return: nil,
          memory: %{items: [1, 2, 3], count: 3}
        )

      result = TurnFeedback.execution_feedback(agent, state, lisp_step)

      assert Map.has_key?(result.memory.changed, "items")
      assert Map.has_key?(result.memory.changed, "count")
    end

    test ":result is non-nil for single-turn agent with both prints AND return" do
      # Worst-case combination: max_turns: 1 (memory hint suppressed) AND
      # prints non-empty (result preview suppressed). Both structured fields
      # must still be populated for Phase 4's tool-result JSON.
      agent = SubAgent.new(prompt: "task", tools: %{}, max_turns: 1)
      state = build_state()

      lisp_step =
        build_lisp_step(
          return: %{ok: true},
          prints: ["working..."],
          memory: %{step: "done"}
        )

      result = TurnFeedback.execution_feedback(agent, state, lisp_step)

      assert result.result =~ "user=>"
      assert Map.has_key?(result.memory.changed, "step")
    end

    test "stored_keys is empty list when memory is empty" do
      agent = SubAgent.new(prompt: "task", tools: %{}, max_turns: 3)
      state = build_state()
      lisp_step = build_lisp_step(memory: %{})

      result = TurnFeedback.execution_feedback(agent, state, lisp_step)

      assert result.memory.stored_keys == []
      assert result.memory.changed == %{}
      assert result.memory.truncated == false
    end
  end
end
