defmodule PtcRunner.Kernel.EventSinkTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.EventBudget
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.EventSinkState
  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.TerminalUsage
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Lisp.RetainedSize

  test "default run identifiers have fixed entropy format and remain unique" do
    {:ok, limits} = Limits.new(normal_event_count: 4, normal_event_bytes: 10_000)

    ids =
      for _ <- 1..64 do
        {:ok, sink} =
          EventSink.start(:normal, limits, terminal_reserve: %{count: 0, bytes: 0})

        :ok = EventSink.emit(sink, "run-started", %{})
        [event] = EventSink.events(sink)
        event.run_id
      end

    assert Enum.uniq(ids) == ids
    assert Enum.all?(ids, &Regex.match?(~r/\Arun-[0-9a-f]{12}\z/, &1))
  end

  test "normal sinks reserve the ordinary terminal envelope by default" do
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "default-terminal-reserve")

    assert {:ok, %{terminal_reserve: reserve, ready?: true}} =
             EventSink.session_contract(sink)

    assert reserve == EventSink.terminal_reserve(:normal, limits)
    assert reserve.bytes > limits.event_payload_bytes * 2
  end

  test "drop accounting has fixed type buckets and one saturating overflow bucket" do
    limits = %{
      Limits.defaults()
      | normal_event_count: 3,
        normal_event_bytes: 2_000,
        event_payload_bytes: 100
    }

    {:ok, sink} =
      EventSink.start(:normal, limits,
        run_id: "bounded-drops",
        terminal_reserve: %{count: 0, bytes: 0}
      )

    assert :ok = EventSink.emit(sink, "seed-one", %{})
    assert :ok = EventSink.emit(sink, "seed-two", %{})
    assert :ok = EventSink.emit(sink, "seed-three", %{})

    for index <- 1..40 do
      assert :ok = EventSink.emit(sink, "custom-#{index}", %{})
    end

    dropped = EventSink.dropped(sink)
    assert map_size(dropped) == 17
    assert dropped["$overflow"] == 24
  end

  test "terminal reserve retains one dropped summary and one run-stopped event" do
    {:ok, limits} =
      Limits.new(
        normal_event_count: 4,
        normal_event_bytes: 26_000,
        event_payload_bytes: 8_000
      )

    {:ok, sink} =
      EventSink.start(:normal, limits,
        run_id: "reserved",
        terminal_reserve: EventSink.terminal_reserve(:normal, limits)
      )

    assert :ok = EventSink.emit(sink, "run-started", %{})
    assert :ok = EventSink.emit(sink, "evaluation-started", %{})
    assert :ok = EventSink.emit(sink, "evaluation-stopped", %{})
    assert %{"evaluation-stopped" => 1} = EventSink.dropped(sink)

    assert {:ok, first_batch} =
             EventSink.finalize_and_events(sink, %{
               outcome: :ok,
               reason: nil,
               usage: %{}
             })

    assert {:ok, ^first_batch} = EventSink.finalize_and_events(sink, %{outcome: :error})

    events = first_batch.events

    assert Enum.map(events, & &1.type) ==
             ["run-started", "evaluation-started", "events-dropped", "run-stopped"]

    assert List.last(events).data.outcome == :ok
  end

  test "the minimum admitted normal budget retains run-started and both terminal events" do
    payload_bytes = 8_000
    {:ok, base} = Limits.new(event_payload_bytes: payload_bytes)
    reserve = EventSink.terminal_reserve(:normal, base)
    run_started_bytes = EventBudget.maximum_event_bytes("run-started", payload_bytes)
    payload = exact_payload(payload_bytes)

    {:ok, limits} =
      Limits.new(
        event_payload_bytes: payload_bytes,
        normal_event_bytes: reserve.bytes + run_started_bytes,
        normal_event_count: 3
      )

    {:ok, sink} = EventSink.start(:normal, limits, run_id: "minimum-normal-budget")
    assert EventSink.begin_capacity?(sink, payload)
    assert :ok = EventSink.begin(sink, payload)
    assert :ok = EventSink.emit(sink, "evaluation-started", %{})
    assert %{"evaluation-started" => 1} = EventSink.dropped(sink)

    assert {:ok, %{events: events}} =
             EventSink.finalize_and_events(sink, %{outcome: :ok, usage: %{}})

    assert Enum.map(events, & &1.type) == ["run-started", "events-dropped", "run-stopped"]
  end

  test "terminal reserve remains available after the ordinary byte budget is saturated" do
    {:ok, limits} =
      Limits.new(
        normal_event_count: 10,
        normal_event_bytes: 26_000,
        event_payload_bytes: 8_000
      )

    {:ok, sink} =
      EventSink.start(:normal, limits,
        run_id: "byte-reserved",
        terminal_reserve: EventSink.terminal_reserve(:normal, limits)
      )

    assert :ok = EventSink.emit(sink, "run-started", %{value: String.duplicate("x", 3_500)})

    assert :ok =
             EventSink.emit(sink, "evaluation-started", %{
               value: String.duplicate("x", 3_500)
             })

    assert %{"evaluation-started" => 1} = EventSink.dropped(sink)

    assert {:ok, %{events: events}} =
             EventSink.finalize_and_events(sink, %{outcome: :ok, usage: %{}})

    assert Enum.map(events, & &1.type) ==
             ["run-started", "events-dropped", "run-stopped"]
  end

  test "finalization atomically hands off a frozen terminal batch" do
    {:ok, limits} =
      Limits.new(
        normal_event_count: 4,
        normal_event_bytes: 26_000,
        event_payload_bytes: 8_000
      )

    {:ok, sink} =
      EventSink.start(:normal, limits,
        run_id: "atomic-finalize",
        fail_closed: true,
        terminal_reserve: EventSink.terminal_reserve(:normal, limits)
      )

    assert :ok = EventSink.emit(sink, "run-started", %{})

    assert {:ok, %{events: events}} =
             EventSink.finalize_and_events(sink, %{outcome: :ok, reason: nil})

    EventSink.stop(sink)

    assert Enum.map(events, & &1.type) == ["run-started", "run-stopped"]
    assert List.last(events).data.outcome == :ok
    assert {:error, :event_sink_error} = EventSink.emit(sink, "evaluation-started", %{})
  end

  test "normal sinks report owner failure instead of treating it as an ordinary drop" do
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, fail_closed: true)
    ref = Process.monitor(sink.pid)
    EventSink.stop(sink)
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}
    assert {:error, :event_sink_error} = EventSink.emit(sink, "evaluation-started", %{})
  end

  test "invalid terminal usage is contained without destroying the recorder" do
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "invalid-terminal")

    assert :ok = EventSink.begin(sink, %{})
    assert {:error, :event_sink_error} = EventSink.finalize_and_events(sink, %{usage: nil})
    assert Process.alive?(sink.pid)
    assert Enum.map(EventSink.events(sink), & &1.type) == ["run-started"]
  end

  test "claim distinguishes an existing owner from an unavailable sink" do
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits)
    claim_id = make_ref()

    assert :ok = EventSink.claim(sink, claim_id, %{})
    assert {:error, :event_sink_already_claimed} = EventSink.claim(sink, claim_id, %{})

    assert {:error, :event_sink_claimed_by_other} =
             EventSink.claim(sink, make_ref(), %{})

    assert {:error, :event_sink_error} = EventSink.begin(sink, %{})

    EventSink.stop(sink)
    assert {:error, :event_sink_error} = EventSink.claim(sink, claim_id, %{})
  end

  test "normal sink preflight measures the normalized cleanup-failure terminal payload" do
    legacy_payload = %{
      outcome: :error,
      reason: :event_sink_error,
      usage: %{events_dropped: %{}}
    }

    minimum =
      Enum.find(1..20_000, fn payload_bytes ->
        limits = %{Limits.defaults() | event_payload_bytes: payload_bytes}
        match?({:ok, _state, _handle}, EventSink.prepare(:normal, limits, []))
      end)

    assert minimum == EventBudget.minimum_normal_payload_bytes()
    assert minimum > RetainedSize.bytes(legacy_payload)

    too_tight = %{Limits.defaults() | event_payload_bytes: minimum - 1}
    assert {:error, :invalid_event_sink} = EventSink.prepare(:normal, too_tight, [])

    {:ok, exact} = Limits.new(event_payload_bytes: minimum)
    assert {:ok, _state, _handle} = EventSink.prepare(:normal, exact, [])
  end

  test "the payload minimum finalizes a saturated reachable drop map" do
    minimum = EventBudget.minimum_normal_payload_bytes()
    {:ok, limits} = Limits.new(event_payload_bytes: minimum)
    token = make_ref()

    dropped = saturated_drop_map()

    state =
      EventSinkState.new(
        :normal,
        limits,
        token,
        "run",
        "trace",
        EventSink.terminal_reserve(:normal, limits)
      )
      |> Map.put(:dropped, dropped)

    stopped_data = %{
      outcome: :error,
      reason: :binary.copy(String.duplicate("r", 1_020)),
      usage: %{}
    }

    assert {{:ok, %{events: events}}, _finalized} =
             EventSinkState.handle({token, {:finalize_and_events, stopped_data}}, state)

    assert Enum.map(events, & &1.type) == ["events-dropped", "run-stopped"]
  end

  test "the payload minimum is exactly what the maximum fixed terminal usage needs" do
    sink = %EventSink{pid: self(), token: make_ref(), policy: :normal}
    usage = TerminalUsage.maximum(%{}, %{}, [], catalog_maximum_limits())

    payload_bytes =
      Enum.find(1..20_000, fn payload_bytes ->
        limits = %{Limits.defaults() | event_payload_bytes: payload_bytes}
        EventSink.terminal_usage_capacity?(sink, limits, usage)
      end)

    assert payload_bytes == EventBudget.minimum_normal_payload_bytes()
    assert EventSink.required_terminal_payload_bytes(sink, usage) == payload_bytes

    {:ok, limits} = Limits.new(event_payload_bytes: payload_bytes)
    token = make_ref()

    state =
      EventSinkState.new(
        :normal,
        limits,
        token,
        "run",
        "trace",
        EventSink.terminal_reserve(:normal, limits)
      )
      |> Map.put(:dropped, saturated_drop_map())

    stopped_data = %{
      outcome: :error,
      reason: EventBudget.maximum_terminal_reason(),
      usage: usage
    }

    assert {{:ok, _batch}, _finalized} =
             EventSinkState.handle({token, {:finalize_and_events, stopped_data}}, state)

    too_tight_limits = %{limits | event_payload_bytes: payload_bytes - 1}
    refute EventSink.terminal_usage_capacity?(sink, too_tight_limits, usage)
  end

  test "terminal usage admission exceeds the former cleanup-reason ceiling" do
    usage = %{}

    former_payload = %{
      outcome: :error,
      reason: :provider_cleanup_failed,
      usage: %{events_dropped: %{}}
    }

    former_minimum =
      Enum.find(1..10_000, fn payload_bytes ->
        EventSinkState.payload_within_limit?(former_payload, payload_bytes)
      end)

    limits = %{Limits.defaults() | event_payload_bytes: former_minimum}
    {:ok, sink} = EventSink.start(:private, limits)

    assert EventSinkState.payload_within_limit?(former_payload, former_minimum)
    refute EventSink.terminal_usage_capacity?(sink, limits, usage)
  end

  test "canonical identifiers and event values are validated before retention" do
    {:ok, limits} = Limits.new()

    assert {:error, :invalid_event_sink} =
             EventSink.start(:normal, limits, run_id: String.duplicate("x", 257))

    assert {:error, :invalid_event_sink} =
             EventSink.start(:normal, limits, trace_id: <<255>>)

    {:ok, sink} = EventSink.start(:private, limits, run_id: "canonical-events")

    assert {:error, :event_sink_error} =
             EventSink.emit(sink, "run-started", %{invalid: {1, 2}})

    assert {:error, :event_sink_error} = EventSink.emit(sink, "Not Canonical", %{})
    assert EventSink.events(sink) == []

    assert {:ok, trace_log} = TraceLog.new(source: {:private, sink})
    assert {:ok, %{"items" => []}} = TraceLog.query(trace_log, :list_runs, %{})
  end

  test "event limits account for the normalized JSON payload" do
    {:ok, limits} =
      Limits.new(
        event_payload_bytes: 20_000,
        normal_event_bytes: 100_000
      )

    {:ok, sink} = EventSink.start(:private, limits, run_id: "normalized-accounting")

    expanding_atom = :event_normalization_expands_this_atom_value
    payload = %{"values" => List.duplicate(expanding_atom, 1_000)}

    assert {:error, :event_sink_error} = EventSink.emit(sink, "run-started", payload)
    assert EventSink.events(sink) == []
  end

  defp exact_payload(bytes) do
    Enum.find_value(bytes..1//-1, fn size ->
      payload = %{"value" => String.duplicate("x", size)}
      if RetainedSize.bytes(payload) == bytes, do: payload
    end) || flunk("could not construct a #{bytes}-byte payload")
  end

  defp catalog_maximum_limits do
    {:ok, limits} = Limits.new(Map.new(LimitCatalog.rows(), &{&1.field, &1.maximum}))
    limits
  end

  defp saturated_drop_map do
    1..16
    |> Map.new(fn index ->
      suffix = String.pad_leading(Integer.to_string(index), 3, "0")
      type = <<96 + index>> <> String.duplicate("b", 124) <> suffix
      assert byte_size(type) == 128
      {type, 4_294_967_295}
    end)
    |> Map.put("$overflow", 4_294_967_295)
  end
end
