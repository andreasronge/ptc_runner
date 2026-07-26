defmodule PtcRunner.Kernel.EventSinkTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.EventSinkState
  alias PtcRunner.Kernel.Limits
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
    {:ok, limits} =
      Limits.new(
        normal_event_count: 2,
        normal_event_bytes: 2_000,
        event_payload_bytes: 100
      )

    {:ok, sink} =
      EventSink.start(:normal, limits,
        run_id: "bounded-drops",
        terminal_reserve: %{count: 0, bytes: 0}
      )

    assert :ok = EventSink.emit(sink, "seed-one", %{})
    assert :ok = EventSink.emit(sink, "seed-two", %{})

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
        normal_event_bytes: 20_000,
        event_payload_bytes: 5_000
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

  test "terminal reserve remains available after the ordinary byte budget is saturated" do
    {:ok, limits} =
      Limits.new(
        normal_event_count: 10,
        normal_event_bytes: 20_000,
        event_payload_bytes: 5_000
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
        normal_event_bytes: 20_000,
        event_payload_bytes: 5_000
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
        {:ok, limits} = Limits.new(event_payload_bytes: payload_bytes)
        match?({:ok, _state, _handle}, EventSink.prepare(:normal, limits, []))
      end)

    assert minimum > RetainedSize.bytes(legacy_payload)

    {:ok, too_tight} = Limits.new(event_payload_bytes: minimum - 1)
    assert {:error, :invalid_event_sink} = EventSink.prepare(:normal, too_tight, [])

    {:ok, exact} = Limits.new(event_payload_bytes: minimum)
    assert {:ok, _state, _handle} = EventSink.prepare(:normal, exact, [])
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

    {:ok, limits} = Limits.new(event_payload_bytes: former_minimum)
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
end
