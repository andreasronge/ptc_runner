defmodule PtcRunner.Kernel.OwnerStatusPrivacyTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MCPRequestContext
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.RunState

  @logger_handler :owner_status_privacy_probe

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    :ok =
      :logger.add_handler(@logger_handler, PtcRunner.TestSupport.LoggerProbeHandler, %{
        level: :all,
        test_pid: self()
      })

    on_exit(fn ->
      :logger.remove_handler(@logger_handler)
      Logger.configure(level: previous_level)
    end)

    :ok
  end

  test "owner callback fallbacks reject unexpected messages without logging private data" do
    marker = "PRIVATE_FALLBACK_MARKER"
    owners = start_owners(marker)

    assert {:error, :closed} = GenServer.call(owners.store, {:unexpected, marker})
    assert {:error, :inspection_sink_error} = GenServer.call(owners.sink.pid, marker)
    assert {:error, :closed} = GenServer.call(owners.run_state.pid, marker)
    assert {:error, :closed} = GenServer.call(owners.mcp.pid, marker)

    assert {:error, :execution_session_unavailable} =
             GenServer.call(owners.execution, {:unexpected, marker})

    Enum.each(owner_pids(owners), &GenServer.cast(&1, {:unexpected, marker}))
    Enum.each(owner_pids(owners), &:sys.get_status/1)

    Logger.flush()

    refute_receive {:logger_probe, _event}
  end

  test "OTP status and every crash Logger event redact private owner state" do
    markers = %{
      store: "PRIVATE_INSPECTION_STORE_MARKER",
      sink: "PRIVATE_INSPECTION_RECORD_MARKER",
      run_state: "PRIVATE_EVALUATION_MEMORY_MARKER",
      endpoint: "PRIVATE_MCP_ENDPOINT_MARKER",
      header: "PRIVATE_MCP_HEADER_MARKER",
      execution: "PRIVATE_EXECUTION_INPUT_MARKER"
    }

    owners = start_owners(markers)

    Enum.each(owner_pids(owners), fn pid ->
      status = :sys.get_status(pid)

      Enum.each(Map.values(markers), fn marker ->
        refute inspect(status) =~ marker
      end)
    end)

    Enum.each(owner_pids(owners), fn pid ->
      ref = Process.monitor(pid)
      :ok = GenServer.stop(pid, :privacy_probe)
      assert_receive {:DOWN, ^ref, :process, ^pid, :privacy_probe}
    end)

    Logger.flush()
    events = drain_logger_events([])
    assert length(events) >= 4

    Enum.each(events, fn event ->
      encoded = inspect(event, limit: :infinity, printable_limit: :infinity)

      Enum.each(Map.values(markers), fn marker ->
        refute encoded =~ marker
      end)
    end)
  end

  defp start_owners(marker) when is_binary(marker) do
    start_owners(%{
      store: marker,
      sink: marker,
      run_state: marker,
      endpoint: marker,
      header: marker,
      execution: marker
    })
  end

  defp start_owners(markers) do
    {:ok, store} = PtcViewer.InspectionStore.start({:pinned, markers.store})
    {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    :ok =
      InspectionSink.emit(
        sink,
        "capability-input",
        %{capability_id: "cap-1"},
        %{environment: :mission, name: "read", arguments: %{"value" => markers.sink}}
      )

    {:ok, run_state} = RunState.start(Limits.defaults())
    {:ok, %{}, [], evaluation_lease} = RunState.reserve_evaluation(run_state)

    :ok =
      RunState.commit_evaluation(
        run_state,
        evaluation_lease,
        %{"value" => markers.run_state},
        [markers.run_state]
      )

    {:ok, mcp} =
      MCPRequestContext.start(
        owner: self(),
        endpoint: "https://example.com/#{markers.endpoint}",
        headers: [{"authorization", "Bearer #{markers.header}"}],
        timeout_ms: 50
      )

    {execution, execution_catalog} = start_execution_owner(markers.execution)

    owners = %{
      store: store,
      sink: sink,
      run_state: run_state,
      mcp: mcp,
      execution: execution,
      execution_catalog: execution_catalog
    }

    on_exit(fn ->
      Enum.each(owner_pids(owners), fn pid ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      end)

      InstallationCatalog.close(execution_catalog)
    end)

    owners
  end

  defp owner_pids(owners),
    do: [owners.store, owners.sink.pid, owners.run_state.pid, owners.mcp.pid, owners.execution]

  defp start_execution_owner(marker) do
    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{"private" => marker}}
    }

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [_input] (loop [] (recur)))"
    }

    {:ok, request} =
      ApplicationPackage.request_memory("ptc.json", documents, input_authority: :private)

    {:ok, catalog} = InstallationCatalog.new()
    {:ok, prepared} = RunCoordinator.prepare(request, catalog)
    {:ok, authority} = PublicationAuthority.new([])
    {:ok, owner} = ExecutionSessionOwner.start(prepared, authority, self())
    {ExecutionSessionOwner.pid(owner), catalog}
  end

  defp drain_logger_events(events) do
    receive do
      {:logger_probe, event} -> drain_logger_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
