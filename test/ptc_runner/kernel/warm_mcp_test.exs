defmodule PtcRunner.Kernel.WarmMCPTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias PtcRunner.Kernel.{MCPRequestContext, ProviderRuntime}
  alias PtcRunner.TestSupport.{Eventually, MCPTLSProxy, WarmMCPFixture}

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  @tag :tmp_dir
  test "MCP acquisition is warm and serves distinct concurrent borrows", %{tmp_dir: dir} do
    server = WarmMCPFixture.http()
    on_exit(server.close)
    tls = MCPTLSProxy.start(dir, server.endpoint)
    on_exit(tls.close)

    transport = %{
      "type" => "streamable_http",
      "endpoint" => tls.endpoint,
      "auth" => [%{"scheme" => "api_key", "binding" => "upstream", "header" => "X-Key"}]
    }

    {template, services} = WarmMCPFixture.application(dir, transport)

    output =
      capture_io(fn ->
        assert {:ok, runtime} =
                 ProviderRuntime.start_link(
                   template: template,
                   services: services,
                   pins: :discover
                 )

        GenServer.stop(runtime)
      end)

    pins = Jason.decode!(output)

    assert {:ok, runtime} =
             ProviderRuntime.start_link(
               template: template,
               services: services,
               pins: %{
                 installation_config_pins: pins["installation_config_pins"],
                 provider_snapshot_pins: pins["provider_snapshot_pins"]
               }
             )

    on_exit(fn -> if Process.alive?(runtime), do: GenServer.stop(runtime) end)

    tasks =
      for query <- ["one", "two"] do
        Task.async(fn ->
          {:ok, borrow} =
            ProviderRuntime.borrow(runtime, System.monotonic_time(:millisecond) + 10_000)

          [capability] = borrow.providers.mission.capabilities

          result =
            capability.callback.(%{"query" => query}, %{
              inspection_sink: nil,
              traceparent: nil,
              capability_id: "remote.echo"
            })

          assert :ok = ProviderRuntime.return(borrow)
          result
        end)
      end

    assert Enum.map(tasks, &Task.await/1) == [
             {:ok, %{"text" => ["one"]}},
             {:ok, %{"text" => ["two"]}}
           ]

    assert_receive {:upstream, "tools/call", %{"x-key" => "fixture-key"}}
    assert ProviderRuntime.status(runtime) == :ready
    assert :ok = ProviderRuntime.drain(runtime, System.monotonic_time(:millisecond) + 10_000)
  end

  @tag :tmp_dir
  test "HTTP owner loss fences readiness but a request failure does not", %{tmp_dir: dir} do
    {runtime, _template, server} = runtime(dir)
    {:ok, borrow} = ProviderRuntime.borrow(runtime, deadline())
    [handle] = borrow.providers.mcp_transports
    # A connection refusal is local to this request, while the acquired owner stays live.
    [capability] = borrow.providers.mission.capabilities
    assert {:ok, _} = capability.callback.(%{"query" => "healthy"}, context())
    server.close.()
    assert {:error, _} = capability.callback.(%{"query" => "disconnected"}, context())
    assert :ok = ProviderRuntime.return(borrow)
    assert ProviderRuntime.status(runtime) == :ready
    ref = Process.monitor(handle.pid)
    Process.exit(handle.pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}

    Eventually.assert_eventually(fn ->
      ProviderRuntime.status(runtime) == {:not_ready, :provider_runtime_lost}
    end)

    assert {:error, :provider_runtime_unavailable} = ProviderRuntime.borrow(runtime, deadline())
  end

  @tag :tmp_dir
  test "execution owner death holds a detached HTTP borrow until worker DOWN", %{tmp_dir: dir} do
    {runtime, _, _} = runtime(dir)
    {borrow, handle, owner, worker} = detached(runtime)
    Process.exit(owner, :kill)
    assert_receive {:worker_cancelled, ^worker}

    Eventually.assert_eventually(fn ->
      match?(%{settling: {_pid, _ref}}, :sys.get_state(runtime).borrows[borrow.monitor])
    end)

    assert map_size(:sys.get_state(runtime).borrows) == 1
    assert {:error, :closed} = MCPRequestContext.begin_request(handle)
    draining = Task.async(fn -> ProviderRuntime.drain(runtime, deadline()) end)
    assert Task.yield(draining, 0) == nil
    send(worker, :settle)
    assert :ok = Task.await(draining)
    refute Process.alive?(handle.pid)
  end

  @tag :tmp_dir
  test "settlement expiry fences and retains the borrow through forced drain", %{tmp_dir: dir} do
    {runtime, _, _} = runtime(dir, host_limits: %{"provider_cleanup_timeout_ms" => 100})
    {borrow, handle, owner, worker} = detached(runtime)
    Process.exit(owner, :kill)
    assert_receive {:worker_cancelled, ^worker}

    Eventually.assert_eventually(fn ->
      ProviderRuntime.status(runtime) == {:not_ready, :provider_cleanup_failed}
    end)

    assert map_size(:sys.get_state(runtime).borrows) == 1
    assert :sys.get_state(runtime).borrows[borrow.monitor].settling == :failed
    send(worker, :settle)
    # Expired settlement is not retroactively accepted; the count is kept until close.
    assert {:error, {:outstanding_borrows, 1}} =
             ProviderRuntime.drain(runtime, System.monotonic_time(:millisecond))

    refute Process.alive?(handle.pid)
  end

  @tag :tmp_dir
  test "drain cutoff closes an acquisition with detached work still outstanding", %{tmp_dir: dir} do
    {runtime, _, _} = runtime(dir, host_limits: %{"provider_cleanup_timeout_ms" => 100})
    {_borrow, handle, owner, worker} = detached(runtime)
    Process.exit(owner, :kill)
    assert_receive {:worker_cancelled, ^worker}
    assert {:error, _} = ProviderRuntime.drain(runtime, System.monotonic_time(:millisecond))
    refute Process.alive?(handle.pid)
    send(worker, :settle)
  end

  defp detached(runtime) do
    parent = self()
    {:ok, borrow} = ProviderRuntime.borrow(runtime, deadline())
    [handle] = borrow.providers.mcp_transports
    handle = MCPRequestContext.with_borrow(handle, borrow.mcp_token)

    worker =
      spawn(fn ->
        receive do
          :mcp_cancel -> send(parent, {:worker_cancelled, self()})
        end

        receive do: (:settle -> :ok)
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)

    owner =
      spawn(fn ->
        :ok = ProviderRuntime.hold_borrow(borrow)
        {:ok, request} = MCPRequestContext.begin_request(handle)
        :ok = MCPRequestContext.register_worker(handle, request.id, worker)
        send(parent, {:detached, self()})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:detached, ^owner}
    {borrow, handle, owner, worker}
  end

  defp runtime(dir, opts \\ []) do
    server = WarmMCPFixture.http()
    on_exit(server.close)

    {template, services} =
      WarmMCPFixture.application(dir, WarmMCPFixture.http_transport(server.endpoint), opts)

    output =
      capture_io(fn ->
        {:ok, discovery} =
          ProviderRuntime.start_link(template: template, services: services, pins: :discover)

        GenServer.stop(discovery)
      end)

    pins = Jason.decode!(output)

    {:ok, runtime} =
      ProviderRuntime.start_link(
        template: template,
        services: services,
        pins: %{
          installation_config_pins: pins["installation_config_pins"],
          provider_snapshot_pins: pins["provider_snapshot_pins"]
        }
      )

    on_exit(fn -> if Process.alive?(runtime), do: GenServer.stop(runtime) end)
    {runtime, template, server}
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 10_000
  defp context, do: %{inspection_sink: nil, traceparent: nil, capability_id: "remote.echo"}
end
