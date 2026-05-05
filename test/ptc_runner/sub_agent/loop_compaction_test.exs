defmodule PtcRunner.SubAgent.LoopCompactionTest do
  @moduledoc """
  Integration tests for compaction wired into the loop (step 3 of the
  pressure-triggered compaction migration).

  Asserted behavior comes from the plan §"4. Replace `build_llm_messages/3`":

  - Compaction is skipped for single-shot and single-shot+retry runs.
  - Compaction is skipped when disabled.
  - Stats appear in `step.usage.compaction` when triggered.
  - `state.messages` is not mutated; `step.messages` (collected) reflects
    the full raw history.
  - `state.turns` is preserved in full regardless of compaction.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop

  import PtcRunner.TestSupport.SubAgentTestHelpers

  # ---------- helpers ----------

  defp capture_messages_log do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    pid
  end

  defp record_turn(log, turn, messages) do
    Agent.update(log, fn entries -> [{turn, messages} | entries] end)
  end

  defp messages_at_turn(log, turn) do
    Agent.get(log, & &1)
    |> Enum.find(fn {t, _} -> t == turn end)
    |> case do
      {_t, msgs} -> msgs
      nil -> nil
    end
  end

  # LLM that returns a 200-char block on the first N-1 turns, then `(return ...)`.
  # 200 chars per message keeps token estimates noisy enough to also trigger
  # token pressure when threshold is set low.
  defp recording_llm(log, turns_until_return, return_value \\ %{result: 42}) do
    long = String.duplicate("x", 200)

    fn %{turn: turn, messages: messages} ->
      record_turn(log, turn, messages)

      if turn < turns_until_return do
        # Successful intermediate turn — the loop captures these into state.turns
        # and appends them to state.messages. Each turn appends one assistant
        # message and one user feedback message.
        {:ok, "```clojure\n\"#{long}\"\n```"}
      else
        {:ok, "```clojure\n(return #{format_return(return_value)})\n```"}
      end
    end
  end

  defp format_return(%{} = m) do
    pairs =
      m
      |> Enum.map_join(" ", fn {k, v} -> ":#{k} #{inspect(v)}" end)

    "{#{pairs}}"
  end

  # ---------- §9 plan tests ----------

  describe "skipped paths" do
    test "compaction: nil (default) does not produce stats" do
      log = capture_messages_log()
      llm = recording_llm(log, 3)

      agent = test_agent(max_turns: 4)
      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}
      refute Map.has_key?(step.usage, :compaction)
    end

    test "compaction: false does not produce stats" do
      log = capture_messages_log()
      llm = recording_llm(log, 3)

      agent = SubAgent.new(prompt: "Test", max_turns: 4, compaction: false)
      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}
      refute Map.has_key?(step.usage, :compaction)
    end

    test "single-shot (max_turns: 1) skips compaction even when enabled" do
      log = capture_messages_log()
      llm = recording_llm(log, 1)

      agent =
        SubAgent.new(
          prompt: "Test",
          max_turns: 1,
          compaction: [trigger: [turns: 1, tokens: 1], keep_recent_turns: 1]
        )

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}
      # Plan §"Decisions Locked In" item 4: gate is agent.max_turns > 1,
      # so single-shot skips even with aggressive triggers.
      refute Map.has_key?(step.usage, :compaction)
    end

    test "single-shot + retry (max_turns: 1, retry_turns > 0) skips compaction" do
      # Retry-on-validation-failure path: agent forced to retry once, still
      # single-shot, must NOT enter compaction.
      log = capture_messages_log()

      # Turn 1 fails validation, retry turn returns a valid value
      llm = fn %{turn: turn, messages: messages} ->
        record_turn(log, turn, messages)

        case turn do
          1 -> {:ok, "```clojure\n(return {:wrong \"shape\"})\n```"}
          _ -> {:ok, "```clojure\n(return {:result 42})\n```"}
        end
      end

      agent =
        SubAgent.new(
          prompt: "Test",
          signature: "() -> {result :int}",
          max_turns: 1,
          retry_turns: 1,
          compaction: [trigger: [turns: 1, tokens: 1], keep_recent_turns: 1]
        )

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}
      # Behavior change documented in the migration: compaction does NOT run
      # for single-shot+retry. The previous compression default did.
      refute Map.has_key?(step.usage, :compaction)
    end
  end

  describe "triggered paths" do
    test "compaction: true with turn pressure surfaces stats in step.usage.compaction" do
      log = capture_messages_log()
      llm = recording_llm(log, 6)

      # Default compaction trigger: turns: 8. Use a custom low threshold so we
      # actually fire within reasonable test turns.
      agent =
        SubAgent.new(
          prompt: "Test",
          max_turns: 8,
          compaction: [trigger: [turns: 2], keep_recent_turns: 2, keep_initial_user: true]
        )

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}
      assert %{} = step.usage.compaction
      assert step.usage.compaction.strategy == "trim"
      assert step.usage.compaction.triggered == true
      assert step.usage.compaction.reason == :turn_pressure
      assert step.usage.compaction.kept_recent_turns == 2
    end

    test "compaction triggers on token pressure when turn threshold not met" do
      log = capture_messages_log()
      llm = recording_llm(log, 5)

      # 200 chars per intermediate message → 50 tokens. Trigger at 100 tokens
      # so it fires once a few messages have accumulated, but turn threshold
      # (1000) keeps turn pressure off.
      agent =
        SubAgent.new(
          prompt: "Test",
          max_turns: 6,
          compaction: [
            trigger: [turns: 1000, tokens: 100],
            keep_recent_turns: 1,
            keep_initial_user: true
          ]
        )

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}
      assert step.usage.compaction.triggered == true
      assert step.usage.compaction.reason == :token_pressure
    end

    test "compaction does NOT trigger when neither pressure threshold is reached" do
      log = capture_messages_log()
      llm = recording_llm(log, 3)

      agent =
        SubAgent.new(
          prompt: "Test",
          max_turns: 4,
          compaction: [trigger: [turns: 1000], keep_recent_turns: 2]
        )

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}
      # When pressure never fires, the last call's :not_triggered stats live
      # on state.compaction_stats and surface in usage.
      assert step.usage.compaction.triggered == false
      assert step.usage.compaction.strategy == "trim"
    end
  end

  describe "non-mutation invariants" do
    test "state.messages is not mutated — collected messages reflect full raw history" do
      log = capture_messages_log()
      llm = recording_llm(log, 5)

      agent =
        SubAgent.new(
          prompt: "Test",
          max_turns: 6,
          compaction: [trigger: [turns: 2], keep_recent_turns: 1, keep_initial_user: true]
        )

      {:ok, step} = Loop.run(agent, llm: llm, context: %{}, collect_messages: true)

      assert step.return == %{"result" => 42}
      assert step.usage.compaction.triggered == true

      # The collected message log is the FULL raw history, not the trimmed
      # view. If state.messages were mutated, this would be shorter.
      assert is_list(step.messages)

      # A successful 5-turn run produces: 1 initial user + 4×(assistant+user feedback)
      # + final assistant = 10 entries (without system, when no system prompt set).
      # We don't pin exact length to keep the test resilient to feedback-format
      # changes — just assert it's clearly more than the trimmed window
      # (which would be ~3 messages for keep_recent_turns: 1 + initial user).
      assert length(step.messages) > 4
    end

    test "state.turns is preserved in full regardless of compaction" do
      log = capture_messages_log()
      llm = recording_llm(log, 5)

      agent =
        SubAgent.new(
          prompt: "Test",
          max_turns: 6,
          compaction: [trigger: [turns: 2], keep_recent_turns: 1]
        )

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}
      assert step.usage.compaction.triggered == true
      # state.turns becomes step.turns. Should reflect every completed turn,
      # not the trimmed slice.
      assert length(step.turns) == 5
    end

    test "messages sent to LLM ARE compacted on triggered turns" do
      log = capture_messages_log()
      llm = recording_llm(log, 5)

      agent =
        SubAgent.new(
          prompt: "Test",
          max_turns: 6,
          compaction: [trigger: [turns: 2], keep_recent_turns: 1, keep_initial_user: true]
        )

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}
      assert step.usage.compaction.triggered == true

      # Turn 1: just initial user message.
      turn1 = messages_at_turn(log, 1)
      assert length(turn1) == 1

      # Turn 4 should be compacted (turn > 2): keep_recent_turns: 1 means
      # 2 recent messages; +1 initial user = at most 3. The exact count
      # depends on whether the recent slice begins with :user, but it must
      # be strictly less than the uncompacted count at turn 4.
      turn4 = messages_at_turn(log, 4)
      uncompacted_at_turn_4 = 1 + 2 * 3
      assert length(turn4) < uncompacted_at_turn_4
    end
  end

  describe "telemetry — [:ptc_runner, :sub_agent, :compaction, :triggered]" do
    test "emits one event per triggered firing with the documented shape" do
      handler_id = "test-compaction-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:ptc_runner, :sub_agent, :compaction, :triggered],
          fn event, measurements, metadata, _ ->
            send(test_pid, {:compaction_event, event, measurements, metadata})
          end,
          nil
        )

      try do
        log = capture_messages_log()
        llm = recording_llm(log, 5)

        # Aggressive trigger: turns > 1 fires from turn 2 onward, so we
        # expect one event per intermediate turn (turns 2..5).
        agent =
          SubAgent.new(
            prompt: "Test",
            max_turns: 6,
            compaction: [trigger: [turns: 1], keep_recent_turns: 1, keep_initial_user: true]
          )

        {:ok, step} = Loop.run(agent, llm: llm, context: %{})

        assert step.return == %{"result" => 42}

        # Drain all events.
        events = drain_compaction_events()
        assert events != [], "Expected at least one compaction.triggered event"

        # Check shape on the first event.
        {event, measurements, metadata} = hd(events)
        assert event == [:ptc_runner, :sub_agent, :compaction, :triggered]

        # Numeric fields live in measurements.
        assert is_integer(measurements.messages_before)
        assert is_integer(measurements.messages_after)
        assert is_integer(measurements.estimated_tokens_before)
        assert is_integer(measurements.estimated_tokens_after)
        assert measurements.messages_after < measurements.messages_before

        # Descriptive fields live in metadata, plus span correlation.
        assert metadata.strategy == "trim"
        assert metadata.reason in [:turn_pressure, :token_pressure]
        assert is_integer(metadata.turn)
        assert is_boolean(metadata.kept_initial_user?)
        assert is_integer(metadata.kept_recent_turns)
        assert is_boolean(metadata.over_budget?)
        # span_id is auto-injected by Telemetry.emit/3
        assert is_binary(metadata.span_id) or metadata.span_id == nil
      after
        :telemetry.detach(handler_id)
      end
    end

    test "does NOT emit on non-triggered pressure checks" do
      handler_id = "test-compaction-quiet-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:ptc_runner, :sub_agent, :compaction, :triggered],
          fn _e, _m, _meta, _ -> send(test_pid, :compaction_event) end,
          nil
        )

      try do
        log = capture_messages_log()
        llm = recording_llm(log, 3)

        # High threshold: pressure never fires.
        agent =
          SubAgent.new(
            prompt: "Test",
            max_turns: 4,
            compaction: [trigger: [turns: 1000], keep_recent_turns: 2]
          )

        {:ok, step} = Loop.run(agent, llm: llm, context: %{})
        assert step.return == %{"result" => 42}

        # Confirm zero events were sent.
        refute_receive :compaction_event, 50
      after
        :telemetry.detach(handler_id)
      end
    end

    test "emits zero events when compaction is disabled" do
      handler_id = "test-compaction-disabled-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:ptc_runner, :sub_agent, :compaction, :triggered],
          fn _e, _m, _meta, _ -> send(test_pid, :compaction_event) end,
          nil
        )

      try do
        log = capture_messages_log()
        llm = recording_llm(log, 3)

        agent = SubAgent.new(prompt: "Test", max_turns: 4, compaction: false)

        {:ok, step} = Loop.run(agent, llm: llm, context: %{})
        assert step.return == %{"result" => 42}

        refute_receive :compaction_event, 50
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  defp drain_compaction_events(acc \\ []) do
    receive do
      {:compaction_event, e, m, meta} -> drain_compaction_events([{e, m, meta} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
