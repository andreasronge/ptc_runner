defmodule PtcRunner.SubAgent.TelemetryTest do
  use ExUnit.Case, async: false

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Telemetry

  doctest Telemetry

  setup do
    events_table = :ets.new(:telemetry_test_events, [:bag, :public])

    handler = fn event, measurements, metadata, config ->
      :ets.insert(config.table, {event, measurements, metadata, System.monotonic_time()})
    end

    handler_id = "test-handler-#{:erlang.unique_integer()}"

    :telemetry.attach_many(
      handler_id,
      [
        [:ptc_runner, :sub_agent, :run, :start],
        [:ptc_runner, :sub_agent, :run, :stop],
        [:ptc_runner, :sub_agent, :run, :exception],
        [:ptc_runner, :sub_agent, :turn, :start],
        [:ptc_runner, :sub_agent, :turn, :stop],
        [:ptc_runner, :sub_agent, :llm, :start],
        [:ptc_runner, :sub_agent, :llm, :stop],
        [:ptc_runner, :sub_agent, :tool, :start],
        [:ptc_runner, :sub_agent, :tool, :stop],
        [:ptc_runner, :sub_agent, :tool, :exception]
      ],
      handler,
      %{table: events_table}
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      if :ets.info(events_table) != :undefined do
        :ets.delete(events_table)
      end
    end)

    {:ok, table: events_table}
  end

  defp get_events(table) do
    :ets.tab2list(table)
  end

  defp get_events_by_name(table, event_name) do
    table
    |> get_events()
    |> Enum.filter(fn {event, _, _, _} -> event == event_name end)
  end

  describe "run events" do
    test "emits :run :start and :stop events on successful execution", %{table: table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|```clojure
(call "return" {:value 42})
```|}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm, context: %{x: 1})

      start_events = get_events_by_name(table, [:ptc_runner, :sub_agent, :run, :start])
      stop_events = get_events_by_name(table, [:ptc_runner, :sub_agent, :run, :stop])

      assert length(start_events) == 1
      assert length(stop_events) == 1

      [{_, start_measurements, start_meta, _}] = start_events
      [{_, stop_measurements, stop_meta, _}] = stop_events

      # Start event includes system_time and monotonic_time from telemetry.span
      assert is_integer(start_measurements.system_time)
      assert is_integer(start_measurements.monotonic_time)
      assert start_meta.agent == agent
      assert start_meta.context == %{x: 1}

      # Stop event has duration in native time units
      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration > 0
      assert stop_meta.agent == agent
      assert stop_meta.status == :ok
      assert stop_meta.step.return == %{value: 42}
    end

    test "emits :run :stop with error status on failure", %{table: table} do
      # Use max_turns: 2 to ensure loop mode (not single-shot mode)
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 2)

      llm = fn _ ->
        # Return code that will cause a parsing error, then max_turns exceeded
        {:ok, "no valid code here"}
      end

      {:error, _step} = SubAgent.run(agent, llm: llm, context: %{})

      stop_events = get_events_by_name(table, [:ptc_runner, :sub_agent, :run, :stop])
      assert length(stop_events) == 1

      [{_, stop_measurements, stop_meta, _}] = stop_events
      assert is_integer(stop_measurements.duration)
      assert stop_meta.status == :error
    end
  end

  describe "turn events" do
    test "emits :turn :start and :stop events for each turn", %{table: table} do
      turn_counter = :counters.new(1, [:atomics])

      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 5)

      llm = fn %{turn: turn} ->
        :counters.put(turn_counter, 1, turn)

        case turn do
          1 -> {:ok, "(+ 1 2)"}
          2 -> {:ok, ~S|(call "return" {:value 42})|}
          _ -> {:ok, "(+ 1 2)"}
        end
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      turn_starts = get_events_by_name(table, [:ptc_runner, :sub_agent, :turn, :start])
      turn_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :turn, :stop])

      assert length(turn_starts) == 2
      assert length(turn_stops) == 2

      # Check first turn event
      [{_, start_measurements, start_meta, _} | _] = turn_starts
      assert start_measurements == %{}
      assert start_meta.agent == agent
      assert start_meta.turn == 1

      # Check turn stop has duration
      [{_, stop_measurements, _stop_meta, _} | _] = turn_stops
      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration > 0
    end
  end

  describe "llm events" do
    test "emits :llm :start and :stop events for each LLM call", %{table: table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|(call "return" {:done true})|}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm, context: %{input: "test"})

      llm_starts = get_events_by_name(table, [:ptc_runner, :sub_agent, :llm, :start])
      llm_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :llm, :stop])

      assert length(llm_starts) == 1
      assert length(llm_stops) == 1

      [{_, start_measurements, start_meta, _}] = llm_starts
      [{_, stop_measurements, stop_meta, _}] = llm_stops

      # Start event includes system_time and monotonic_time from telemetry.span
      assert is_integer(start_measurements.system_time)
      assert start_meta.agent == agent
      assert start_meta.turn == 1
      assert is_list(start_meta.messages)

      # Stop event
      assert is_integer(stop_measurements.duration)
      assert stop_meta.agent == agent
      assert stop_meta.turn == 1
      assert stop_meta.response =~ "return"
    end

    test "includes tokens in :llm :stop measurements when LLM returns tokens", %{table: table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 2)

      llm = fn _ ->
        {:ok, %{content: ~S|(call "return" {:done true})|, tokens: %{input: 100, output: 50}}}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      llm_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :llm, :stop])
      assert length(llm_stops) == 1

      [{_, stop_measurements, _stop_meta, _}] = llm_stops

      assert is_integer(stop_measurements.duration)
      assert stop_measurements.tokens == 150
    end

    test "omits tokens from measurements when LLM returns plain string", %{table: table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|(call "return" {:done true})|}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      llm_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :llm, :stop])
      [{_, stop_measurements, _stop_meta, _}] = llm_stops

      refute Map.has_key?(stop_measurements, :tokens)
    end
  end

  describe "token accumulation in Step.usage" do
    test "accumulates tokens across multiple LLM calls", %{table: _table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 3)

      llm = fn %{turn: turn} ->
        tokens = %{input: turn * 10, output: turn * 5}

        code =
          case turn do
            1 -> "(+ 1 2)"
            _ -> ~S|(call "return" {:value 42})|
          end

        {:ok, %{content: code, tokens: tokens}}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      # Turn 1: input=10, output=5
      # Turn 2: input=20, output=10
      # Total: input=30, output=15
      assert step.usage.input_tokens == 30
      assert step.usage.output_tokens == 15
      assert step.usage.total_tokens == 45
      assert step.usage.llm_requests == 2
    end

    test "includes llm_requests even without token counts", %{table: _table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|(call "return" {:done true})|}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.usage.llm_requests == 1
      refute Map.has_key?(step.usage, :input_tokens)
      refute Map.has_key?(step.usage, :output_tokens)
      refute Map.has_key?(step.usage, :total_tokens)
    end

    test "works with mixed token and non-token responses", %{table: _table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 4)

      llm = fn %{turn: turn} ->
        case turn do
          1 ->
            # First turn: no tokens
            {:ok, "(+ 1 2)"}

          2 ->
            # Second turn: with tokens
            {:ok, %{content: "(+ 3 4)", tokens: %{input: 20, output: 10}}}

          _ ->
            # Final turn: return
            {:ok, ~S|(call "return" {:value 42})|}
        end
      end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      # Only turn 2 contributed tokens
      assert step.usage.input_tokens == 20
      assert step.usage.output_tokens == 10
      assert step.usage.total_tokens == 30
      assert step.usage.llm_requests == 3
    end
  end

  describe "turn events with tokens" do
    test "includes tokens in :turn :stop measurements", %{table: table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 2)

      llm = fn _ ->
        {:ok, %{content: ~S|(call "return" {:done true})|, tokens: %{input: 50, output: 25}}}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      turn_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :turn, :stop])
      assert length(turn_stops) == 1

      [{_, stop_measurements, _stop_meta, _}] = turn_stops

      assert is_integer(stop_measurements.duration)
      assert stop_measurements.tokens == 75
    end
  end

  describe "tool events" do
    test "emits :tool :start and :stop events for tool calls", %{table: table} do
      helper_fn = fn args -> args.x * 2 end

      agent = SubAgent.new(prompt: "Test", tools: %{"helper" => helper_fn}, max_turns: 2)

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, ~S|(call "helper" {:x 5})|}
          _ -> {:ok, ~S|(call "return" {:done true})|}
        end
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      tool_starts = get_events_by_name(table, [:ptc_runner, :sub_agent, :tool, :start])
      tool_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :tool, :stop])

      assert length(tool_starts) == 1
      assert length(tool_stops) == 1

      [{_, start_measurements, start_meta, _}] = tool_starts
      [{_, stop_measurements, stop_meta, _}] = tool_stops

      # Start event includes system_time and monotonic_time from telemetry.span
      assert is_integer(start_measurements.system_time)
      assert start_meta.agent == agent
      assert start_meta.tool_name == "helper"
      assert start_meta.args == %{x: 5}

      # Stop event
      assert is_integer(stop_measurements.duration)
      assert stop_meta.agent == agent
      assert stop_meta.tool_name == "helper"
      assert stop_meta.result == 10
    end

    test "emits :tool :exception on tool crash", %{table: table} do
      failing_fn = fn _args -> raise "Tool failure!" end

      agent = SubAgent.new(prompt: "Test", tools: %{"crasher" => failing_fn}, max_turns: 1)

      llm = fn _ ->
        {:ok, ~S|(call "crasher" {:x 1})|}
      end

      {:error, _step} = SubAgent.run(agent, llm: llm)

      tool_exceptions = get_events_by_name(table, [:ptc_runner, :sub_agent, :tool, :exception])

      assert length(tool_exceptions) == 1

      [{_, measurements, meta, _}] = tool_exceptions

      assert is_integer(measurements.duration)
      assert meta.agent == agent
      assert meta.tool_name == "crasher"
      assert meta.kind == :error
      assert meta.reason.__struct__ == RuntimeError
    end
  end

  describe "end-to-end execution" do
    test "full agent execution emits all expected events", %{table: table} do
      counter_fn = fn args -> args.n + 1 end

      agent =
        SubAgent.new(
          prompt: "Test with {{input}}",
          tools: %{"counter" => counter_fn},
          max_turns: 3
        )

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, ~S|(call "counter" {:n 5})|}
          _ -> {:ok, ~S|(call "return" {:value 42})|}
        end
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm, context: %{input: "hello"})

      all_events = get_events(table)

      # Verify we got all event types
      event_names = Enum.map(all_events, fn {event, _, _, _} -> event end) |> Enum.uniq()

      assert [:ptc_runner, :sub_agent, :run, :start] in event_names
      assert [:ptc_runner, :sub_agent, :run, :stop] in event_names
      assert [:ptc_runner, :sub_agent, :turn, :start] in event_names
      assert [:ptc_runner, :sub_agent, :turn, :stop] in event_names
      assert [:ptc_runner, :sub_agent, :llm, :start] in event_names
      assert [:ptc_runner, :sub_agent, :llm, :stop] in event_names
      assert [:ptc_runner, :sub_agent, :tool, :start] in event_names
      assert [:ptc_runner, :sub_agent, :tool, :stop] in event_names

      # Verify event counts
      run_starts = get_events_by_name(table, [:ptc_runner, :sub_agent, :run, :start])
      run_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :run, :stop])
      assert length(run_starts) == 1
      assert length(run_stops) == 1

      llm_starts = get_events_by_name(table, [:ptc_runner, :sub_agent, :llm, :start])
      llm_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :llm, :stop])
      assert length(llm_starts) == 2
      assert length(llm_stops) == 2

      tool_starts = get_events_by_name(table, [:ptc_runner, :sub_agent, :tool, :start])
      tool_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :tool, :stop])
      assert length(tool_starts) == 1
      assert length(tool_stops) == 1
    end
  end

  describe "Telemetry module" do
    test "prefix/0 returns correct prefix" do
      assert Telemetry.prefix() == [:ptc_runner, :sub_agent]
    end

    test "emit/3 emits events with correct prefix" do
      custom_table = :ets.new(:custom_events, [:bag, :public])

      handler = fn event, measurements, metadata, config ->
        :ets.insert(config.table, {event, measurements, metadata})
      end

      handler_id = "custom-handler-#{:erlang.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:ptc_runner, :sub_agent, :test, :event],
        handler,
        %{table: custom_table}
      )

      Telemetry.emit([:test, :event], %{count: 1}, %{name: "test"})

      events = :ets.tab2list(custom_table)
      assert length(events) == 1

      [{event, measurements, metadata}] = events
      assert event == [:ptc_runner, :sub_agent, :test, :event]
      assert measurements == %{count: 1}
      assert metadata == %{name: "test"}

      :telemetry.detach(handler_id)
      :ets.delete(custom_table)
    end

    test "span/3 emits start/stop events" do
      custom_table = :ets.new(:span_events, [:bag, :public])

      handler = fn event, measurements, metadata, config ->
        :ets.insert(config.table, {event, measurements, metadata})
      end

      handler_id = "span-handler-#{:erlang.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:ptc_runner, :sub_agent, :span, :test, :start],
          [:ptc_runner, :sub_agent, :span, :test, :stop]
        ],
        handler,
        %{table: custom_table}
      )

      result =
        Telemetry.span([:span, :test], %{input: "hello"}, fn ->
          Process.sleep(1)
          {"result_value", %{output: "world"}}
        end)

      assert result == "result_value"

      events = :ets.tab2list(custom_table)
      assert length(events) == 2

      start_event = Enum.find(events, fn {event, _, _} -> List.last(event) == :start end)
      stop_event = Enum.find(events, fn {event, _, _} -> List.last(event) == :stop end)

      assert start_event != nil
      assert stop_event != nil

      {_, start_measurements, start_meta} = start_event
      {_, stop_measurements, stop_meta} = stop_event

      assert start_measurements[:system_time] != nil
      assert start_meta.input == "hello"

      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration > 0
      assert stop_meta.output == "world"

      :telemetry.detach(handler_id)
      :ets.delete(custom_table)
    end
  end
end
