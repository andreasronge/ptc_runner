defmodule PtcRunner.Kernel.ViewerReplAdapterTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.ViewerReplAdapter
  alias PtcRunner.Kernel.ViewerReplBackend

  @tag :tmp_dir
  test "connected backend owns an idempotent log-analysis session ledger", %{tmp_dir: trace_dir} do
    seed_trace(trace_dir, "seed")

    assert {:ok, backend, features} =
             ViewerReplAdapter.connect(%{
               trace_dir: trace_dir,
               profile_id: "log-analysis-v2"
             })

    assert features == %{
             "enabled" => true,
             "namespaces" => ["cap", "log", "log.analysis"],
             "profile_id" => "log-analysis-v2",
             "source_limit_bytes" => 65_536
           }

    start_id = random_id()
    public_session_id = random_id()
    assert :ok = ViewerReplAdapter.prepare_operation(backend, nil, :start, start_id)

    assert {:ok, session, info} =
             ViewerReplAdapter.start(backend, start_id, public_session_id)

    assert info.session_id == public_session_id
    assert info.profile_id == "log-analysis-v2"

    assert Map.keys(info) |> Enum.sort() ==
             Enum.sort([
               :evaluation_count,
               :lifecycle,
               :namespaces,
               :profile_digest,
               :profile_id,
               :session_id,
               :snapshot,
               :terminal_reason,
               :trace,
               :usage
             ])

    assert {:ok, %{session_id: ^public_session_id}} = ViewerReplAdapter.info(backend, session)
    assert {:ok, ^session, ^info} = ViewerReplAdapter.reconcile_start(backend, start_id)
    assert {:error, :invalid_operation} = ViewerReplAdapter.start(backend, start_id, random_id())
    assert :ok = ViewerReplAdapter.acknowledge_operation(backend, :start, start_id)

    second_start_id = random_id()

    assert {:error, :invalid_operation} =
             ViewerReplAdapter.prepare_operation(backend, nil, :start, second_start_id)

    evaluation_id = random_id()
    source = "(log/runs {})"
    assert :ok = ViewerReplAdapter.prepare_operation(backend, session, :evaluation, evaluation_id)
    assert {:ok, result} = ViewerReplAdapter.evaluate(backend, session, evaluation_id, source)
    assert result.status == :ok

    assert {:error, :invalid_operation} =
             ViewerReplAdapter.evaluate(backend, session, evaluation_id, "(+ 1 2)")

    assert {:error, :operation_not_prepared} =
             ViewerReplAdapter.evaluate(backend, random_id(), evaluation_id, source)

    assert {:ok, ^result} = ViewerReplAdapter.reconcile_evaluate(backend, session, evaluation_id)
    assert :ok = ViewerReplAdapter.acknowledge_operation(backend, :evaluation, evaluation_id)

    assert {:ok, %{source: ~s[(log/run "seed")]}} =
             ViewerReplAdapter.template(backend, session, :run, "seed")

    assert {:ok, %{source: ~s[(log/turns "seed" {})]}} =
             ViewerReplAdapter.template(backend, session, :turns, "seed")

    close_id = random_id()
    assert :ok = ViewerReplAdapter.prepare_operation(backend, session, :close, close_id)
    assert {:ok, closed_info} = ViewerReplAdapter.close(backend, session, close_id)
    assert closed_info.lifecycle == :closed
    assert closed_info.session_id == public_session_id
    assert {:ok, ^closed_info} = ViewerReplAdapter.reconcile_close(backend, session, close_id)
    assert :ok = ViewerReplAdapter.acknowledge_operation(backend, :close, close_id)
    assert {:error, :session_closed} = ViewerReplAdapter.info(backend, session)
  end

  @tag :tmp_dir
  test "preparation binds IDs and reconciliation seals work before it starts", %{
    tmp_dir: trace_dir
  } do
    seed_trace(trace_dir, "seed")

    assert {:ok, backend, _features} =
             ViewerReplAdapter.connect(%{
               trace_dir: trace_dir,
               profile_id: "log-analysis-v2"
             })

    start_id = random_id()
    assert :ok = ViewerReplAdapter.prepare_operation(backend, nil, :start, start_id)

    assert {:error, :operation_active} =
             ViewerReplAdapter.acknowledge_operation(backend, :start, start_id)

    assert {:error, :not_started} = ViewerReplAdapter.reconcile_start(backend, start_id)
    assert {:error, :not_started} = ViewerReplAdapter.start(backend, start_id, random_id())
    assert :ok = ViewerReplAdapter.acknowledge_operation(backend, :start, start_id)

    assert {:error, :operation_not_prepared} =
             ViewerReplAdapter.start(backend, start_id, random_id())
  end

  @tag :tmp_dir
  test "connected backend exits and cleans sessions when its lifecycle owner exits", %{
    tmp_dir: trace_dir
  } do
    seed_trace(trace_dir, "seed")
    parent = self()

    owner =
      spawn(fn ->
        {:ok, backend, _features} =
          ViewerReplAdapter.connect(%{
            trace_dir: trace_dir,
            profile_id: "log-analysis-v2"
          })

        start_id = random_id()
        :ok = ViewerReplAdapter.prepare_operation(backend, nil, :start, start_id)
        {:ok, _session, _info} = ViewerReplAdapter.start(backend, start_id, random_id())
        send(parent, {:backend_ready, backend.pid})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:backend_ready, backend_pid}, 5_000
    backend_ref = Process.monitor(backend_pid)
    send(owner, :stop)
    assert_receive {:DOWN, ^backend_ref, :process, ^backend_pid, :normal}, 5_000
  end

  test "connection and operation inputs are closed contracts" do
    assert {:error, :invalid_repl_connection} = ViewerReplAdapter.connect(%{})
    assert {:error, :invalid_repl_connection} = ViewerReplAdapter.connect(%{trace_dir: "."})
  end

  test "structured retained-limit failures keep their public start classification" do
    assert :source_retained_limit_exceeded =
             ViewerReplBackend.normalize_start_error(
               {:source_retained_limit_exceeded,
                %{
                  source: :ptc_trace_snapshot,
                  measured_bytes: 4_096,
                  limit_bytes: 1_024
                }}
             )
  end

  @tag :tmp_dir
  test "malformed evaluation and control inputs cannot crash the backend", %{tmp_dir: trace_dir} do
    seed_trace(trace_dir, "seed")

    assert {:ok, backend, _features} =
             ViewerReplAdapter.connect(%{
               trace_dir: trace_dir,
               profile_id: "log-analysis-v2"
             })

    start_id = random_id()
    assert :ok = ViewerReplAdapter.prepare_operation(backend, nil, :start, start_id)
    assert {:ok, session, _info} = ViewerReplAdapter.start(backend, start_id, random_id())
    assert :ok = ViewerReplAdapter.acknowledge_operation(backend, :start, start_id)

    evaluation_id = random_id()
    assert :ok = ViewerReplAdapter.prepare_operation(backend, session, :evaluation, evaluation_id)

    assert {:error, :invalid_source} =
             ViewerReplAdapter.evaluate(backend, session, evaluation_id, [:not, :source])

    assert {:error, :source_too_large} =
             ViewerReplAdapter.evaluate(
               backend,
               session,
               evaluation_id,
               :binary.copy("x", 65_537)
             )

    assert {:error, :invalid_source} =
             ViewerReplAdapter.evaluate(backend, session, evaluation_id, <<255>>)

    assert {:error, :adapter_failure} = ViewerReplAdapter.abort(backend, session, "not-an-atom")
    assert Process.alive?(backend.pid)
  end

  @tag :tmp_dir
  test "Core session death fails the backend and invalidates cached start success", %{
    tmp_dir: trace_dir
  } do
    seed_trace(trace_dir, "seed")

    assert {:ok, backend, _features} =
             ViewerReplAdapter.connect(%{
               trace_dir: trace_dir,
               profile_id: "log-analysis-v2"
             })

    start_id = random_id()
    assert :ok = ViewerReplAdapter.prepare_operation(backend, nil, :start, start_id)
    assert {:ok, _session, _info} = ViewerReplAdapter.start(backend, start_id, random_id())

    %{sessions: sessions} = :sys.get_state(backend.pid)
    [%{worker: worker}] = Map.values(sessions)
    {:monitors, [{:process, core_session}]} = Process.info(worker, :monitors)
    Process.exit(core_session, :kill)

    await_backend_state(backend.pid, fn state ->
      state.backend_failed? and map_size(state.sessions) == 0
    end)

    assert {:error, :adapter_failure} = ViewerReplAdapter.reconcile_start(backend, start_id)
    assert :ok = ViewerReplAdapter.acknowledge_operation(backend, :start, start_id)

    assert {:error, :adapter_failure} =
             ViewerReplAdapter.prepare_operation(backend, nil, :start, random_id())
  end

  @tag :tmp_dir
  test "Core session death after start acknowledgement fails the backend closed", %{
    tmp_dir: trace_dir
  } do
    seed_trace(trace_dir, "seed")

    assert {:ok, backend, _features} =
             ViewerReplAdapter.connect(%{
               trace_dir: trace_dir,
               profile_id: "log-analysis-v2"
             })

    start_id = random_id()
    assert :ok = ViewerReplAdapter.prepare_operation(backend, nil, :start, start_id)
    assert {:ok, session, _info} = ViewerReplAdapter.start(backend, start_id, random_id())
    assert :ok = ViewerReplAdapter.acknowledge_operation(backend, :start, start_id)

    %{sessions: sessions} = :sys.get_state(backend.pid)
    [%{worker: worker}] = Map.values(sessions)
    {:monitors, [{:process, core_session}]} = Process.info(worker, :monitors)
    Process.exit(core_session, :kill)

    await_backend_state(backend.pid, fn state ->
      state.backend_failed? and map_size(state.sessions) == 0
    end)

    assert {:error, :adapter_failure} =
             ViewerReplAdapter.prepare_operation(backend, session, :evaluation, random_id())
  end

  @tag :tmp_dir
  test "backend OTP status redacts the configured directory and ledger", %{tmp_dir: trace_dir} do
    marker = "PRIVATE_VIEWER_TRACE_DIRECTORY"
    private_dir = Path.join(trace_dir, marker)
    File.mkdir!(private_dir)
    seed_trace(private_dir, "seed")

    assert {:ok, backend, _features} =
             ViewerReplAdapter.connect(%{
               trace_dir: private_dir,
               profile_id: "log-analysis-v2"
             })

    status = backend.pid |> :sys.get_status() |> inspect()
    refute status =~ marker
  end

  @tag :tmp_dir
  test "abnormal backend death cannot orphan its session worker", %{tmp_dir: trace_dir} do
    seed_trace(trace_dir, "seed")

    assert {:ok, backend, _features} =
             ViewerReplAdapter.connect(%{
               trace_dir: trace_dir,
               profile_id: "log-analysis-v2"
             })

    start_id = random_id()
    assert :ok = ViewerReplAdapter.prepare_operation(backend, nil, :start, start_id)
    assert {:ok, _session, _info} = ViewerReplAdapter.start(backend, start_id, random_id())

    %{sessions: sessions} = :sys.get_state(backend.pid)
    [%{worker: worker}] = Map.values(sessions)
    worker_ref = Process.monitor(worker)
    Process.unlink(backend.pid)
    Process.exit(backend.pid, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 5_000
  end

  @tag :tmp_dir
  test "an ambiguous operation timeout waits for worker death and fails the backend closed", %{
    tmp_dir: trace_dir
  } do
    seed_trace(trace_dir, "seed")

    assert {:ok, backend, _features} =
             ViewerReplAdapter.connect(%{
               trace_dir: trace_dir,
               profile_id: "log-analysis-v2"
             })

    start_id = random_id()
    assert :ok = ViewerReplAdapter.prepare_operation(backend, nil, :start, start_id)
    assert {:ok, session, _info} = ViewerReplAdapter.start(backend, start_id, random_id())
    assert :ok = ViewerReplAdapter.acknowledge_operation(backend, :start, start_id)

    evaluation_id = random_id()
    assert :ok = ViewerReplAdapter.prepare_operation(backend, session, :evaluation, evaluation_id)

    %{sessions: %{^session => %{worker: worker}}} = :sys.get_state(backend.pid)
    true = :erlang.suspend_process(worker)

    evaluation =
      Task.async(fn ->
        ViewerReplAdapter.evaluate(backend, session, evaluation_id, "(loop [] (recur))")
      end)

    key = {:evaluation, evaluation_id}

    state =
      await_backend_state(backend.pid, fn state ->
        match?(%{status: :running}, state.operations[key])
      end)

    assert state.sessions[session].worker == worker
    worker_ref = Process.monitor(worker)
    send(backend.pid, {:operation_timeout, key})

    assert {:error, :adapter_failure} = Task.await(evaluation, 1_000)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 5_000
    assert :ok = ViewerReplAdapter.acknowledge_operation(backend, :evaluation, evaluation_id)

    assert {:error, :adapter_failure} =
             ViewerReplAdapter.prepare_operation(backend, session, :evaluation, random_id())
  end

  defp seed_trace(directory, run_id) do
    path = Path.join(directory, run_id <> ".jsonl")
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: run_id)
    :ok = EventSink.emit(sink, "run-started", %{})
    :ok = EventSink.emit(sink, "run-stopped", %{outcome: :ok, reason: nil})
    :ok = TraceLog.append_jsonl(path, EventSink.events(sink))
    EventSink.stop(sink)
  end

  defp random_id, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp await_backend_state(pid, predicate) do
    # The callback task can be starved briefly when the full 4k-test suite is
    # saturating schedulers; the backend operation itself remains bounded by
    # its independent 20-second watchdog.
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_await_backend_state(pid, predicate, deadline)
  end

  defp do_await_backend_state(pid, predicate, deadline) do
    state = :sys.get_state(pid)

    cond do
      predicate.(state) ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("backend did not reach the expected state")

      true ->
        receive do
        after
          1 -> do_await_backend_state(pid, predicate, deadline)
        end
    end
  end
end
