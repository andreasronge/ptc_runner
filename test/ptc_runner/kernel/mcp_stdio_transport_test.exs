defmodule PtcRunner.Kernel.MCPStdioTransportTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.MCPStdioTransport

  @fixture Path.expand("../../support/mcp_stdio_fixture.exs", __DIR__)
  @stall_launcher Path.expand("../../support/mcp_stdio_stall_launcher.sh", __DIR__)
  @test_launcher Path.expand("../../support/mcp_stdio_test_launcher.exs", __DIR__)
  @root Path.expand("../../..", __DIR__)
  @inherited_environment ~w(HOME LOGNAME PATH SHELL TERM USER)

  @tag :tmp_dir
  test "correlates concurrent responses that arrive out of order", %{tmp_dir: tmp_dir} do
    transport = start_transport(tmp_dir)

    slow = Task.async(fn -> request(transport, "slow") end)
    fast = Task.async(fn -> request(transport, "fast") end)

    assert {:ok, %{"result" => %{"method" => "fast"}}} = Task.await(fast)
    assert {:ok, %{"result" => %{"method" => "slow"}}} = Task.await(slow)
    assert :ok = MCPStdioTransport.close(transport)
  end

  @tag :tmp_dir
  test "ignores valid server notifications while waiting for a response", %{tmp_dir: tmp_dir} do
    transport = start_transport(tmp_dir)

    assert {:ok, %{"result" => %{"method" => "notify"}}} = request(transport, "notify")
    assert :ok = MCPStdioTransport.close(transport)
  end

  @tag :tmp_dir
  test "charges notification frames against the response byte ceiling", %{tmp_dir: tmp_dir} do
    transport = start_transport(tmp_dir)
    unrelated = Task.async(fn -> request(transport, "slow", 128) end)

    assert_eventually(fn ->
      state = :sys.get_state(transport.pid)
      Enum.count(state.pending, fn {_id, pending} -> pending.sent? end) == 1
    end)

    assert {:error, :mcp_response_exceeded} =
             MCPStdioTransport.request(transport, "notify-flood", %{}, %{}, 128, 1_000)

    assert {:ok, %{"result" => %{"method" => "slow"}}} = Task.await(unrelated)

    assert {:ok, %{"result" => %{"method" => "after-notify-flood"}}} =
             request(transport, "after-notify-flood")

    assert :ok = MCPStdioTransport.close(transport)
  end

  @tag :tmp_dir
  test "rejects an individual response above its byte ceiling without closing", %{
    tmp_dir: tmp_dir
  } do
    transport = start_transport(tmp_dir)

    assert {:error, :mcp_response_exceeded} =
             MCPStdioTransport.request(transport, "large", %{}, %{}, 128, 1_000)

    assert {:ok, %{"result" => %{"method" => "small"}}} = request(transport, "small")
    assert :ok = MCPStdioTransport.close(transport)
  end

  @tag :tmp_dir
  test "accepts a response exactly at the transport byte ceiling", %{tmp_dir: tmp_dir} do
    transport = start_transport(tmp_dir)

    for method <- ["exact", "exact-crlf"] do
      assert {:ok, %{"result" => %{"method" => ^method}}} =
               MCPStdioTransport.request(
                 transport,
                 method,
                 %{},
                 %{},
                 1_048_576,
                 5_000
               )
    end

    assert :ok = MCPStdioTransport.close(transport)
  end

  @tag :tmp_dir
  test "malformed protocol stdout fails the transport closed", %{tmp_dir: tmp_dir} do
    transport = start_transport(tmp_dir)

    assert {:error, :mcp_protocol_error} =
             MCPStdioTransport.request(transport, "junk", %{}, %{}, 8_192, 5_000)

    assert {:error, :closed} = request(transport, "after-junk")
  end

  @tag :tmp_dir
  test "timeout during an unacknowledged write fails the wedged transport", %{tmp_dir: tmp_dir} do
    transport = start_transport(tmp_dir, nil, "no-read")
    ref = Process.monitor(transport.pid)

    assert {:error, :mcp_timeout} =
             MCPStdioTransport.request(
               transport,
               "blocked",
               %{"payload" => String.duplicate("x", 900_000)},
               %{},
               1_000_000,
               25
             )

    assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 5_000
    assert {:error, :closed} = request(transport, "after-timeout")
  end

  @tag :tmp_dir
  test "timeout sends a cancellation notification and leaves the transport usable", %{
    tmp_dir: tmp_dir
  } do
    marker = Path.join(tmp_dir, "cancelled")
    transport = start_transport(tmp_dir, marker)

    assert {:error, :mcp_timeout} =
             MCPStdioTransport.request(transport, "never", %{}, %{}, 8_192, 25)

    assert_eventually(fn ->
      case File.read(marker) do
        {:ok, contents} ->
          String.contains?(contents, ~s("method":"notifications/cancelled")) and
            String.contains?(contents, ~s("requestId":1))

        _missing ->
          false
      end
    end)

    assert {:ok, %{"result" => %{"method" => "after-timeout"}}} =
             request(transport, "after-timeout")

    assert :ok = MCPStdioTransport.close(transport)
  end

  @tag :tmp_dir
  test "fails closed when a cancellation write is not acknowledged", %{tmp_dir: tmp_dir} do
    transport = start_test_launcher(tmp_dir, "fake-cancel-ack")
    ref = Process.monitor(transport.pid)

    assert {:error, :mcp_timeout} =
             MCPStdioTransport.request(transport, "never", %{}, %{}, 8_192, 25)

    assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 5_000
    assert {:error, :closed} = request(transport, "after-cancellation-stall")
  end

  @tag :tmp_dir
  test "rejects a response for a queued request that was not transmitted", %{tmp_dir: tmp_dir} do
    transport = start_test_launcher(tmp_dir, "fake-premature-response")

    first =
      Task.async(fn ->
        MCPStdioTransport.request(transport, "first", %{}, %{}, 8_192, 5_000)
      end)

    assert_eventually(fn -> unacknowledged_request?(transport) end)

    second =
      Task.async(fn ->
        MCPStdioTransport.request(transport, "second", %{}, %{}, 8_192, 5_000)
      end)

    assert_eventually(fn ->
      match?(%{2 => %{sent?: false}}, :sys.get_state(transport.pid).pending)
    end)

    assert {:error, :mcp_protocol_error} = Task.await(first, 5_000)
    assert {:error, :mcp_protocol_error} = Task.await(second, 5_000)
  end

  @tag :tmp_dir
  test "caller death sends a cancellation notification", %{tmp_dir: tmp_dir} do
    marker = Path.join(tmp_dir, "cancelled")
    transport = start_transport(tmp_dir, marker)
    parent = self()

    caller =
      spawn(fn ->
        send(parent, :caller_started)
        MCPStdioTransport.request(transport, "never", %{}, %{}, 8_192, 5_000)
      end)

    assert_receive :caller_started

    assert_eventually(fn ->
      state = :sys.get_state(transport.pid)

      state.writing == nil and
        Enum.any?(state.pending, fn {_id, pending} -> pending.sent? end)
    end)

    Process.exit(caller, :kill)

    assert_eventually(fn ->
      case File.read(marker) do
        {:ok, contents} ->
          String.contains?(contents, ~s("method":"notifications/cancelled"))

        _missing ->
          false
      end
    end)

    assert :ok = MCPStdioTransport.close(transport)
  end

  @tag :tmp_dir
  test "owner death closes the transport", %{tmp_dir: tmp_dir} do
    parent = self()

    owner =
      spawn(fn ->
        transport = start_transport(tmp_dir)
        send(parent, {:transport, transport})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:transport, %MCPStdioTransport{pid: transport_pid}}, 5_000
    ref = Process.monitor(transport_pid)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^transport_pid, _reason}, 5_000
  end

  @tag :tmp_dir
  test "owner death discards an unacknowledged request", %{tmp_dir: tmp_dir} do
    marker = Path.join(tmp_dir, "delivered-bytes")
    parent = self()

    owner =
      spawn(fn ->
        transport = start_transport(tmp_dir, marker, "delayed-read")
        send(parent, {:transport, transport})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:transport, transport}, 5_000

    request =
      Task.async(fn ->
        blocked_request(transport)
      end)

    assert_eventually(fn -> unacknowledged_request?(transport) end)
    Process.exit(owner, :kill)
    assert {:error, :mcp_transport_error} = Task.await(request, 5_000)
    assert_partial_delivery(marker)
  end

  @tag :tmp_dir
  test "owner death aborts a launcher that is still starting", %{tmp_dir: tmp_dir} do
    existing = matching_ports(@stall_launcher)
    parent = self()

    owner =
      spawn(fn ->
        send(parent, :starting_transport)

        result =
          MCPStdioTransport.start(
            tmp_dir
            |> launch_options()
            |> Keyword.put(:launcher, @stall_launcher)
            |> Keyword.put(:start_timeout_ms, 60_000)
          )

        send(parent, {:start_result, result})
      end)

    assert_receive :starting_transport
    assert_eventually(fn -> matching_ports(@stall_launcher) -- existing != [] end)
    Process.exit(owner, :kill)
    assert_eventually(fn -> matching_ports(@stall_launcher) -- existing == [] end)
    refute_receive {:start_result, _result}
  end

  @tag :tmp_dir
  test "concurrent close calls are exact-once and idempotent to callers", %{tmp_dir: tmp_dir} do
    transport = start_transport(tmp_dir)

    closes =
      for _index <- 1..2 do
        Task.async(fn -> MCPStdioTransport.close(transport) end)
      end

    assert [:ok, :ok] = Enum.map(closes, &Task.await(&1, 5_000))
    assert :ok = MCPStdioTransport.close(transport)
  end

  @tag :tmp_dir
  test "close acknowledges and discards trailing server stdout", %{tmp_dir: tmp_dir} do
    marker = Path.join(tmp_dir, "request-received")
    transport = start_transport(tmp_dir, marker, "close-output")
    request = Task.async(fn -> request(transport, "wait-for-close") end)

    assert_eventually(fn -> File.exists?(marker) end)
    assert :ok = MCPStdioTransport.close(transport)
    assert {:error, :mcp_transport_error} = Task.await(request, 5_000)
  end

  @tag :tmp_dir
  test "explicit close discards an unacknowledged request", %{tmp_dir: tmp_dir} do
    marker = Path.join(tmp_dir, "delivered-bytes")
    transport = start_transport(tmp_dir, marker, "delayed-read")
    request = Task.async(fn -> blocked_request(transport) end)

    assert_eventually(fn -> unacknowledged_request?(transport) end)
    assert {:error, :mcp_transport_error} = MCPStdioTransport.close(transport)
    assert {:error, :mcp_transport_error} = Task.await(request, 5_000)
    assert_partial_delivery(marker)
  end

  @tag :tmp_dir
  test "does not report a launcher cleanup failure as a successful close", %{tmp_dir: tmp_dir} do
    transport = start_transport(tmp_dir)
    state = :sys.get_state(transport.pid)
    :sys.suspend(transport.pid)

    close = Task.async(fn -> MCPStdioTransport.close(transport) end)

    receive do
    after
      10 -> :ok
    end

    send(
      transport.pid,
      {state.port, {:data, <<"X", 5, 0::signed-big-32, 0>>}}
    )

    :sys.resume(transport.pid)
    assert {:error, :mcp_transport_error} = Task.await(close, 5_000)
  end

  @tag :tmp_dir
  test "preserves a cleanup failure observed before close", %{tmp_dir: tmp_dir} do
    transport = start_transport(tmp_dir)
    state = :sys.get_state(transport.pid)
    ref = Process.monitor(transport.pid)

    send(transport.pid, {state.port, {:data, <<"X", 5, 0::signed-big-32, 0>>}})

    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
    assert {:error, :mcp_transport_error} = MCPStdioTransport.close(transport)
  end

  @tag :tmp_dir
  test "waits for a delayed clean finish after port exit", %{tmp_dir: tmp_dir} do
    transport = start_transport(tmp_dir)
    state = :sys.get_state(transport.pid)
    :sys.suspend(transport.pid)
    close = Task.async(fn -> MCPStdioTransport.close(transport) end)

    receive do
    after
      10 -> :ok
    end

    send(transport.pid, {state.port, {:exit_status, 0}})
    second_close = Task.async(fn -> MCPStdioTransport.close(transport) end)

    Task.start(fn ->
      receive do
      after
        25 ->
          send(transport.pid, {state.port, {:data, <<"X", 1, 0::signed-big-32, 0>>}})
      end
    end)

    :sys.resume(transport.pid)
    assert :ok = Task.await(close, 5_000)
    assert :ok = Task.await(second_close, 5_000)
  end

  @tag :tmp_dir
  test "close waits for a clean finish already draining after port exit", %{tmp_dir: tmp_dir} do
    transport = start_transport(tmp_dir)
    state = :sys.get_state(transport.pid)
    send(transport.pid, {state.port, {:exit_status, 0}})
    assert_eventually(fn -> :sys.get_state(transport.pid).terminal_pending? end)

    close = Task.async(fn -> MCPStdioTransport.close(transport) end)

    assert_eventually(fn ->
      :sys.get_state(transport.pid).closing |> is_list()
    end)

    send(transport.pid, {state.port, {:data, <<"X", 1, 0::signed-big-32, 0>>}})

    assert :ok = Task.await(close, 5_000)
  end

  @tag :tmp_dir
  test "fails active and new requests while draining terminal status", %{tmp_dir: tmp_dir} do
    transport = start_transport(tmp_dir)

    active =
      Task.async(fn ->
        MCPStdioTransport.request(transport, "never", %{}, %{}, 8_192, 5_000)
      end)

    assert_eventually(fn ->
      state = :sys.get_state(transport.pid)
      state.writing == nil and map_size(state.pending) == 1
    end)

    state = :sys.get_state(transport.pid)
    send(transport.pid, {state.port, {:exit_status, 0}})
    assert_eventually(fn -> :sys.get_state(transport.pid).terminal_pending? end)

    assert {:error, :mcp_transport_error} = Task.await(active, 5_000)
    assert {:error, :mcp_transport_error} = request(transport, "after-exit")
  end

  @tag :tmp_dir
  test "rejects a launcher protocol mismatch before spawning", %{tmp_dir: tmp_dir} do
    assert {:error, :invalid_mcp_stdio_launch} =
             MCPStdioTransport.start(
               Keyword.put(launch_options(tmp_dir), :launcher_protocol_version, 2)
             )
  end

  @tag :tmp_dir
  test "status does not expose process arguments or environment values", %{tmp_dir: tmp_dir} do
    options =
      tmp_dir
      |> launch_options()
      |> Keyword.update!(:args, &(&1 ++ ["private-argument"]))
      |> Keyword.update!(:env, &Map.put(&1, "PRIVATE_VALUE", "private-environment"))

    assert {:ok, %MCPStdioTransport{pid: pid} = transport} = MCPStdioTransport.start(options)

    status = pid |> :sys.get_status() |> inspect()
    refute status =~ "private-argument"
    refute status =~ "private-environment"
    assert :ok = MCPStdioTransport.close(transport)
  end

  defp request(transport, method, max_bytes \\ 8_192),
    do: MCPStdioTransport.request(transport, method, %{}, %{}, max_bytes, 1_000)

  defp blocked_request(transport) do
    MCPStdioTransport.request(
      transport,
      "blocked",
      %{"payload" => String.duplicate("x", 900_000)},
      %{},
      1_000_000,
      5_000
    )
  end

  defp unacknowledged_request?(transport) do
    match?(%{request_id: id} when is_integer(id), :sys.get_state(transport.pid).writing)
  end

  defp assert_partial_delivery(marker) do
    receive do
    after
      500 -> :ok
    end

    case File.read(marker) do
      {:ok, bytes} -> assert String.to_integer(bytes) < 900_000
      {:error, :enoent} -> :ok
    end
  end

  defp start_transport(tmp_dir, marker \\ nil, fixture_mode \\ "read") do
    marker = marker || Path.join(tmp_dir, "unused")

    assert {:ok, transport} =
             MCPStdioTransport.start(launch_options(tmp_dir, marker, fixture_mode))

    transport
  end

  defp launch_options(tmp_dir, marker \\ nil, fixture_mode \\ "read") do
    marker = marker || Path.join(tmp_dir, "unused")
    {:ok, launcher} = PtcRunnerLauncher.executable_path()
    executable = System.find_executable("elixir")

    [
      launcher: launcher,
      launcher_protocol_version: PtcRunnerLauncher.protocol_version(),
      executable: executable,
      executable_sha256: executable |> File.read!() |> then(&:crypto.hash(:sha256, &1)),
      cwd: @root,
      args: [@fixture, marker, fixture_mode],
      env: inherited_environment(),
      grace_ms: 50,
      start_timeout_ms: 5_000
    ]
  end

  defp start_test_launcher(tmp_dir, mode) do
    launcher = Path.join(tmp_dir, "mcp-stdio-test-launcher")
    interpreter = System.find_executable("elixir")

    File.write!(launcher, [
      "#!/bin/sh\nPATH=",
      shell_quote(System.fetch_env!("PATH")),
      " exec ",
      shell_quote(interpreter),
      " ",
      shell_quote(@test_launcher),
      "\n"
    ])

    File.chmod!(launcher, 0o700)

    options =
      tmp_dir
      |> launch_options()
      |> Keyword.put(:launcher, launcher)
      |> Keyword.put(:args, [mode])

    assert {:ok, transport} = MCPStdioTransport.start(options)
    transport
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp inherited_environment do
    @inherited_environment
    |> Enum.flat_map(fn name ->
      case System.get_env(name) do
        value when is_binary(value) -> [{name, value}]
        _missing -> []
      end
    end)
    |> Map.new()
  end

  defp matching_ports(executable) do
    Enum.filter(Port.list(), fn port ->
      case Port.info(port, :name) do
        {:name, name} -> List.to_string(name) == executable
        _closed -> false
      end
    end)
  end

  defp assert_eventually(predicate, attempts \\ 300)

  defp assert_eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      receive do
      after
        10 -> assert_eventually(predicate, attempts - 1)
      end
    end
  end

  defp assert_eventually(_predicate, 0), do: flunk("condition did not become true")
end
