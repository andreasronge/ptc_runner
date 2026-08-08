defmodule PtcRunner.Soak.AnalysisSessionSoakTest do
  @moduledoc """
  Repeated `AnalysisSession` and `SessionTrace` churn (use-case row 10).

  This row is an owner *pair*: the trace owner and the evaluation owner are
  separate processes with separate lifetimes, and a session that reaps one but
  not the other looks correct from either side alone.

  Resource model, written down before the workload:

  | resource | creator | owner | authorized user | closer |
  |---|---|---|---|---|
  | `AnalysisSession` process | `AnalysisSessionBuilder.start/4` | itself | the holder of `{pid, token}` | `close/1`, `abort/2`, `stop/1`, or its own lifecycle timer |
  | `SessionTrace` process | the builder | itself | the session | session close, or `stop/1` |
  | `RunState` and `EventSink` processes | the builder | themselves | the session | session close |
  | lifecycle timer | `init/1` | the session | nobody | fires on expiry and terminates the session |

  Behavior on termination:

    * **caller death** — the session monitors nothing about its caller; a
      handle is `{pid, token}`, so a dead caller leaves an orphan the lifecycle
      timer eventually reaps.
    * **owner death** — killing the session process must take its trace, run
      state and sink with it, or each becomes a per-cycle orphan.
    * **deadline expiry** — the session carries its own lifecycle timer. This
      is the variant where `terminate/2` does not run on the caller's schedule,
      and it is the one the happy path cannot reach.

  The trace destination is a temporary directory per cycle, so a leaked file
  descriptor or a retained directory identity shows up as a port or an
  unreclaimed process rather than being hidden by reuse.
  """

  use ExUnit.Case, async: false

  @moduletag :soak
  @moduletag timeout: :infinity

  alias PtcRunner.Kernel.AnalysisSession
  alias PtcRunner.Kernel.AnalysisSessionBuilder
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LogAnalysisProfile
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.TestSupport.LifecycleSoak
  alias PtcRunner.TestSupport.MemorySoak

  # Higher than the other families: a cycle here builds a profile, compiles its
  # components, and starts four processes, so its batch-to-batch drift is
  # correspondingly larger.
  @threshold_bytes_per_cycle 8_192

  # A cycle here builds a profile, compiles its components, and starts four
  # processes — roughly half a second each, against microseconds for the other
  # families. `PTC_SOAK_ITERATIONS=3000` would put this one family into the
  # hours, so it is capped. Measured at ~1s per cycle, this puts the file at
  # roughly seven minutes across its four variants. Not a silent cap: the
  # harness prints the cycle count it actually ran in every report.
  @max_cycles 25

  setup_all do
    directory =
      Path.join(System.tmp_dir!(), "ptc-soak-analysis-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    seed_trace(directory, "soak-seed")
    {:ok, traces: directory}
  end

  describe "normal completion" do
    test "close/1 reaps the session and its trace owner", %{traces: traces} do
      LifecycleSoak.soak!(
        [
          name: "analysis session (normal close)",
          threshold_bytes_per_cycle: @threshold_bytes_per_cycle,
          cycles: cycles()
        ],
        fn _cycle ->
          {session, owned} = open(traces)
          assert {:ok, _info} = AnalysisSession.close(session)
          AnalysisSession.stop(session)

          ledger(owned)
        end
      )
    end

    test "abort/2 reaps the same set as a clean close", %{traces: traces} do
      LifecycleSoak.soak!(
        [
          name: "analysis session (abort)",
          threshold_bytes_per_cycle: @threshold_bytes_per_cycle,
          cycles: cycles()
        ],
        fn _cycle ->
          {session, owned} = open(traces)
          assert {:ok, _info} = AnalysisSession.abort(session, :soak_cycle)
          AnalysisSession.stop(session)

          ledger(owned)
        end
      )
    end
  end

  describe "owner death" do
    test "killing the session takes its trace, run state and sink with it", %{traces: traces} do
      LifecycleSoak.soak!(
        [
          name: "analysis session (owner death)",
          threshold_bytes_per_cycle: @threshold_bytes_per_cycle,
          cycles: cycles()
        ],
        fn _cycle ->
          {session, owned} = open(traces)

          # No close and no stop: `terminate/2` never runs. Every process the
          # builder created has to be reclaimed by its own linkage, and a
          # survivor here is a per-cycle orphan.
          kill_and_await(session.pid)
          Enum.each(owned, &await_dead/1)

          ledger(owned)
        end
      )
    end
  end

  describe "deadline expiry" do
    test "the lifecycle timer reaps a session nobody closes", %{traces: traces} do
      LifecycleSoak.soak!(
        [
          name: "analysis session (lifecycle expiry)",
          threshold_bytes_per_cycle: @threshold_bytes_per_cycle,
          cycles: cycles()
        ],
        fn _cycle ->
          {session, owned} = open(traces)

          # The lifecycle timer is armed for the profile's whole run duration
          # and the builder exposes no option to shorten it, so waiting for it
          # would make every cycle cost that duration. Delivering the session
          # its own `{:deadline_expired, token}` message reaches the same
          # handler on demand — the token is read from the session's state, so
          # a message with the wrong one is ignored exactly as it would be in
          # production, and nothing here sleeps.
          expire(session)

          # The handler closes the session's resources and replies `:noreply` —
          # it does not stop the session process, and does not reap everything
          # the builder created. `stop/1` finishes the teardown, and the ledger
          # is what says whether the pair as a whole came back.
          AnalysisSession.stop(session)

          ledger(owned)
        end
      )
    end
  end

  defp open(traces) do
    {:ok, session, _info} =
      AnalysisSessionBuilder.start(
        LogAnalysisProfile.id(),
        %{"traces" => traces},
        {:directory, traces}
      )

    {session, owned_processes(session)}
  end

  # Captured at creation, from the session's own state. Nothing here publishes
  # an authority marker, and scanning for owners would find the wrong ones, so
  # the identities have to be read out while the session is still alive.
  defp owned_processes(session) do
    state = :sys.get_state(session.pid)

    [session.pid, state.session_trace.pid, state.run_state.pid, state.config.event_sink.pid]
    |> Enum.filter(&is_pid/1)
    |> Enum.uniq()
  end

  defp cycles, do: min(MemorySoak.iteration_count(), @max_cycles)

  defp expire(session) do
    %{deadline_token: token} = :sys.get_state(session.pid)
    send(session.pid, {:deadline_expired, token})
    :ok
  end

  defp ledger(owned), do: LifecycleSoak.ledger(processes: owned)

  defp kill_and_await(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    :ok
  end

  defp await_dead(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    :ok
  end

  defp seed_trace(directory, run_id) do
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: run_id)
    :ok = EventSink.emit(sink, "run-started", %{})
    :ok = EventSink.emit(sink, "run-stopped", %{outcome: :ok, reason: nil})
    :ok = TraceLog.append_jsonl(Path.join(directory, run_id <> ".jsonl"), EventSink.events(sink))
    EventSink.stop(sink)
  end
end
