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
(return {:value 42})
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
      # run.stop uses slim_agent (not the full struct)
      assert stop_meta.agent.output == agent.output
      assert stop_meta.agent.max_turns == agent.max_turns
      assert stop_meta.status == :ok
      assert stop_meta.step.return == %{"value" => 42}
      # run.stop surfaces return value at top level
      assert stop_meta.return == %{"value" => 42}
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
    test "emits :turn :start and :stop for each turn immediately", %{table: table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 5)

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, "(+ 1 2)"}
          2 -> {:ok, ~S|(return {:value 42})|}
          _ -> {:ok, "(+ 1 2)"}
        end
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      turn_starts = get_events_by_name(table, [:ptc_runner, :sub_agent, :turn, :start])
      turn_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :turn, :stop])

      # Start events for each turn
      assert length(turn_starts) == 2

      # Stop event for EVERY turn (emitted immediately after each turn completes)
      assert length(turn_stops) == 2

      # Check first turn event
      first_start =
        turn_starts
        |> Enum.sort_by(fn {_, _, meta, _} -> meta.turn end)
        |> List.first()

      {_, start_measurements, start_meta, _} = first_start
      assert start_measurements == %{}
      # turn.start uses slim_agent
      assert start_meta.agent.output == agent.output
      assert start_meta.agent.max_turns == agent.max_turns
      assert start_meta.turn == 1

      # Check turn stop has duration (all stop events should have duration)
      Enum.each(turn_stops, fn {_, stop_measurements, _stop_meta, _} ->
        assert is_integer(stop_measurements.duration)
        assert stop_measurements.duration > 0
      end)
    end
  end

  describe "llm events" do
    test "emits :llm :start and :stop events for each LLM call", %{table: table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|(return {:done true})|}
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
      # llm.start uses slim_agent and includes model info
      assert start_meta.agent.output == agent.output
      assert start_meta.agent.max_turns == agent.max_turns
      assert start_meta.turn == 1
      assert is_list(start_meta.messages)
      assert Map.has_key?(start_meta, :model)

      # Stop event
      assert is_integer(stop_measurements.duration)
      assert stop_meta.agent.output == agent.output
      assert stop_meta.turn == 1
      assert stop_meta.response =~ "return"
    end

    test "includes tokens in :llm :stop measurements when LLM returns tokens", %{table: table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 2)

      llm = fn _ ->
        {:ok, %{content: ~S|(return {:done true})|, tokens: %{input: 100, output: 50}}}
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
        {:ok, ~S|(return {:done true})|}
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
            _ -> ~S|(return {:value 42})|
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
        {:ok, ~S|(return {:done true})|}
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
            {:ok, ~S|(return {:value 42})|}
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
        {:ok, %{content: ~S|(return {:done true})|, tokens: %{input: 50, output: 25}}}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      turn_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :turn, :stop])
      assert length(turn_stops) == 1

      [{_, stop_measurements, _stop_meta, _}] = turn_stops

      assert is_integer(stop_measurements.duration)
      assert stop_measurements.tokens == 75
    end

    test "includes per-turn token breakdown in :turn :stop measurements", %{table: table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 2)

      llm = fn _ ->
        {:ok,
         %{
           content: ~S|(return {:done true})|,
           tokens: %{input: 100, output: 25, cache_creation: 50, cache_read: 30}
         }}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      [{_, stop_measurements, _stop_meta, _}] =
        get_events_by_name(table, [:ptc_runner, :sub_agent, :turn, :stop])

      assert stop_measurements.input_tokens == 100
      assert stop_measurements.output_tokens == 25
      assert stop_measurements.cache_creation_tokens == 50
      assert stop_measurements.cache_read_tokens == 30
      assert stop_measurements.tokens == 125
    end

    test "includes prints in :turn :stop metadata", %{table: table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|(do (println "hello") (return {:done true}))|}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      [{_, _measurements, stop_meta, _}] =
        get_events_by_name(table, [:ptc_runner, :sub_agent, :turn, :stop])

      assert stop_meta.prints == ["hello"]
    end

    test "includes system_prompt only in first llm.start event", %{table: table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 3)

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, ~S|(+ 1 1)|}
          _ -> {:ok, ~S|(return {:done true})|}
        end
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      llm_starts = get_events_by_name(table, [:ptc_runner, :sub_agent, :llm, :start])
      assert length(llm_starts) == 2

      [{_, _, first_meta, _}, {_, _, second_meta, _}] =
        Enum.sort_by(llm_starts, fn {_, _, meta, _} -> meta.turn end)

      # First turn includes system_prompt
      assert is_binary(first_meta.system_prompt)
      assert String.length(first_meta.system_prompt) > 0

      # Second turn does not
      refute Map.has_key?(second_meta, :system_prompt)
    end
  end

  describe "grep tools" do
    test "grep_tools option makes grep and grep-n available as tools", %{table: _table} do
      agent =
        SubAgent.new(
          prompt: "Search for errors in {{log}}",
          grep_tools: true,
          max_turns: 2
        )

      llm = fn _ ->
        {:ok, ~S|(return (tool/grep {:pattern "error" :text data/log}))|}
      end

      {:ok, step} =
        SubAgent.run(agent,
          llm: llm,
          context: %{log: "line1\nerror: bad\nline3"}
        )

      assert step.return == ["error: bad"]
    end
  end

  describe "tool events" do
    test "emits :tool :start and :stop events for tool calls", %{table: table} do
      # Tools receive string keys at the boundary
      helper_fn = fn args -> args["x"] * 2 end

      agent = SubAgent.new(prompt: "Test", tools: %{"helper" => helper_fn}, max_turns: 2)

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, ~S|(tool/helper {:x 5})|}
          _ -> {:ok, ~S|(return {:done true})|}
        end
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      tool_starts = get_events_by_name(table, [:ptc_runner, :sub_agent, :tool, :start])
      tool_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :tool, :stop])

      # 2 start events: one from wrap_with_telemetry (in-sandbox), one from
      # emit_tool_telemetry (post-sandbox, for trace log reliability)
      assert length(tool_starts) == 2
      # 2 stop events: one from wrap_with_telemetry (in-sandbox), one from
      # emit_tool_telemetry (post-sandbox, for trace log reliability)
      assert length(tool_stops) == 2

      # All start events should have valid metadata
      Enum.each(tool_starts, fn {_, _measurements, start_meta, _} ->
        assert start_meta.tool_name == "helper"
        # Args have string keys at the boundary
        assert start_meta.args == %{"x" => 5}
      end)

      # Both stop events should have valid metadata
      Enum.each(tool_stops, fn {_, stop_measurements, stop_meta, _} ->
        assert is_integer(stop_measurements.duration)
        assert stop_meta.tool_name == "helper"
      end)
    end

    test "post-sandbox tool stop event includes tool_name and duration", %{table: table} do
      helper_fn = fn args -> args["x"] + 1 end

      agent = SubAgent.new(prompt: "Test", tools: %{"inc" => helper_fn}, max_turns: 2)

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, ~S|(tool/inc {:x 3})|}
          _ -> {:ok, ~S|(return {:done true})|}
        end
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      tool_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :tool, :stop])

      # Post-sandbox re-emission produces a second :stop event alongside the
      # in-sandbox span :stop. Both carry tool_name and duration.
      assert length(tool_stops) == 2

      Enum.each(tool_stops, fn {_, measurements, meta, _} ->
        assert meta.tool_name == "inc"
        assert is_integer(measurements.duration)
      end)
    end

    test "llm-query with tracing propagates child_trace_id in tool stop metadata", %{
      table: table
    } do
      trace_dir =
        Path.join(
          System.tmp_dir!(),
          "telemetry_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(trace_dir)
      on_exit(fn -> File.rm_rf!(trace_dir) end)

      call_count = :counters.new(1, [:atomics])

      llm = fn %{messages: _} ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        case count do
          # Parent agent turn 1: call llm-query tool
          1 ->
            {:ok, ~S|(tool/llm-query {:prompt "Is sky blue?" :signature "{answer :string}"})|}

          # Inner llm-query call (JSON mode)
          2 ->
            {:ok, ~s|{"answer": "yes"}|}

          # Parent agent turn 2: return
          _ ->
            {:ok, ~S|(return {:done true})|}
        end
      end

      agent =
        SubAgent.new(
          prompt: "Test",
          tools: %{},
          llm_query: true,
          max_turns: 2
        )

      trace_context = %{
        trace_id: "parent123",
        parent_span_id: nil,
        depth: 0,
        trace_dir: trace_dir
      }

      {:ok, _step} = SubAgent.run(agent, llm: llm, trace_context: trace_context)

      tool_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :tool, :stop])

      # At least one stop event should carry child_trace_id
      stops_with_trace =
        Enum.filter(tool_stops, fn {_, _, meta, _} -> Map.has_key?(meta, :child_trace_id) end)

      assert stops_with_trace != []

      [{_, _, meta, _} | _] = stops_with_trace
      assert is_binary(meta.child_trace_id)
      assert meta.tool_name == "llm-query"
    end

    test "emits :tool :exception on tool crash", %{table: table} do
      failing_fn = fn _args -> raise "Tool failure!" end

      agent = SubAgent.new(prompt: "Test", tools: %{"crasher" => failing_fn}, max_turns: 1)

      llm = fn _ ->
        {:ok, ~S|(tool/crasher {:x 1})|}
      end

      {:error, _step} = SubAgent.run(agent, llm: llm)

      tool_exceptions = get_events_by_name(table, [:ptc_runner, :sub_agent, :tool, :exception])

      assert length(tool_exceptions) == 1

      [{_, measurements, meta, _}] = tool_exceptions

      assert is_integer(measurements.duration)
      # tool.exception comes from in-sandbox span, still has full agent
      assert meta.tool_name == "crasher"
      assert meta.kind == :error
      assert meta.reason.__struct__ == RuntimeError
    end

    test "summarizes large tool arguments in telemetry metadata", %{table: table} do
      large_list = Enum.to_list(1..1000)
      large_string = String.duplicate("x", 500)
      large_map = Map.new(1..20, fn i -> {i, i} end)

      helper_fn = fn args -> args end

      agent = SubAgent.new(prompt: "Test", tools: %{"helper" => helper_fn}, max_turns: 2)

      llm = fn %{turn: turn} ->
        case turn do
          1 ->
            {:ok,
             %{
               content:
                 ~S|(tool/helper {:list data/list :string data/string :map data/map :small 42})|,
               tokens: %{}
             }}

          _ ->
            {:ok, ~S|(return {:done true})|}
        end
      end

      {:ok, _step} =
        SubAgent.run(agent,
          llm: llm,
          context: %{list: large_list, string: large_string, map: large_map}
        )

      tool_starts = get_events_by_name(table, [:ptc_runner, :sub_agent, :tool, :start])

      # 2 start events: in-sandbox span + post-sandbox re-emission
      assert length(tool_starts) == 2

      # The in-sandbox span event has summarized args; check the first one
      [{_, _, start_meta, _} | _] = tool_starts

      assert start_meta.tool_name == "helper"
      # Args have string keys at the boundary
      assert start_meta.args["small"] == 42
      assert start_meta.args["list"] == "List(1000)"
      assert start_meta.args["string"] == "String(500 bytes)"
      assert start_meta.args["map"] == "Map(20)"
    end

    test "summarizes arbitrary results using fallback inspect settings", %{table: table} do
      # A moderately complex structure that isn't a list/map/binary
      result = {:complex, %{a: 1, b: 2, c: 3, d: 4}, [1, 2, 3, 4]}
      helper_fn = fn _ -> result end

      agent = SubAgent.new(prompt: "Test", tools: %{"helper" => helper_fn}, max_turns: 1)
      llm = fn _ -> {:ok, ~S|(tool/helper {})|} end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      tool_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :tool, :stop])
      [{_, _, stop_meta, _} | _] = tool_stops

      # limit: 3 should cap the map keys and list elements
      # result = {:complex, %{a: 1, b: 2, c: 3, ...}, [1, 2, 3, ...]}
      assert stop_meta.result =~ "..."
      # Allow small buffer for delimiters
      assert byte_size(stop_meta.result) <= 100 + 10
    end
  end

  describe "end-to-end execution" do
    test "full agent execution emits all expected events", %{table: table} do
      # Tools receive string keys at the boundary
      counter_fn = fn args -> args["n"] + 1 end

      agent =
        SubAgent.new(
          prompt: "Test with {{input}}",
          tools: %{"counter" => counter_fn},
          max_turns: 3
        )

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, ~S|(tool/counter {:n 5})|}
          _ -> {:ok, ~S|(return {:value 42})|}
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
      # 2 start events: in-sandbox span + post-sandbox re-emission for trace log
      assert length(tool_starts) == 2
      # 2 stop events: in-sandbox span + post-sandbox re-emission for trace log
      assert length(tool_stops) == 2
    end
  end

  describe "span correlation" do
    test "span events include span_id and parent_span_id", %{table: table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|(return {:value 42})|}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      # Check run events have span correlation
      run_starts = get_events_by_name(table, [:ptc_runner, :sub_agent, :run, :start])
      run_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :run, :stop])

      [{_, _, start_meta, _}] = run_starts
      [{_, _, stop_meta, _}] = run_stops

      # Run is the root span, so parent should be nil
      assert is_binary(start_meta.span_id)
      assert String.length(start_meta.span_id) == 8
      assert start_meta.parent_span_id == nil

      # Start and stop should have the same span_id
      assert start_meta.span_id == stop_meta.span_id
      assert stop_meta.parent_span_id == nil
    end

    test "nested spans have correct parent-child relationship", %{table: table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|(return {:done true})|}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      # Get all events
      run_starts = get_events_by_name(table, [:ptc_runner, :sub_agent, :run, :start])
      llm_starts = get_events_by_name(table, [:ptc_runner, :sub_agent, :llm, :start])

      [{_, _, run_meta, _}] = run_starts
      run_span_id = run_meta.span_id

      # LLM spans should have run as parent
      Enum.each(llm_starts, fn {_, _, meta, _} ->
        assert is_binary(meta.span_id)
        assert meta.parent_span_id == run_span_id
      end)
    end

    test "different spans have unique span IDs", %{table: table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 3)

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, "(+ 1 2)"}
          2 -> {:ok, "(+ 3 4)"}
          _ -> {:ok, ~S|(return {:done true})|}
        end
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      # Collect all start events (each span gets a unique ID)
      run_starts = get_events_by_name(table, [:ptc_runner, :sub_agent, :run, :start])
      llm_starts = get_events_by_name(table, [:ptc_runner, :sub_agent, :llm, :start])

      # Each LLM call should have a unique span ID
      llm_span_ids = Enum.map(llm_starts, fn {_, _, meta, _} -> meta.span_id end)
      assert length(Enum.uniq(llm_span_ids)) == length(llm_span_ids)

      # Run span ID should be different from LLM span IDs
      [{_, _, run_meta, _}] = run_starts
      refute run_meta.span_id in llm_span_ids
    end

    test "emit events include span context from current span", %{table: table} do
      # Turn start/stop events are emitted via Telemetry.emit, not span
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|(return {:value 42})|}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      turn_starts = get_events_by_name(table, [:ptc_runner, :sub_agent, :turn, :start])
      turn_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :turn, :stop])

      # Turn events should have span context
      [{_, _, start_meta, _}] = turn_starts
      [{_, _, stop_meta, _}] = turn_stops

      assert is_binary(start_meta.span_id)
      assert is_binary(stop_meta.span_id)
      # Turn events are emitted within the run span, so parent should be the run span
    end
  end

  describe "turn.stop enhanced metadata" do
    test "includes program, result_preview, and type", %{table: table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 2)

      llm = fn _ ->
        {:ok, ~S|(return {:value 42})|}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      turn_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :turn, :stop])
      assert length(turn_stops) == 1

      [{_, _, stop_meta, _}] = turn_stops

      # Program should contain the PTC-Lisp code
      assert stop_meta.program == ~S|(return {:value 42})|

      # Result preview should be a string representation
      assert is_binary(stop_meta.result_preview)
      assert stop_meta.result_preview =~ "value"

      # Type should be :normal for first turn
      assert stop_meta.type == :normal
    end

    test "includes type :must_return on final work turn", %{table: table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 2)

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, "(+ 1 2)"}
          _ -> {:ok, ~S|(return {:done true})|}
        end
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      turn_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :turn, :stop])
      # Final turn emits turn.stop event with :must_return type
      # Get the last stop event (sorted by timestamp)
      [{_, _, stop_meta, _}] =
        turn_stops
        |> Enum.sort_by(fn {_, _, _, ts} -> ts end, :desc)
        |> Enum.take(1)

      assert stop_meta.type == :must_return
    end

    test "result_preview is truncated for large results", %{table: table} do
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 2)

      # Return a large map in PTC-Lisp syntax
      llm = fn _ ->
        large_map = Enum.map_join(1..50, " ", fn i -> ":key#{i} #{i}" end)
        {:ok, "(return {#{large_map}})"}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      turn_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :turn, :stop])
      [{_, _, stop_meta, _}] = turn_stops

      # Result preview should be truncated to max 200 chars
      assert String.length(stop_meta.result_preview) <= 200
    end

    test "program is nil when parsing fails", %{table: table} do
      # Use max_turns: 2 to ensure we're in loop mode and emit turn stop
      agent = SubAgent.new(prompt: "Test", tools: %{}, max_turns: 2)

      llm = fn _ ->
        {:ok, "no valid code here"}
      end

      {:error, _step} = SubAgent.run(agent, llm: llm)

      turn_stops = get_events_by_name(table, [:ptc_runner, :sub_agent, :turn, :stop])

      # All turns should have nil program when parsing fails
      Enum.each(turn_stops, fn {_, _, stop_meta, _} ->
        assert stop_meta.program == nil
      end)
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
      # emit/3 adds span context (nil when not in a span)
      assert metadata.name == "test"
      assert Map.has_key?(metadata, :span_id)
      assert Map.has_key?(metadata, :parent_span_id)

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
