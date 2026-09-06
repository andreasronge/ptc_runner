ExUnit.start()
Logger.configure(level: :critical)

defmodule PtcRunner.Labs.ComparisonTest do
  use ExUnit.Case, async: false
  alias PtcRunner.Labs.{HttpAdapter, WorkflowProbe}
  alias PtcRunner.LLM.{Invocation, ReqLLMAdapter, Requirements}
  alias PtcRunner.TestSupport.MCPHTTPFixture
  import PtcRunner.TestSupport.Eventually

  setup do
    owner = self()

    responder =
      start_supervised!(
        {Agent,
         fn ->
           fn request -> json(WorkflowProbe.response(request)) end
         end}
      )

    fixture =
      MCPHTTPFixture.start(fn request ->
        send(owner, {:wire, request.body})

        Agent.get(responder, & &1).(request.body)
      end)

    on_exit(fixture.close)
    Application.put_env(:req_llm, :load_dotenv, false)
    Application.put_env(:llm_db, :load_dotenv, false)
    Application.put_env(:req_llm, :openrouter, base_url: fixture.endpoint)

    Application.put_env(:req_llm, :finch,
      pools: %{default: [count: 1, size: 2, protocols: [:http1]]}
    )

    Application.put_env(:ptc_runner, :pilot_http_endpoint, {fixture.endpoint, :literal_loopback})
    {:ok, _} = Application.ensure_all_started(:req_llm)

    runtime =
      start_supervised!(%{
        id: HttpAdapter,
        type: :supervisor,
        restart: :temporary,
        start: {HttpAdapter, :start_runtime, [[max_concurrency: 2, groups: %{"openrouter" => 2}]]}
      })

    on_exit(fn ->
      Application.stop(:req_llm)
      Application.stop(:llm_db)
    end)

    %{runtime: runtime, responder: responder}
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
      {root, 0} = System.cmd("git", ["rev-parse", "HEAD"])

      {transport, 0} =
        System.cmd("git", ["-C", System.fetch_env!("PTC_LLM_HTTP_PATH"), "rev-parse", "HEAD"])

      report = %{
        captured_at: DateTime.to_iso8601(DateTime.utc_now()),
        root_base: String.trim(root),
        transport: String.trim(transport),
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

  test "HTTP disconnect cancels the admitted workflow and rejects excess workflows locally", %{
    responder: responder,
    runtime: runtime
  } do
    hold_responses(responder)
    host = start_supervised!({PtcRunner.Labs.ServingHost, 1})

    for adapter <- [ReqLLMAdapter, HttpAdapter] do
      server =
        MCPHTTPFixture.start(fn _ ->
          {:script,
           fn socket ->
             PtcRunner.Labs.ServingHost.serve(host, socket, fn ->
               WorkflowProbe.run(adapter, requirements())
             end)
           end}
        end)

      try do
        socket = connect(server.endpoint)
        assert {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
        assert response =~ "200 OK"
        assert_receive {:holding, _}, 5_000
        assert PtcRunner.Labs.ServingHost.snapshot(host) == 1
        assert_receive {:wire, _}
        extra = connect(server.endpoint)
        assert {:ok, response} = :gen_tcp.recv(extra, 0, 5_000)
        assert response =~ "503 Busy"
        :gen_tcp.close(extra)
        refute_received {:wire, _}
        :gen_tcp.close(socket)
        assert_receive :socket_closed, 5_000
        assert_eventually(fn -> PtcRunner.Labs.ServingHost.snapshot(host) == 0 end)

        assert_eventually(fn ->
          match?({:ok, %{in_use: 0}}, PtcLlmHttp.Runtime.snapshot(runtime))
        end)
      after
        server.close.()
      end
    end
  end

  defp connect(endpoint) do
    uri = URI.parse(endpoint)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, uri.port, [:binary, active: false], 5_000)

    :ok =
      :gen_tcp.send(socket, "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n")

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
             5_000 -> :ok
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
