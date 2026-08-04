defmodule PtcRunner.Kernel.RunCoordinatorExecutionTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunCoordinator

  test "provider-free execution returns sealed path-free publication evidence" do
    {prepared, catalog} = prepared_run("(return {\"answer\" 42})")
    assert {:ok, authority} = PublicationAuthority.new([])

    assert {:ok, outcome} = RunCoordinator.execute(prepared, authority)
    assert ExecutionOutcome.valid?(outcome)

    assert {:ok, %{value: %{"answer" => 42}}, :normal} =
             RunBuilder.publish_execution(outcome, authority)

    assert :ok = PreparedRun.close(prepared)
    assert :ok = InstallationCatalog.close(catalog)
  end

  test "invalid publication authority does not consume the prepared run" do
    {prepared, catalog} = prepared_run("(return 42)")
    assert {:ok, authority} = PublicationAuthority.new([])
    invalid = Map.put(authority, :output, "relative.json")

    assert {:error, :invalid_publication_authority} =
             RunCoordinator.execute(prepared, invalid)

    assert PreparedRun.valid?(prepared)
    assert :ok = PreparedRun.close(prepared)
    assert :ok = InstallationCatalog.close(catalog)
  end

  @tag :tmp_dir
  test "failed opening finalizes and stops both sinks from the execution owner", %{
    tmp_dir: directory
  } do
    {prepared, catalog} = oversized_metadata_prepared_run()
    inspection_path = Path.join(directory, "failed.inspection.jsonl")
    assert {:ok, authority} = PublicationAuthority.new(inspect: inspection_path)

    trace_calls([
      {EventSink, :start, 3},
      {EventSink, :finalize_and_events, 2},
      {EventSink, :stop, 1},
      {InspectionSink, :start, 1},
      {InspectionSink, :stop, 1}
    ])

    try do
      assert {:ok, owner} = ExecutionSessionOwner.start(prepared, authority, self())
      owner_pid = ExecutionSessionOwner.pid(owner)

      assert {:error, :run_started_metadata_exceeded} = ExecutionSessionOwner.await(owner)

      assert_receive {:trace, ^owner_pid, :call, {EventSink, :start, _arguments}}, 5_000

      assert_receive {:trace, ^owner_pid, :call, {InspectionSink, :start, _arguments}},
                     5_000

      assert_receive {:trace, ^owner_pid, :call,
                      {EventSink, :finalize_and_events,
                       [event_sink, %{outcome: :error, reason: :session_owner_failed}]}},
                     5_000

      assert_receive {:trace, ^owner_pid, :call, {InspectionSink, :stop, [inspection_sink]}},
                     5_000

      assert_receive {:trace, ^owner_pid, :call, {EventSink, :stop, [^event_sink]}}, 5_000

      refute Process.alive?(event_sink.pid)
      refute Process.alive?(inspection_sink.pid)
    after
      stop_trace_calls([
        {EventSink, :start, 3},
        {EventSink, :finalize_and_events, 2},
        {EventSink, :stop, 1},
        {InspectionSink, :start, 1},
        {InspectionSink, :stop, 1}
      ])
    end

    assert :ok = InstallationCatalog.close(catalog)
  end

  @tag :tmp_dir
  test "caller death aborts the worker and stops both owner-backed sinks", %{
    tmp_dir: directory
  } do
    {prepared, catalog} =
      prepared_run("(loop [] (recur))", inspection_capture: true)

    inspection_path = Path.join(directory, "run.inspection.jsonl")
    assert {:ok, authority} = PublicationAuthority.new(inspect: inspection_path)
    parent = self()

    caller =
      spawn(fn ->
        assert {:ok, owner} = ExecutionSessionOwner.start(prepared, authority, self())
        send(parent, {:execution_owner, owner})
        send(parent, {:execution_result, ExecutionSessionOwner.await(owner)})
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:execution_owner, owner}, 5_000
    owner_pid = ExecutionSessionOwner.pid(owner)
    state = :sys.get_state(owner_pid)
    event_sink = state.built.config.event_sink
    inspection_sink = state.built.config.inspection_sink

    assert {:ok, ^owner_pid} = EventSink.owner(event_sink)
    assert {:ok, ^owner_pid} = InspectionSink.owner(inspection_sink)
    assert_eventually(fn -> run_started?(event_sink) end)

    Code.ensure_loaded!(EventSink)
    assert :erlang.trace_pattern({EventSink, :finalize_and_events, 2}, true, [:local]) == 1
    assert :erlang.trace(owner_pid, true, [:call]) == 1

    owner_ref = Process.monitor(owner_pid)
    worker_ref = Process.monitor(state.worker_pid)
    event_sink_ref = Process.monitor(event_sink.pid)
    inspection_sink_ref = Process.monitor(inspection_sink.pid)
    activity_ref = Process.monitor(prepared.provider_activity.owner)

    try do
      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}

      assert_receive {:trace, ^owner_pid, :call,
                      {EventSink, :finalize_and_events,
                       [^event_sink, %{outcome: :error, reason: :session_owner_failed} = stopped]}}

      assert is_map(stopped.usage)
      assert_receive {:DOWN, ^worker_ref, :process, _worker, :killed}, 5_000
      assert_receive {:DOWN, ^inspection_sink_ref, :process, _pid, :normal}, 5_000
      assert_receive {:DOWN, ^event_sink_ref, :process, _pid, :normal}, 5_000
      assert_receive {:DOWN, ^activity_ref, :process, _pid, :normal}, 5_000
      assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}, 5_000
      refute_received {:execution_result, _result}
    after
      stop_trace(owner_pid)
      :erlang.trace_pattern({EventSink, :finalize_and_events, 2}, false, [:local])
    end

    assert :ok = InstallationCatalog.close(catalog)
  end

  defp prepared_run(body, opts \\ []) do
    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}}
    }

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [_input] #{body})"
    }

    request_opts = Keyword.merge([result_projection: :json], opts)
    assert {:ok, request} = ApplicationPackage.request_memory("ptc.json", documents, request_opts)
    assert {:ok, catalog} = InstallationCatalog.new()
    assert {:ok, prepared} = RunCoordinator.prepare(request, catalog)
    {prepared, catalog}
  end

  defp oversized_metadata_prepared_run do
    component_ids = Enum.map(1..96, &"component#{&1}")

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" =>
          [%{"id" => "app", "path" => "main.clj"}] ++
            Enum.map(component_ids, &%{"id" => &1, "path" => "#{&1}.clj"}),
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "limits" => %{"event_payload_bytes" => 5_000}
    }

    documents =
      Map.new(component_ids, &{"#{&1}.clj", "(ns #{&1})"})
      |> Map.put("ptc.json", Jason.encode!(manifest))
      |> Map.put("main.clj", "(ns app) (defn run [_input] (return 42))")

    assert {:ok, request} =
             ApplicationPackage.request_memory("ptc.json", documents, inspection_capture: true)

    assert {:ok, catalog} = InstallationCatalog.new()
    assert {:ok, prepared} = RunCoordinator.prepare(request, catalog)
    {prepared, catalog}
  end

  defp run_started?(sink), do: Enum.any?(EventSink.events(sink), &(&1.type == "run-started"))

  defp assert_eventually(callback, attempts \\ 1_000)

  defp assert_eventually(callback, attempts) when attempts > 0 do
    if callback.(), do: :ok, else: assert_eventually(callback, attempts - 1)
  end

  defp assert_eventually(_callback, 0), do: flunk("condition did not become true")

  defp stop_trace(pid) do
    :erlang.trace(pid, false, [:call])
  catch
    :error, :badarg -> false
  end

  defp trace_calls(patterns) do
    patterns
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.each(&Code.ensure_loaded!/1)

    assert :erlang.trace(:new_processes, true, [:call]) >= 0
    Enum.each(patterns, &assert(:erlang.trace_pattern(&1, true, [:local]) == 1))
  end

  defp stop_trace_calls(patterns) do
    :erlang.trace(:new_processes, false, [:call])
    Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local]))
  end
end
