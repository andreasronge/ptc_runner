ExUnit.start(exclude: [:sustained_tls])
Logger.configure(level: :critical)

defmodule PtcRunner.Labs.ComparisonTest do
  use ExUnit.Case, async: false
  alias PtcRunner.Labs.{HttpAdapter, WorkflowProbe}
  alias PtcRunner.Kernel.RunAdmission
  alias PtcRunner.LLM.{Invocation, ReqLLMAdapter, Requirements}
  alias PtcRunner.TestSupport.MCPHTTPFixture
  import PtcRunner.TestSupport.Eventually

  @source_identity (if System.get_env("PTC_PILOT_REPORT") ||
                         System.get_env("PTC_PILOT_SUSTAINED_REPORT") do
                      %{
                        runner: PtcRunner.Labs.TransportPreflight.clean_source!("."),
                        transport:
                          PtcRunner.Labs.TransportPreflight.clean_source!(
                            System.fetch_env!("PTC_LLM_HTTP_PATH")
                          )
                      }
                    else
                      %{runner: nil, transport: nil}
                    end)

  setup context do
    owner = self()
    ambient_trust = system_trust()
    start_supervised!({PtcRunner.Labs.RequestAdmission, 4})

    responder =
      start_supervised!(
        {Agent,
         fn ->
           fn request -> json(WorkflowProbe.response(request)) end
         end}
      )

    handler = fn request ->
      send(owner, {:wire, request.body})
      send(owner, {:provider_auth, request.headers["authorization"]})

      Agent.get(responder, & &1).(request.body)
    end

    Application.put_env(:req_llm, :load_dotenv, false)
    Application.put_env(:llm_db, :load_dotenv, false)

    {endpoint, policy, connection_opts, persistent_fixture} =
      cond do
        context[:persistent_tls] ->
          {:ok, _} = Application.ensure_all_started(:ssl)
          config = PtcRunner.TestSupport.TLSFixture.configuration()
          fixture = PtcRunner.Labs.PersistentTLSFixture.start(handler, config.server)
          on_exit(fixture.close)
          install_trust(context.tmp_dir, ambient_trust, config.trust)

          {fixture.endpoint, {:allow_cidrs, ["127.0.0.0/8", "::1/128"]},
           [transport_opts: [cacerts: config.trust]], fixture}

        context[:installed_host] ->
          fixture = MCPHTTPFixture.start(handler)
          on_exit(fixture.close)
          {:ok, _} = Application.ensure_all_started(:ssl)
          config = PtcRunner.TestSupport.TLSFixture.configuration()
          proxy = PtcRunner.Labs.TLSProxy.start(fixture.endpoint, config.server)
          on_exit(proxy.close)
          install_trust(context.tmp_dir, ambient_trust, config.trust)

          {proxy.endpoint, {:allow_cidrs, ["127.0.0.0/8", "::1/128"]},
           [transport_opts: [cacerts: config.trust]], nil}

        true ->
          fixture = MCPHTTPFixture.start(handler)
          on_exit(fixture.close)
          {fixture.endpoint, :literal_loopback, [], nil}
      end

    Application.put_env(:req_llm, :openrouter, base_url: endpoint)

    Application.put_env(:req_llm, :finch,
      pools: %{default: [count: 1, size: 2, protocols: [:http1], conn_opts: connection_opts]}
    )

    Application.put_env(:ptc_runner, :pilot_http_endpoint, {endpoint, policy})
    {:ok, _} = Application.ensure_all_started(:req_llm)

    runtime =
      start_supervised!(%{
        id: HttpAdapter,
        type: :supervisor,
        restart: :temporary,
        start: {HttpAdapter, :start_runtime, [[max_concurrency: 2, groups: %{"openrouter" => 2}]]}
      })

    previous_adapter = Application.fetch_env!(:ptc_runner, :llm_adapter)

    on_exit(fn ->
      Application.put_env(:ptc_runner, :llm_adapter, previous_adapter)
      Application.stop(:req_llm)
      Application.stop(:llm_db)
    end)

    %{
      runtime: runtime,
      responder: responder,
      ambient_trust: ambient_trust,
      persistent_fixture: persistent_fixture
    }
  end

  @tag persistent_tls: true
  @tag :sustained_tls
  @tag :tmp_dir
  @tag timeout: 700_000
  test "sustained TLS comparison records physical connection reuse", %{
    persistent_fixture: fixture
  } do
    criteria = %{
      concurrency: 2,
      minimum_workflows: 200,
      duration_ms: sustained_duration_ms(),
      maximum_error_rate: 0.0,
      maximum_connections_per_concurrency: 1,
      minimum_requests_per_connection: 20
    }

    observations =
      for adapter <- [ReqLLMAdapter, HttpAdapter] do
        assert {:ok, _} = WorkflowProbe.run(adapter, requirements())
        drain_wire()
        before_stats = fixture.snapshot.()
        before_resources = resources()
        started = System.monotonic_time(:millisecond)

        {latencies, failures, workflows} =
          sustained_workflows(adapter, criteria.minimum_workflows, criteria.duration_ms, started)

        duration_ms = System.monotonic_time(:millisecond) - started
        requests = drain_wire()
        after_stats = fixture.snapshot.()
        stats = subtract_stats(after_stats, before_stats)

        assert failures == 0
        assert workflows >= criteria.minimum_workflows
        assert requests == workflows * 2
        assert stats.requests == requests
        assert stats.accepted_connections == stats.successful_handshakes

        requests_per_connection = requests / max(stats.connections_used, 1)

        accepted? =
          stats.connections_observed <=
            criteria.concurrency * criteria.maximum_connections_per_concurrency and
            requests_per_connection >= criteria.minimum_requests_per_connection

        %{
          adapter: inspect(adapter),
          accepted: accepted?,
          workflows: workflows,
          requests: requests,
          failures: failures,
          duration_ms: duration_ms,
          workflows_per_second: workflows * 1_000 / max(duration_ms, 1),
          latency_ms: percentiles(latencies),
          connections_used: stats.connections_used,
          connections_observed: stats.connections_observed,
          new_connections: stats.new_connections,
          accepted_connections: stats.accepted_connections,
          successful_handshakes: stats.successful_handshakes,
          requests_per_connection: requests_per_connection,
          resources: %{before: before_resources, after: resources()}
        }
      end

    req_llm = Enum.find(observations, &String.ends_with?(&1.adapter, "ReqLLMAdapter"))
    http = Enum.find(observations, &String.ends_with?(&1.adapter, "HttpAdapter"))

    assert req_llm.accepted

    conclusion =
      cond do
        http.accepted ->
          "Both transports meet the fixed TLS connection-reuse envelope; compare their operational evidence before choosing."

        true ->
          "Keep configured ReqLLM/Finch for the gateway: it meets the fixed TLS connection-reuse envelope and the experimental transport does not."
      end

    if path = System.get_env("PTC_PILOT_SUSTAINED_REPORT") do
      PtcRunner.Labs.TransportPreflight.verify_source!(".", @source_identity.runner)

      PtcRunner.Labs.TransportPreflight.verify_source!(
        System.fetch_env!("PTC_LLM_HTTP_PATH"),
        @source_identity.transport
      )

      report = %{
        captured_at: DateTime.to_iso8601(DateTime.utc_now()),
        source: @source_identity,
        criteria: criteria,
        observations: observations,
        conclusion: conclusion
      }

      File.write!(path, Jason.encode!(report, pretty: true) <> "\n")
    end
  end

  test "both adapters execute concurrent support-triage workflows with tool round trips" do
    for adapter <- [ReqLLMAdapter, HttpAdapter] do
      outcomes =
        Task.async_stream(1..2, fn _ -> WorkflowProbe.run(adapter, requirements()) end,
          max_concurrency: 2,
          timeout: 30_000
        )
        |> Enum.to_list()

      for outcome <- outcomes do
        assert {:ok, {:ok, result}} = outcome
        assert %{"ok" => true, "value" => ["T-1001", "T-1004"]} = result.value
      end

      assert_received {:wire, %{"tools" => [%{"function" => %{"name" => "run_ptc_lisp"}}]}}
      assert_received {:wire, %{"messages" => messages}}
      assert is_list(messages)
    end
  end

  test "pilot rejects unsupported exact controls during preparation" do
    for options <- [%{max_tokens: 64, top_p: 0.5}, %{max_tokens: 64, reasoning_effort: :high}] do
      assert {:error, :unsupported_model_option} =
               HttpAdapter.prepare_model(
                 "openrouter:deepseek/deepseek-v4-flash",
                 Requirements.interim(options)
               )
    end

    refute_received {:wire, _}
  end

  test "pilot deadline and unsupported cache refuse before wire dispatch" do
    {:ok, target, _, _} =
      HttpAdapter.prepare_model("openrouter:deepseek/deepseek-v4-flash", requirements())

    {:ok, invocation} =
      Invocation.new(
        %{messages: [%{role: :user, content: "hello"}]},
        false,
        nil,
        System.monotonic_time(:millisecond) - 1
      )

    assert {:error, %{kind: :timeout, dispatch_provenance: :not_dispatched}} =
             HttpAdapter.call(target, invocation)

    assert {:error, %{kind: :invalid_request, dispatch_provenance: :not_dispatched}} =
             HttpAdapter.call(target, %{invocation | cache: true})

    refute_received {:wire, _}
  end

  test "exact cache accounting and length attribution survive the adapter", %{
    responder: responder
  } do
    Agent.update(responder, fn _ -> fn _ -> json(text_response("length")) end end)

    {:ok, target, _, _} =
      HttpAdapter.prepare_model("openrouter:deepseek/deepseek-v4-flash", requirements())

    assert {:ok,
            %{
              finish_reason: :length,
              output_limit: %{value: 4096, bindings: [:configured]},
              tokens: %{
                input: 100,
                output: 20,
                cache_read: 10,
                cache_creation: 5,
                total_cost: "0.0000051"
              }
            }} =
             HttpAdapter.call(target, invocation())
  end

  test "required usage cannot be replaced by an estimate", %{responder: responder} do
    Agent.update(responder, fn _ ->
      fn _ -> json(Map.delete(text_response("stop"), :usage)) end
    end)

    {:ok, target, _, _} =
      HttpAdapter.prepare_model("openrouter:deepseek/deepseek-v4-flash", requirements())

    assert {:error, %{retryable?: false}} = HttpAdapter.call(target, invocation())
  end

  test "structured output returns an object through the current boundary", %{responder: responder} do
    response =
      put_in(text_response("stop"), [:choices, Access.at(0), :message, :content], ~s({"ok":true}))

    Agent.update(responder, fn _ -> fn _ -> json(response) end end)

    {:ok, target, _, _} =
      HttpAdapter.prepare_model(
        "openrouter:deepseek/deepseek-v4-flash",
        %{requirements() | structured_output_mode: :json_schema}
      )

    invocation = invocation()

    schema = %{
      "type" => "object",
      "properties" => %{"ok" => %{"type" => "boolean"}},
      "required" => ["ok"],
      "additionalProperties" => false
    }

    assert {:ok, %{object: %{"ok" => true}}} =
             HttpAdapter.call(target, %{
               invocation
               | request: Map.put(invocation.request, :schema, schema)
             })
  end

  test "shared physical capacity rejects before dispatch and drains on caller death", %{
    responder: responder,
    runtime: runtime
  } do
    hold_responses(responder)

    {:ok, target, _, _} =
      HttpAdapter.prepare_model("openrouter:deepseek/deepseek-v4-flash", requirements())

    callers = for _ <- 1..2, do: spawn_monitor(fn -> HttpAdapter.call(target, invocation()) end)
    for _ <- 1..2, do: assert_receive({:holding, _}, 5_000)
    assert {:ok, %{in_use: 2}} = PtcLlmHttp.Runtime.snapshot(runtime)

    assert {:error, %{kind: :unavailable, dispatch_provenance: :not_dispatched}} =
             HttpAdapter.call(target, invocation())

    for {pid, ref} <- callers do
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
      assert_receive :socket_closed, 5_000
    end

    Agent.update(responder, fn _ -> fn _ -> json(text_response("stop")) end end)
    assert_eventually(fn -> match?({:ok, %{in_use: 0}}, PtcLlmHttp.Runtime.snapshot(runtime)) end)
    assert {:ok, _} = HttpAdapter.call(target, invocation())
    assert {:ok, %{in_use: 0}} = PtcLlmHttp.Runtime.snapshot(runtime)
  end

  test "killing a complete workflow owner drains the shared HTTP attempt", %{
    responder: responder,
    runtime: runtime
  } do
    hold_responses(responder)
    {caller, ref} = spawn_monitor(fn -> WorkflowProbe.run(HttpAdapter, requirements()) end)
    assert_receive {:holding, _}, 5_000
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, _}, 5_000
    assert_receive :socket_closed, 5_000
    assert_eventually(fn -> match?({:ok, %{in_use: 0}}, PtcLlmHttp.Runtime.snapshot(runtime)) end)
  end

  test "runtime owner failure closes active sockets and refuses further calls", %{
    responder: responder,
    runtime: runtime
  } do
    hold_responses(responder)

    {:ok, target, _, _} =
      HttpAdapter.prepare_model("openrouter:deepseek/deepseek-v4-flash", requirements())

    task = Task.async(fn -> HttpAdapter.call(target, invocation()) end)
    assert_receive {:holding, _}, 5_000
    ref = Process.monitor(runtime)
    Process.exit(runtime, :kill)
    assert_receive {:DOWN, ^ref, :process, ^runtime, :killed}, 5_000
    assert_receive :socket_closed, 5_000
    assert {:error, _} = Task.await(task, 5_000)

    assert {:error, %{dispatch_provenance: :not_dispatched}} =
             HttpAdapter.call(target, invocation())
  end

  test "active-response deadline releases capacity", %{responder: responder, runtime: runtime} do
    hold_responses(responder)

    {:ok, target, _, _} =
      HttpAdapter.prepare_model("openrouter:deepseek/deepseek-v4-flash", requirements())

    invocation = %{
      invocation()
      | llm_request_deadline_ms: System.monotonic_time(:millisecond) + 250
    }

    task = Task.async(fn -> HttpAdapter.call(target, invocation) end)
    assert_receive {:holding, _}, 5_000
    assert {:error, %{kind: :timeout}} = Task.await(task, 5_000)
    assert_receive :socket_closed, 5_000
    assert {:ok, %{in_use: 0}} = PtcLlmHttp.Runtime.snapshot(runtime)
  end

  test "both adapters settle exact fractional costs at the Kernel boundary", %{
    responder: responder
  } do
    Agent.update(responder, fn _ -> fn _ -> json(text_response("stop")) end end)

    for adapter <- [ReqLLMAdapter, HttpAdapter] do
      {:ok, target, _, _} =
        adapter.prepare_model("openrouter:deepseek/deepseek-v4-flash", requirements())

      result = PtcRunner.Labs.LLMTransportBaseline.dispatch(target, "accounting", 5_000, adapter)
      assert result.result.status == :ok
      assert result.ledger["total_tokens"]["charged"] == 120
      assert result.ledger["cost"]["charged_microusd"] == 6
      assert result.ledger["cost"]["reserved_microusd"] == 0
    end
  end

  test "missing usage conservatively charges reservations and zero remains a valid observation",
       %{responder: responder} do
    {:ok, target, _, _} =
      HttpAdapter.prepare_model("openrouter:deepseek/deepseek-v4-flash", requirements())

    Agent.update(responder, fn _ ->
      fn _ -> json(Map.delete(text_response("stop"), :usage)) end
    end)

    missing = PtcRunner.Labs.LLMTransportBaseline.dispatch(target, "missing", 5_000, HttpAdapter)
    assert missing.result.status == :error
    assert missing.ledger["total_tokens"]["state"] == "incomplete"
    assert missing.ledger["total_tokens"]["charged"] > 4096
    assert missing.ledger["cost"]["charged_microusd"] > 0

    response = %{
      text_response("stop")
      | usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0, cost: "0"}
    }

    Agent.update(responder, fn _ -> fn _ -> json(response) end end)
    zero = PtcRunner.Labs.LLMTransportBaseline.dispatch(target, "zero", 5_000, HttpAdapter)
    assert zero.result.status == :ok
    assert zero.ledger["total_tokens"]["charged"] == 0
    assert zero.ledger["cost"]["charged_microusd"] == 0
  end

  test "actual provider usage above the reservation is retained as an overrun", %{
    responder: responder
  } do
    {:ok, target, _, _} =
      HttpAdapter.prepare_model("openrouter:deepseek/deepseek-v4-flash", requirements())

    response = %{
      text_response("stop")
      | usage: %{prompt_tokens: 9000, completion_tokens: 2000, total_tokens: 11000, cost: "0.02"}
    }

    Agent.update(responder, fn _ -> fn _ -> json(response) end end)
    result = PtcRunner.Labs.LLMTransportBaseline.dispatch(target, "overrun", 5_000, HttpAdapter)
    assert result.ledger["total_tokens"]["charged"] == 11000
    assert result.ledger["total_tokens"]["state"] == "overrun"
    assert result.ledger["cost"]["charged_microusd"] == 20000
  end

  test "matched workflow batches record diagnostic latency and resource observations" do
    observations =
      for adapter <- [ReqLLMAdapter, HttpAdapter] do
        assert {:ok, _} = WorkflowProbe.run(adapter, requirements())
        drain_wire()
        before = resources()
        start = System.monotonic_time(:millisecond)

        samples =
          Task.async_stream(
            1..20,
            fn _ ->
              start = System.monotonic_time(:millisecond)
              assert {:ok, result} = WorkflowProbe.run(adapter, requirements())
              assert result.value == %{"ok" => true, "value" => ["T-1001", "T-1004"]}
              System.monotonic_time(:millisecond) - start
            end,
            max_concurrency: 2,
            timeout: 30_000
          )
          |> Enum.map(fn {:ok, ms} -> ms end)

        elapsed = System.monotonic_time(:millisecond) - start
        assert drain_wire() == 40

        %{
          adapter: inspect(adapter),
          workflows: 20,
          attempts: 40,
          concurrency: 2,
          duration_ms: elapsed,
          workflows_per_second: 20_000 / max(elapsed, 1),
          latency_ms: %{
            samples: samples,
            p50: Enum.at(Enum.sort(samples), 9),
            p95: Enum.at(Enum.sort(samples), 18)
          },
          resources: %{before: before, after: resources()}
        }
      end

    if path = System.get_env("PTC_PILOT_REPORT") do
      PtcRunner.Labs.TransportPreflight.verify_source!(".", @source_identity.runner)

      PtcRunner.Labs.TransportPreflight.verify_source!(
        System.fetch_env!("PTC_LLM_HTTP_PATH"),
        @source_identity.transport
      )

      report = %{
        captured_at: DateTime.to_iso8601(DateTime.utc_now()),
        source: @source_identity,
        probe_hashes:
          Map.new(Path.wildcard("scripts/labs/llm-transport/**/*.{ex,exs}"), fn path ->
            {path, Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower)}
          end),
        observations: observations,
        limitations: [
          "Synthetic loopback HTTP/1 provider closes every response; no TLS or reuse comparison.",
          "Short diagnostic batches, not deployment latency criteria or a sustained leak test."
        ]
      }

      File.write!(path, Jason.encode!(report, pretty: true) <> "\n")
    end
  end

  defp resources,
    do: %{processes: :erlang.system_info(:process_count), ports: :erlang.system_info(:port_count)}

  defp install_trust(dir, ambient_trust, fixture_trust) do
    previous_ca = write_trust(dir, "previous-ca.pem", ambient_trust)

    on_exit(fn ->
      :ok = :public_key.cacerts_load(String.to_charlist(previous_ca))
      assert MapSet.new(system_trust()) == MapSet.new(ambient_trust)
    end)

    ca_file = write_trust(dir, "ca.pem", ambient_trust ++ fixture_trust)
    :ok = :public_key.cacerts_load(String.to_charlist(ca_file))
    assert Enum.all?(ambient_trust, &(&1 in system_trust()))
  end

  defp sustained_duration_ms do
    report? = is_binary(System.get_env("PTC_PILOT_SUSTAINED_REPORT"))

    case Integer.parse(System.get_env("PTC_PILOT_SUSTAINED_MS", "30000")) do
      {duration, ""} when duration >= 30_000 and duration <= 300_000 ->
        duration

      {duration, ""} when duration >= 0 and duration < 30_000 and not report? ->
        duration

      _ ->
        raise "PTC_PILOT_SUSTAINED_MS must be 30000 through 300000 when recording evidence; diagnostics without a report may use 0 through 29999"
    end
  end

  defp sustained_workflows(adapter, minimum, duration_ms, started) do
    sustained_workflows(adapter, minimum, duration_ms, started, [], 0, 0)
  end

  defp sustained_workflows(adapter, minimum, duration_ms, started, latencies, failures, total) do
    elapsed = System.monotonic_time(:millisecond) - started

    if total >= minimum and elapsed >= duration_ms do
      {latencies, failures, total}
    else
      outcomes =
        Task.async_stream(
          1..2,
          fn _ ->
            call_started = System.monotonic_time(:microsecond)
            result = WorkflowProbe.run(adapter, requirements())
            latency_us = System.monotonic_time(:microsecond) - call_started
            {result, latency_us}
          end,
          max_concurrency: 2,
          timeout: 30_000,
          ordered: false
        )
        |> Enum.to_list()

      {next_latencies, next_failures} =
        Enum.reduce(outcomes, {latencies, failures}, fn
          {:ok, {{:ok, %{value: %{"ok" => true, "value" => ["T-1001", "T-1004"]}}}, latency_us}},
          {samples, failed} ->
            {[latency_us | samples], failed}

          _outcome, {samples, failed} ->
            {samples, failed + 1}
        end)

      sustained_workflows(
        adapter,
        minimum,
        duration_ms,
        started,
        next_latencies,
        next_failures,
        total + length(outcomes)
      )
    end
  end

  defp subtract_stats(after_stats, before_stats) do
    request_deltas =
      Map.new(after_stats.requests_by_connection, fn {connection, requests} ->
        {connection, requests - Map.get(before_stats.requests_by_connection, connection, 0)}
      end)

    used_connections =
      request_deltas
      |> Enum.filter(fn {_connection, requests} -> requests > 0 end)
      |> MapSet.new(&elem(&1, 0))

    new_connections =
      after_stats.requests_by_connection
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(before_stats.requests_by_connection, &1))
      |> MapSet.new()

    %{
      accepted_connections: after_stats.accepted_connections - before_stats.accepted_connections,
      successful_handshakes: after_stats.connections - before_stats.connections,
      new_connections: MapSet.size(new_connections),
      connections_used: MapSet.size(used_connections),
      connections_observed: used_connections |> MapSet.union(new_connections) |> MapSet.size(),
      requests: Enum.sum(Map.values(request_deltas))
    }
  end

  defp percentiles(samples_us) do
    samples = Enum.sort(samples_us)
    count = length(samples)

    %{
      p50: percentile(samples, count, 0.50),
      p95: percentile(samples, count, 0.95),
      p99: percentile(samples, count, 0.99)
    }
  end

  defp percentile(samples, count, fraction) do
    index = max(ceil(count * fraction) - 1, 0)
    samples |> Enum.at(index) |> Kernel./(1_000)
  end

  defp drain_wire(count \\ 0) do
    receive do
      {:wire, _} -> drain_wire(count + 1)
    after
      0 -> count
    end
  end

  test "provider errors do not retry and recovery remains available", %{
    responder: responder,
    runtime: runtime
  } do
    {:ok, target, _, _} =
      HttpAdapter.prepare_model("openrouter:deepseek/deepseek-v4-flash", requirements())

    for response <- [{503, [], ""}, :close, {200, [{"content-type", "application/json"}], "{"}] do
      Agent.update(responder, fn _ -> fn _ -> response end end)
      assert {:error, _} = HttpAdapter.call(target, invocation())
      assert_receive {:wire, _}
      refute_received {:wire, _}
      assert {:ok, %{in_use: 0}} = PtcLlmHttp.Runtime.snapshot(runtime)
    end

    Agent.update(responder, fn _ -> fn _ -> json(text_response("stop")) end end)
    assert {:ok, _} = HttpAdapter.call(target, invocation())
  end

  test "repeated cancellation and readmission drains every attempt", %{
    responder: responder,
    runtime: runtime
  } do
    for adapter <- [ReqLLMAdapter, HttpAdapter] do
      {:ok, target, _, _} =
        adapter.prepare_model("openrouter:deepseek/deepseek-v4-flash", requirements())

      hold_responses(responder)

      credential = if adapter == ReqLLMAdapter, do: "loopback-only", else: nil

      for _ <- 1..25 do
        callers =
          for _ <- 1..2, do: spawn_monitor(fn -> adapter.call(target, invocation(credential)) end)

        for _ <- callers, do: assert_receive({:holding, _}, 5_000)

        if adapter == HttpAdapter,
          do: assert({:ok, %{in_use: 2}} = PtcLlmHttp.Runtime.snapshot(runtime))

        for {pid, _} <- callers, do: Process.exit(pid, :kill)

        for {pid, ref} <- callers do
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
          assert_receive :socket_closed, 5_000
        end

        assert_eventually(fn ->
          match?({:ok, %{in_use: 0}}, PtcLlmHttp.Runtime.snapshot(runtime))
        end)
      end

      Agent.update(responder, fn _ -> fn _ -> json(text_response("stop")) end end)
      assert {:ok, _} = adapter.call(target, invocation(credential))
    end
  end

  @tag :http_cold_start
  test "HTTP success returns the published workflow value and readmits" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})

    for adapter <- [ReqLLMAdapter, HttpAdapter] do
      server = workflow_server(host, adapter)

      for _ <- 1..2 do
        assert_success(connect(server.endpoint))
        assert {:ok, %{in_use: 0, status: :ready}} = RunAdmission.snapshot(host)
      end
    end
  end

  @tag :http_rejected_preparation
  test "rejected preparations do not accumulate in a surviving caller" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    GenServer.stop(host)
    {:links, initial_links} = Process.info(self(), :links)

    for _ <- 1..3 do
      assert {:error, :run_admission_unavailable} =
               WorkflowProbe.run_admitted(host, ReqLLMAdapter, requirements())

      {:links, links} = Process.info(self(), :links)

      for pid <- links -- initial_links do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
      end
    end

    refute_received {:wire, _}
  end

  test "HTTP disconnect retains admission until provider cleanup finishes", %{
    responder: responder,
    runtime: runtime
  } do
    parent = self()
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})

    for adapter <- [ReqLLMAdapter, HttpAdapter] do
      hold_responses(responder)

      server =
        workflow_server(host, adapter,
          close: fn ->
            send(parent, {:closing, self()})
            receive do: (:release -> :ok)
          end
        )

      socket = connect(server.endpoint)
      assert_receive {:holding, _}, 5_000
      assert_receive {:wire, _}
      assert_busy(connect(server.endpoint))
      refute_received {:wire, _}
      :gen_tcp.close(socket)
      assert_receive :socket_closed, 5_000
      assert_receive {:closing, closer}, 5_000
      assert {:ok, %{in_use: 1, status: :ready}} = RunAdmission.snapshot(host)
      assert_busy(connect(server.endpoint))
      refute_received {:wire, _}
      send(closer, :release)
      assert_drained(host, runtime)
      Agent.update(responder, fn _ -> fn request -> json(WorkflowProbe.response(request)) end end)
      recovery = workflow_server(host, adapter)
      assert_success(connect(recovery.endpoint))
      # Drain recovery exchanges before asserting no wire work in the next iteration.
      assert_receive {:wire, _}
      assert_receive {:wire, _}
    end
  end

  test "connection-process death cancels the workflow and its provider socket", %{
    responder: responder,
    runtime: runtime
  } do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    hold_responses(responder)

    for adapter <- [ReqLLMAdapter, HttpAdapter] do
      server = workflow_server(host, adapter)
      socket = connect(server.endpoint)
      assert_receive {:connection, connection}, 5_000
      assert_receive {:request_worker, worker}, 5_000
      ref = Process.monitor(worker)
      assert_receive {:holding, _}, 5_000
      Process.exit(connection, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker, _}, 5_000
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
      assert_receive :socket_closed, 5_000
      assert_drained(host, runtime)
    end
  end

  test "a failed provider closer returns a closed error and fences HTTP admission" do
    for adapter <- [ReqLLMAdapter, HttpAdapter] do
      host =
        start_supervised!({RunAdmission, max_concurrent_runs: 1}, id: {:run_admission, adapter})

      server = workflow_server(host, adapter, close: fn -> raise "private-closer-failure" end)
      {head, body} = response(connect(server.endpoint))
      assert head =~ "500 Internal Server Error"
      assert body == %{"error" => "run_failed"}
      assert_receive {:wire, _}
      assert_receive {:wire, _}
      assert {:ok, %{status: :unavailable}} = RunAdmission.snapshot(host)
      {head, body} = response(connect(server.endpoint))
      assert head =~ "503 Unavailable"
      assert body == %{"error" => "run_admission_unavailable"}
      refute_received {:wire, _}
    end
  end

  @tag :http_cold_timeout
  test "HTTP timeout cancels a blocked workflow and returns a bounded error", %{
    responder: responder,
    runtime: runtime
  } do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    hold_responses(responder)

    for adapter <- [ReqLLMAdapter, HttpAdapter] do
      server = workflow_server(host, adapter, [], timeout_ms: 5_000)
      socket = connect(server.endpoint)
      assert_receive {:holding, _}, 5_000
      {head, body} = response(socket)
      assert head =~ "504 Gateway Timeout"
      assert body == %{"error" => "request_timeout"}
      assert_receive :socket_closed, 5_000
      assert_drained(host, runtime)
    end
  end

  test "request-worker death returns an error and drains admission", %{
    responder: responder,
    runtime: runtime
  } do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    hold_responses(responder)

    for adapter <- [ReqLLMAdapter, HttpAdapter] do
      server = workflow_server(host, adapter)
      socket = connect(server.endpoint)
      assert_receive {:request_worker, worker}, 5_000
      assert_receive {:holding, _}, 5_000
      Process.exit(worker, :kill)
      {head, body} = response(socket)
      assert head =~ "500 Internal Server Error"
      assert body == %{"error" => "run_failed"}
      assert_receive :socket_closed, 5_000
      assert_drained(host, runtime)
    end
  end

  for {label, adapter} <- [req_llm: ReqLLMAdapter, http: HttpAdapter] do
    @tag :tmp_dir
    @tag :installed_host
    @tag installed_host_cold_start: label
    @tag installed_adapter: adapter
    test "#{label} real host resolves credentials and runs overlapping workflows over TLS", %{
      tmp_dir: dir,
      responder: responder,
      installed_adapter: adapter
    } do
      parent = self()
      host = start_supervised!({RunAdmission, max_concurrent_runs: 2})
      installation = installed_fixture(dir, adapter)

      assert {:ok, %{source: :llm}} =
               PtcRunner.Kernel.InstallationCatalog.fetch(installation.catalog, "deepseek")

      Agent.update(responder, fn _ ->
        fn request ->
          send(parent, {:provider_barrier, self()})

          receive do
            :release_provider -> json(WorkflowProbe.response(request))
          after
            10_000 -> raise "provider barrier was not released"
          end
        end
      end)

      server = workflow_server(host, adapter, installation: installation)
      sockets = for _ <- 1..2, do: connect(server.endpoint)

      workers =
        for _ <- 1..2 do
          assert_receive {:provider_barrier, worker}, 5_000
          worker
        end

      assert length(Enum.uniq(workers)) == 2
      assert {:ok, %{in_use: 2, status: :ready}} = RunAdmission.snapshot(host)
      Agent.update(responder, fn _ -> fn request -> json(WorkflowProbe.response(request)) end end)
      Enum.each(workers, &send(&1, :release_provider))
      Enum.each(sockets, &assert_success/1)

      for _ <- 1..4 do
        assert_receive {:provider_auth, "Bearer loopback-only"}, 5_000

        assert_receive {:wire, %{"model" => "deepseek/deepseek-v4-flash", "max_tokens" => 4096}},
                       5_000
      end

      assert {:ok, %{in_use: 0, status: :ready}} = RunAdmission.snapshot(host)
      server.close.()
    end
  end

  @tag :tmp_dir
  @tag :installed_host
  test "real host cancellation drains provider TLS connections and permits recovery", %{
    tmp_dir: dir,
    responder: responder,
    runtime: runtime
  } do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})

    for adapter <- [ReqLLMAdapter, HttpAdapter] do
      installation = installed_fixture(dir, adapter)
      server = workflow_server(host, adapter, installation: installation)
      hold_responses(responder)
      socket = connect(server.endpoint)
      assert_receive {:holding, _}, 5_000
      assert_receive {:provider_auth, "Bearer loopback-only"}, 5_000
      :gen_tcp.close(socket)
      assert_receive :socket_closed, 5_000
      assert_drained(host, runtime)
      Agent.update(responder, fn _ -> fn request -> json(WorkflowProbe.response(request)) end end)
      assert_success(connect(server.endpoint))
      server.close.()
    end
  end

  @tag :tmp_dir
  @tag :installed_host
  test "a missing host credential fails before provider traffic", %{tmp_dir: dir} do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})

    for adapter <- [ReqLLMAdapter, HttpAdapter] do
      installation =
        installed_fixture(dir, adapter, %{
          "env" => "PTC_PILOT_ABSENT_#{System.unique_integer([:positive])}"
        })

      server = workflow_server(host, adapter, installation: installation)
      {head, body} = response(connect(server.endpoint))
      assert head =~ "500 Internal Server Error"
      assert body == %{"error" => "run_failed"}
      refute_received {:wire, _}
      assert {:ok, %{in_use: 0, status: :ready}} = RunAdmission.snapshot(host)
      server.close.()
    end
  end

  @tag :tmp_dir
  @tag :installed_host
  test "host-owned provider applications are not restarted by a request", %{tmp_dir: dir} do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})

    for adapter <- [ReqLLMAdapter, HttpAdapter] do
      installation = installed_fixture(dir, adapter)
      server = workflow_server(host, adapter, installation: installation)
      :ok = Application.stop(:req_llm)
      {head, body} = response(connect(server.endpoint))
      assert head =~ "500 Internal Server Error"
      assert body == %{"error" => "run_failed"}
      refute Enum.any?(Application.started_applications(), &(elem(&1, 0) == :req_llm))
      refute_received {:wire, _}
      {:ok, _} = Application.ensure_all_started(:req_llm)
      assert_success(connect(server.endpoint))
      assert_receive {:wire, _}
      assert_receive {:wire, _}
      server.close.()
    end
  end

  @tag :tmp_dir
  @tag :installed_host
  test "an untrusted provider certificate is rejected before credentials reach HTTP", %{
    tmp_dir: dir,
    ambient_trust: ambient_trust
  } do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    stranger = PtcRunner.TestSupport.TLSFixture.configuration()
    wrong_ca = write_trust(dir, "wrong-ca.pem", ambient_trust ++ stranger.trust)
    :ok = :public_key.cacerts_load(String.to_charlist(wrong_ca))
    assert Enum.all?(ambient_trust, &(&1 in system_trust()))
    :ok = Application.stop(:req_llm)

    Application.put_env(:req_llm, :finch,
      pools: %{
        default: [
          count: 1,
          size: 2,
          protocols: [:http1],
          conn_opts: [transport_opts: [cacerts: stranger.trust]]
        ]
      }
    )

    {:ok, _} = Application.ensure_all_started(:req_llm)

    for adapter <- [ReqLLMAdapter, HttpAdapter] do
      installation = installed_fixture(dir, adapter)
      server = workflow_server(host, adapter, installation: installation)
      {head, body} = response(connect(server.endpoint))
      assert head =~ "500 Internal Server Error"
      assert body == %{"error" => "run_failed"}
      refute_received {:wire, _}
      refute_received {:provider_auth, _}
      assert {:ok, %{in_use: 0, status: :ready}} = RunAdmission.snapshot(host)
      server.close.()
    end
  end

  test "request admission owner death refuses later work before preparation" do
    gate = start_supervised!({PtcRunner.Labs.RequestAdmission, 1}, id: :dead_requests)
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    server = workflow_server(host, ReqLLMAdapter, [], request_admission: gate)
    Process.exit(gate, :kill)
    assert_eventually(fn -> not Process.alive?(gate) end)
    {head, body} = response(connect(server.endpoint))
    assert head =~ "503 Unavailable"
    assert body == %{"error" => "request_admission_unavailable"}
    refute_received {:request_worker, _}
    refute_received {:wire, _}
  end

  test "request admission refuses before preparation and survives disconnect" do
    parent = self()
    gate = start_supervised!({PtcRunner.Labs.RequestAdmission, 1}, id: :one_request)
    host = start_supervised!({RunAdmission, max_concurrent_runs: 2})

    server =
      workflow_server(
        host,
        ReqLLMAdapter,
        [
          before_prepare: fn ->
            send(parent, {:preparing, self()})
            receive do: (:continue -> :ok)
          end
        ],
        request_admission: gate
      )

    socket = connect(server.endpoint)
    assert_receive {:preparing, worker}, 5_000
    assert_receive {:request_worker, ^worker}, 5_000
    {head, body} = response(connect(server.endpoint))
    assert head =~ "503 Busy"
    assert body == %{"error" => "request_capacity_exhausted"}
    refute_received {:request_worker, _}
    refute_received {:wire, _}
    assert {:ok, %{in_use: 0}} = RunAdmission.snapshot(host)
    ref = Process.monitor(worker)
    :gen_tcp.close(socket)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 5_000
    assert_eventually(fn -> PtcRunner.Labs.RequestAdmission.snapshot(gate).in_use == 0 end)
    recovered = connect(server.endpoint)
    assert_receive {:preparing, next}, 5_000
    send(next, :continue)
    assert_success(recovered)
  end

  # cacerts_get/0 returns public_key combined_cert records on current OTP;
  # older supported OTP releases can return DER binaries directly.
  defp system_trust do
    Enum.map(:public_key.cacerts_get(), fn
      {:cert, der, _decoded} -> der
      der when is_binary(der) -> der
    end)
  end

  defp write_trust(dir, name, certificates) do
    path = Path.join(dir, name)

    File.write!(
      path,
      :public_key.pem_encode(Enum.map(certificates, &{:Certificate, &1, :not_encrypted}))
    )

    path
  end

  defp installed_fixture(dir, adapter, credential \\ %{"literal" => "loopback-only"}) do
    Application.put_env(:ptc_runner, :llm_adapter, adapter)
    config = "examples/support-triage/ptc-host.json" |> File.read!() |> Jason.decode!()
    config = put_in(config, ["credentials", "openrouter_key"], credential)
    path = Path.join(dir, "ptc-host.json")
    File.write!(path, Jason.encode!(config))
    {:ok, installation} = WorkflowProbe.load_installation(path)
    on_exit(fn -> PtcRunner.Kernel.InstallationCatalog.close(installation.catalog) end)
    installation
  end

  defp workflow_server(host, adapter, run_opts \\ [], http_opts \\ []) do
    parent = self()

    {:ok, supervisor} = ExUnit.fetch_test_supervisor()

    [{_, gate, _, _}] =
      Enum.filter(Supervisor.which_children(supervisor), fn {id, _, _, _} ->
        id == PtcRunner.Labs.RequestAdmission
      end)

    http_opts = Keyword.put_new(http_opts, :request_admission, gate)

    server =
      MCPHTTPFixture.start(fn _ ->
        {:script,
         fn socket ->
           send(parent, {:connection, self()})

           PtcRunner.Labs.ServingHost.serve(
             socket,
             fn ->
               send(parent, {:request_worker, self()})
               if before_prepare = run_opts[:before_prepare], do: before_prepare.()

               case run_opts[:installation] do
                 nil -> WorkflowProbe.run_admitted(host, adapter, requirements(), run_opts)
                 installation -> WorkflowProbe.run_installed(host, installation)
               end
             end,
             http_opts
           )
         end}
      end)

    on_exit(server.close)
    server
  end

  defp assert_drained(host, runtime) do
    assert_eventually(fn ->
      match?({:ok, %{in_use: 0, status: :ready}}, RunAdmission.snapshot(host))
    end)

    assert_eventually(fn -> match?({:ok, %{in_use: 0}}, PtcLlmHttp.Runtime.snapshot(runtime)) end)
  end

  defp assert_success(socket) do
    {head, body} = response(socket)
    assert head =~ "200 OK"
    assert body == %{"result" => %{"ok" => true, "value" => ["T-1001", "T-1004"]}}
  end

  defp assert_busy(socket) do
    {head, body} = response(socket)
    assert head =~ "503 Busy"
    assert body == %{"error" => "run_capacity_exhausted"}
  end

  defp response(socket) do
    [head, body] = socket |> receive_response() |> String.split("\r\n\r\n", parts: 2)
    {head, Jason.decode!(body)}
  end

  defp receive_response(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 7_000) do
      {:ok, bytes} -> receive_response(socket, acc <> bytes)
      {:error, :closed} -> acc
    end
  end

  defp connect(endpoint) do
    uri = URI.parse(endpoint)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, uri.port, [:binary, active: false], 5_000)

    :ok =
      :gen_tcp.send(socket, "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n")

    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  defp hold_responses(responder) do
    parent = self()

    Agent.update(responder, fn _ ->
      fn _ ->
        {:script,
         fn socket ->
           :ok = :inet.setopts(socket, active: :once)
           send(parent, {:holding, self()})

           receive do
             {:tcp_closed, ^socket} -> send(parent, :socket_closed)
           after
             15_000 -> :ok
           end
         end}
      end
    end)
  end

  defp invocation(credential \\ nil) do
    {:ok, invocation} =
      Invocation.new(
        %{messages: [%{role: :user, content: "probe"}]},
        false,
        credential,
        System.monotonic_time(:millisecond) + 5_000
      )

    invocation
  end

  defp text_response(reason) do
    WorkflowProbe.response(%{"messages" => []})
    |> Map.put(:choices, [
      %{index: 0, finish_reason: reason, message: %{role: "assistant", content: "ok"}}
    ])
  end

  defp json(body), do: {200, [{"content-type", "application/json"}], Jason.encode!(body)}

  defp requirements do
    %{
      Requirements.interim(%{max_tokens: 4_096})
      | usage_guarantees: %{tokens: true, cost_currency: "USD"},
        reservation: %{
          total_tokens?: true,
          cost_tariff: %{currency: "USD", id: "pilot-llmdb-2026.8.4"}
        }
    }
  end
end
