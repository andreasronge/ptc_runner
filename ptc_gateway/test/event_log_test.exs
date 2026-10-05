defmodule PtcGateway.EventLogTest do
  use ExUnit.Case, async: false
  import PtcGateway.TestSupport.GatewayFixture
  alias PtcGateway.EventLog
  alias PtcRunner.TestSupport.Eventually
  import Bitwise

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  @tag :tmp_dir
  test "read-only startup, failure, queue overflow and retention preserve public health", %{
    tmp_dir: dir
  } do
    {path, config} = fixture(dir)
    config = with_events(path, config, %{"max_file_bytes" => 1024, "max_retained_files" => 2})
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{token()}\n")
    assert {:ok, gateway} = PtcGateway.start_link(path, env_file: env)
    on_exit(fn -> stop(gateway) end)
    logger = :sys.get_state(gateway).events
    handle = EventLog.handle(logger)
    :sys.suspend(logger)

    for _ <- 1..300,
        do: EventLog.emit(handle, %{kind: :startup_stage, stage: :templates, outcome: :ready})

    assert :atomics.get(elem(handle, 1), 1) == 256
    assert response(config, "/health/ready").body == %{"status" => "ready"}
    :sys.resume(logger)
    send(logger, :interval)

    Eventually.assert_eventually(fn ->
      Enum.any?(records(dir), &(&1["kind"] == "dropped_events"))
    end)

    stop(gateway)
    assert length(files(dir)) <= 2

    for file <- files(dir) do
      assert File.stat!(file).size <= 1024
      assert band(File.stat!(file).mode, 0o777) == 0o600
    end

    assert band(File.stat!(Path.join(dir, "artifacts/events")).mode, 0o777) == 0o700

    config =
      put_in(
        config,
        ["tools", Access.at(0), "expected_application_content_digest"],
        "sha256:" <> String.duplicate("0", 64)
      )

    File.write!(path, Jason.encode!(config))

    assert {:error, :application_content_digest_mismatch} =
             PtcGateway.start_link(path, env_file: env)

    assert Enum.any?(
             records(dir),
             &(&1["kind"] == "startup_failed" and
                 &1["code"] == "application_content_digest_mismatch" and
                 &1["reason_class"] == "application_content_digest_mismatch")
           )

    File.chmod!(Path.join(dir, "artifacts/events"), 0o755)
    assert {:error, :artifact_root_unavailable} = PtcGateway.start_link(path, env_file: env)
  end

  @tag :tmp_dir
  test "open failure drops records and recovers while readiness stays ready", %{tmp_dir: dir} do
    {path, config} = fixture(dir)
    config = with_events(path, config)
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{token()}\n")
    assert {:ok, gateway} = PtcGateway.start_link(path, env_file: env)
    on_exit(fn -> stop(gateway) end)
    logger = :sys.get_state(gateway).events
    handle = EventLog.handle(logger)
    EventLog.checkpoint(logger)

    :sys.replace_state(logger, fn s ->
      File.close(s.io)
      %{s | io: nil}
    end)

    directory = Path.join(dir, "artifacts/events")
    File.rename!(directory, directory <> "-held")
    EventLog.emit(handle, %{kind: :startup_stage, stage: :templates, outcome: :ready})
    EventLog.checkpoint(logger)
    assert response(config, "/health/ready").body == %{"status" => "ready"}
    File.rename!(directory <> "-held", directory)
    send(logger, :interval)
    EventLog.checkpoint(logger)
    assert Enum.any?(records(dir), &(&1["kind"] == "dropped_events"))
    # A real write refusal closes the failed file and reports the dropped
    # event in a later file; it never affects the warm readiness domain.
    :sys.replace_state(logger, fn state ->
      File.close(state.io)
      {:ok, io} = File.open(state.path, [:raw, :binary, :read])
      %{state | io: io}
    end)

    EventLog.emit(handle, %{kind: :startup_stage, stage: :templates, outcome: :ready})
    EventLog.checkpoint(logger)
    assert response(config, "/health/ready").body == %{"status" => "ready"}
    send(logger, :interval)
    EventLog.checkpoint(logger)
    assert Enum.sum(for r <- records(dir), r["kind"] == "dropped_events", do: r["count"]) >= 2
  end

  @tag :tmp_dir
  test "stderr is opt-in evidence on transport loss and shutdown", %{tmp_dir: dir} do
    script = Path.expand("../../test/support/mcp_stdio_source_fixture.sh", __DIR__)

    for stderr <- [false, true], loss <- [false, true] do
      subdir = Path.join(dir, "#{stderr}-#{loss}")
      File.mkdir_p!(subdir)
      wrapper = Path.join(subdir, "server.sh")
      secret = "SENTINEL_SECRET /private/sentinel-path"

      File.write!(
        wrapper,
        "#!/bin/sh\nprintf '%s\\n' '#{secret}' >&2\nexec /bin/sh '#{script}' \"$@\"\n"
      )

      transport = %{
        "type" => "stdio",
        "command" => "/bin/sh",
        "args" => [wrapper, Path.join(subdir, "marker")]
      }

      {path, config} = mcp_fixture(subdir, transport, upstream_tool: "structured")

      config =
        with_events(path, config, %{
          "max_file_bytes" => 65_536,
          "max_retained_files" => 10,
          "stderr" => stderr
        })

      assert {:ok, gateway} = PtcGateway.start_link(path)
      on_exit(fn -> stop(gateway) end)
      warm = :sys.get_state(gateway).warm
      runtime = :sys.get_state(warm).runtimes["a"]
      [handle] = :sys.get_state(runtime).opened.providers.mcp_transports

      if loss do
        Process.exit(handle.pid, :kill)
        Eventually.assert_eventually(fn -> response(config, "/health/ready").status == 503 end)

        Eventually.assert_eventually(fn ->
          Enum.any?(records(subdir), &(&1["kind"] == "transport"))
        end)

        assert Enum.any?(
                 records(subdir),
                 &(&1["kind"] == "readiness" and &1["tool"] == "a" and &1["provider"] == "remote")
               )
      end

      stop(gateway)
      logged = records(subdir)

      if stderr do
        assert Enum.any?(
                 logged,
                 &(&1["kind"] == "stderr_tail" and String.contains?(&1["text"], secret))
               )
      else
        refute Enum.any?(logged, &(&1["kind"] == "stderr_tail"))
      end

      ordinary = Jason.encode!(Enum.reject(logged, &(&1["kind"] == "stderr_tail")))
      refute String.contains?(ordinary, secret)
      refute String.contains?(ordinary, subdir)
    end
  end

  @tag :tmp_dir
  test "HTTP busy, detached and settlement timeout counters name the tool and provider", %{
    tmp_dir: dir
  } do
    alias PtcRunner.Kernel.{MCPRequestContext, ProviderRuntime}
    alias PtcRunner.TestSupport.WarmMCPFixture
    upstream = WarmMCPFixture.http()
    on_exit(upstream.close)

    {path, config} =
      mcp_fixture(dir, WarmMCPFixture.http_transport(upstream.endpoint),
        host_limits: %{"provider_cleanup_timeout_ms" => 100}
      )

    config = with_events(path, config)
    assert {:ok, gateway} = PtcGateway.start_link(path)
    on_exit(fn -> stop(gateway) end)
    warm = :sys.get_state(gateway).warm
    runtime = :sys.get_state(warm).runtimes["a"]
    {:ok, borrow} = ProviderRuntime.borrow(runtime, System.monotonic_time(:millisecond) + 5_000)
    [transport] = borrow.providers.mcp_transports
    transport = MCPRequestContext.with_borrow(transport, borrow.mcp_token)
    parent = self()

    callers =
      for _ <- 1..128 do
        spawn(fn ->
          result = MCPRequestContext.begin_request(transport)
          send(parent, {:admitted, self(), result})

          receive do
            :finish -> MCPRequestContext.finish_request(transport)
          end
        end)
      end

    on_exit(fn -> Enum.each(callers, &Process.exit(&1, :kill)) end)
    for _ <- callers, do: assert_receive({:admitted, _, {:ok, _}}, 5_000)
    assert {:error, :mcp_transport_busy} = MCPRequestContext.begin_request(transport)
    assert response(config, "/health/ready").body == %{"status" => "ready"}
    [dead | remaining] = callers
    ref = Process.monitor(dead)
    Process.exit(dead, :kill)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}
    Eventually.assert_eventually(fn -> map_size(:sys.get_state(transport.pid).active) == 127 end)
    # Return must settle the remaining admitted callers. Their held entries
    # deterministically exceed this test's explicit cleanup deadline.
    assert {:error, :provider_cleanup_failed} = ProviderRuntime.return(borrow)
    assert response(config, "/health/ready").body == %{"status" => "not_ready"}
    logger = :sys.get_state(gateway).events
    send(logger, :interval)
    EventLog.checkpoint(logger)

    for kind <- ["busy", "detached", "settlement_timeout"] do
      assert Enum.any?(
               records(dir),
               &(&1["kind"] == kind and &1["tool"] == "a" and &1["provider"] == "remote" and
                   &1["count"] > 0)
             )
    end

    Enum.each(remaining, &send(&1, :finish))
  end

  @tag :tmp_dir
  test "startup acquisition failure records the internal class behind the public code", %{
    tmp_dir: dir
  } do
    script = Path.expand("../../test/support/mcp_stdio_source_fixture.sh", __DIR__)
    wrapper = Path.join(dir, "server.sh")
    File.mkdir_p!(dir)
    File.write!(wrapper, "#!/bin/sh\nexec /bin/sh '#{script}' \"$@\"\n")

    transport = %{
      "type" => "stdio",
      "command" => "/bin/sh",
      "args" => [wrapper, Path.join(dir, "marker")]
    }

    {path, config} = mcp_fixture(dir, transport, upstream_tool: "structured")
    with_events(path, config)
    File.write!(wrapper, "#!/bin/sh\nprintf '%s\\n' 'malformed-upstream'\nexit 1\n")
    assert {:error, :internal_error} = PtcGateway.start_link(path)

    assert Enum.any?(
             records(dir),
             &(&1["kind"] == "startup_failed" and
                 &1["code"] == "internal_error" and &1["reason_class"] != "other")
           )
  end

  @tag :tmp_dir
  test "restart refuses retained files above a reduced file limit", %{tmp_dir: dir} do
    {path, config} = fixture(dir)
    config = with_events(path, config)
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{token()}\n")
    assert {:ok, gateway} = PtcGateway.start_link(path, env_file: env)
    logger = :sys.get_state(gateway).events
    handle = EventLog.handle(logger)

    for _ <- 1..20,
        do: EventLog.emit(handle, %{kind: :startup_stage, stage: :templates, outcome: :ready})

    EventLog.checkpoint(logger)
    stop(gateway)
    assert Enum.any?(files(dir), &(File.stat!(&1).size > 1024))
    with_events(path, config, %{"max_file_bytes" => 1024, "max_retained_files" => 2})
    assert {:error, :artifact_root_unavailable} = PtcGateway.start_link(path, env_file: env)
  end

  @tag :tmp_dir
  test "transport timeout records its failure class rather than its normal process exit", %{
    tmp_dir: dir
  } do
    script = Path.expand("../../test/support/mcp_stdio_source_fixture.sh", __DIR__)

    stderr = "EARLY_STDERR_SENTINEL " <> String.duplicate("x", 10_000)
    wrapper = Path.join(dir, "server.sh")

    File.write!(
      wrapper,
      "#!/bin/sh\nprintf '%s' '#{stderr}' >&2\nexec /bin/sh '#{script}' \"$@\"\n"
    )

    transport = %{
      "type" => "stdio",
      "command" => "/bin/sh",
      "args" => [wrapper, Path.join(dir, "marker")]
    }

    {path, config} = mcp_fixture(dir, transport, upstream_tool: "structured")

    config =
      with_events(path, config, %{
        "max_file_bytes" => 65_536,
        "max_retained_files" => 10,
        "stderr" => true
      })

    assert {:ok, gateway} = PtcGateway.start_link(path)
    on_exit(fn -> stop(gateway) end)
    runtime = :sys.get_state(:sys.get_state(gateway).warm).runtimes["a"]
    [handle] = :sys.get_state(runtime).opened.providers.mcp_transports

    Eventually.assert_eventually(fn ->
      PtcRunner.Kernel.MCPStdioTransport.cleanup_snapshot(handle)[:stderr] == stderr
    end)

    send(handle.pid, :close_timeout)

    Eventually.assert_eventually(fn ->
      Enum.any?(records(dir), &(&1["kind"] == "transport"))
    end)

    assert Enum.any?(records(dir), fn record ->
             record["kind"] == "transport" and record["fault"] == "close_timeout" and
               record["tool"] == "a" and record["provider"] == "remote"
           end)

    Eventually.assert_eventually(fn ->
      Enum.any?(records(dir), &(&1["kind"] == "stderr_tail"))
    end)

    assert Enum.any?(records(dir), fn record ->
             record["kind"] == "stderr_tail" and record["text"] == stderr and
               record["truncated"] == false
           end)

    assert response(config, "/health/ready").body == %{"status" => "not_ready"}
  end

  defp with_events(
         path,
         config,
         events \\ %{"max_file_bytes" => 65_536, "max_retained_files" => 10}
       ) do
    config = Map.put(config, "artifacts", %{"root" => "artifacts", "events" => events})
    File.write!(path, Jason.encode!(config))
    config
  end

  defp files(dir), do: Path.wildcard(Path.join(dir, "artifacts/events/*.jsonl"))

  defp records(dir) do
    for file <- files(dir),
        {:ok, bytes} <- [File.read(file)],
        line <- String.split(bytes, "\n", trim: true),
        {:ok, record} <- [Jason.decode(line)],
        do: record
  end
end
