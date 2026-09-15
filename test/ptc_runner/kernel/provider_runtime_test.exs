defmodule PtcRunner.Kernel.ProviderRuntimeTest do
  use ExUnit.Case, async: false

  setup context do
    Process.flag(:trap_exit, true)

    keys = [
      {:req_llm, :load_dotenv},
      {:llm_db, :load_dotenv},
      {:req_llm, :stream_pool_protocols},
      {:req_llm, :stream_pool_count},
      {:req_llm, :stream_pool_size},
      {:req_llm, :finch}
    ]

    previous = Map.new(keys, fn {app, key} -> {{app, key}, Application.fetch_env(app, key)} end)
    running = Enum.map(Application.started_applications(), &elem(&1, 0))

    if context[:cold_provider], do: Application.stop(:req_llm)

    on_exit(fn ->
      if context[:cold_provider], do: Application.stop(:req_llm)

      for app <- [:req_llm, :llm_db], app not in running do
        Application.stop(app)
      end

      Enum.each(previous, fn
        {{app, key}, {:ok, value}} -> Application.put_env(app, key, value)
        {{app, key}, :error} -> Application.delete_env(app, key)
      end)

      if context[:cold_provider] == true and :req_llm in running do
        {:ok, _} = Application.ensure_all_started(:req_llm)
      end
    end)

    :ok
  end

  import ExUnit.CaptureIO

  alias PtcRunner.Kernel.{
    Attestation,
    Capability,
    ExecutionInput,
    ExecutionOutcome,
    ExecutionPolicy,
    ExecutionSessionOwner,
    HostConfig,
    HostInstallation,
    InstallationCatalog,
    Limits,
    PreparedRun,
    ProviderAcquisition,
    ProviderCallAdmission,
    ProviderDescriptor,
    ProviderExecution,
    ProviderRegistry,
    ProviderRuntime,
    ProviderRuntimeServices,
    ProviderSession,
    ProviderSnapshot,
    ProviderTaskTracker,
    PublicationAuthority,
    RunAdmission,
    RunBuilder,
    RunConfig,
    RunRequest,
    SelectionRules,
    ServingOutcome,
    ServingTemplate,
    WarmProviderApplications,
    WarmProviderRuntime
  }

  alias PtcRunner.TestSupport.Eventually
  alias PtcRunner.TestSupport.MCPHTTPFixture

  @tag :tmp_dir
  @tag :cold_provider
  test "installed requester reuses an observable HTTP connection through warm serving calls", %{
    tmp_dir: dir
  } do
    parent = self()
    held = :atomics.new(1, [])

    response =
      Jason.encode!(%{
        "id" => "warm-response",
        "model" => "google/gemma-2-27b-it",
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => "ok"}
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
      })

    server =
      MCPHTTPFixture.start(fn request ->
        send(parent, {:warm_connection, request.connection, request.headers["authorization"]})

        if :atomics.get(held, 1) == 1 do
          send(parent, {:held_http, self()})
          receive do: (:release_http -> :ok)
        end

        {:keep_alive, 200, [{"content-type", "application/json"}], response}
      end)

    on_exit(server.close)
    previous = Application.fetch_env(:req_llm, :openrouter)
    Application.put_env(:req_llm, :openrouter, base_url: server.endpoint)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:req_llm, :openrouter, value)
        :error -> Application.delete_env(:req_llm, :openrouter)
      end
    end)

    Enum.each(documents(), fn {name, contents} -> File.write!(Path.join(dir, name), contents) end)

    File.write!(
      Path.join(dir, "main.clj"),
      ~s|(ns app) (defn run {:effect :write :requires ["tool:llm-request"]} [input] (return (tool/llm-request {"messages" [{"role" "user" "content" "hello"}]})))|
    )

    File.write!(
      Path.join(dir, "schema.json"),
      Jason.encode!(%{"type" => "object", "additionalProperties" => true})
    )

    host_path = Path.join(dir, "host.json")
    token = String.duplicate("gateway-token", 4)
    credential_path = Path.join(dir, "provider.key")
    File.write!(credential_path, "provider-fixture-key")

    File.write!(
      host_path,
      Jason.encode!(%{
        "credentials" => %{
          "key" => %{"file" => "provider.key"},
          "bearer" => %{"literal" => token}
        },
        "install" => %{
          "selected" => %{
            "source" => "llm",
            "model" => "openrouter:google/gemma-2-27b-it",
            "credential" => "key",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "installation_revision" => "warm-v1"
          }
        }
      })
    )

    {:ok, host} = HostConfig.load(host_path)
    {:ok, catalog} = HostInstallation.catalog(host)
    {:ok, services} = HostInstallation.runtime_services(host)

    {:ok, template} =
      ServingTemplate.from_directory(Path.join(dir, "app.json"), host.limits, providers: catalog)

    {:ok, applications, _} = WarmProviderApplications.start([:req_llm], 1)

    output =
      capture_io(fn ->
        {:ok, discovery} =
          ProviderRuntime.start_link(template: template, services: services, pins: :discover)

        GenServer.stop(discovery)
      end)

    Enum.each(Enum.reverse(applications), &Application.stop/1)
    discovered = Jason.decode!(output)

    pins = %{
      installation_config_pins: discovered["installation_config_pins"],
      provider_snapshot_pins: discovered["provider_snapshot_pins"]
    }

    admission = start_supervised!({RunAdmission, max_concurrent_runs: 3})

    {:ok, warm} =
      WarmProviderRuntime.start_link(
        tools: %{"tool" => %{template: template, pins: pins}},
        services: services,
        bearer_binding: "bearer",
        run_admission: admission,
        max_active_provider_calls: 1,
        max_waiting_provider_calls: 1
      )

    {:ok, bound} = WarmProviderRuntime.template(warm, "tool")
    File.write!(credential_path, "rotated-provider-key")

    for _ <- 1..2 do
      assert :success ==
               ServingOutcome.code(ServingTemplate.call(bound, %{}, admission))
    end

    assert_receive {:warm_connection, connection, "Bearer provider-fixture-key"}
    assert_receive {:warm_connection, ^connection, "Bearer provider-fixture-key"}

    assert %{ready: true, provider_call_admission: %{active: 0, waiting: 0}} =
             WarmProviderRuntime.snapshot(warm)

    :atomics.put(held, 1, 1)
    first = Task.async(fn -> ServingTemplate.call(bound, %{}, admission) end)
    assert_receive {:held_http, first_worker}
    second = Task.async(fn -> ServingTemplate.call(bound, %{}, admission) end)

    Eventually.assert_eventually(fn ->
      match?(
        %{ready: true, provider_call_admission: %{active: 1, waiting: 1}},
        WarmProviderRuntime.snapshot(warm)
      )
    end)

    overflow = ServingTemplate.call(bound, %{}, admission)

    assert {:ok,
            %{"kind" => "provider_error", "reason" => "capacity_exhausted", "retryable?" => true}} =
             ServingOutcome.value(overflow)

    send(first_worker, :release_http)
    assert :success == ServingOutcome.code(Task.await(first))
    assert_receive {:held_http, second_worker}
    send(second_worker, :release_http)
    assert :success == ServingOutcome.code(Task.await(second))

    assert :ok = Finch.set_pool_count(ReqLLM.Finch, Finch.Pool.new(server.endpoint), 2)
    assert %{ready: false, fenced: true} = WarmProviderRuntime.snapshot(warm)

    assert :admission_unavailable ==
             ServingOutcome.code(ServingTemplate.call(bound, %{}, admission))

    assert :ok =
             WarmProviderRuntime.drain(
               warm,
               System.monotonic_time(:millisecond) + 1_000
             )

    GenServer.stop(warm)
    InstallationCatalog.close(catalog)
  end

  @tag :tmp_dir
  @tag :cold_provider
  test "warm application startup owns one pool and refuses prestarted ReqLLM without resizing", %{
    tmp_dir: dir
  } do
    {template, _catalog, _services, pins, _counts} = fixture(dir, provider_application: :req_llm)

    {:ok, services} =
      ProviderRuntimeServices.new(
        credential_resolver: fn _ ->
          {:ok, %{"bearer" => String.duplicate("token", 10)}}
        end
      )

    admission = start_supervised!({RunAdmission, max_concurrent_runs: 1})

    opts = [
      tools: %{"tool" => %{template: template, pins: pins}},
      services: services,
      bearer_binding: "bearer",
      run_admission: admission,
      max_active_provider_calls: 2,
      max_waiting_provider_calls: 0
    ]

    oversized_tools =
      Map.new(1..129, fn index ->
        {"tool-#{index}", %{template: template, pins: pins}}
      end)

    assert {:error, :invalid_warm_provider_runtime} =
             WarmProviderRuntime.start_link(Keyword.put(opts, :tools, oversized_tools))

    {:ok, _} = Application.ensure_all_started(:llm_db)
    {:ok, warm} = WarmProviderRuntime.start_link(opts)
    on_exit(fn -> if Process.alive?(warm), do: GenServer.stop(warm) end)
    pool = Process.whereis(ReqLLM.Finch.Supervisor)
    assert WarmProviderApplications.ready?(pool, 2)
    assert Application.get_env(:req_llm, :stream_pool_size) == 2
    {:ok, bound} = WarmProviderRuntime.template(warm, "tool")

    for _ <- 1..2 do
      assert :success ==
               ServingOutcome.code(ServingTemplate.call(bound, %{}, admission))

      assert Process.whereis(ReqLLM.Finch.Supervisor) == pool
    end

    assert {:error, :provider_application_prestarted} =
             WarmProviderRuntime.start_link(Keyword.put(opts, :max_active_provider_calls, 3))

    assert Application.get_env(:req_llm, :stream_pool_size) == 2

    assert :ok =
             WarmProviderRuntime.drain(
               warm,
               System.monotonic_time(:millisecond) + 1_000
             )

    refute :req_llm in Enum.map(Application.started_applications(), &elem(&1, 0))
    assert :llm_db in Enum.map(Application.started_applications(), &elem(&1, 0))
    GenServer.stop(warm)
  end

  @tag :tmp_dir
  test "startup pin refusal restores captured scope and closes acquired resources", %{
    tmp_dir: dir
  } do
    {template, _catalog, _services, pins, counts} = fixture(dir)
    key = "PTC_WARM_FAILED_START_TEST"
    path = Path.join(dir, "failure.env")
    File.write!(path, key <> "=" <> String.duplicate("token", 10) <> "\n")
    previous = System.get_env(key)
    System.delete_env(key)

    on_exit(fn ->
      if previous, do: System.put_env(key, previous), else: System.delete_env(key)
    end)

    {:ok, services} =
      ProviderRuntimeServices.new(
        credential_resolver: fn _ ->
          {:ok, %{"bearer" => System.fetch_env!(key)}}
        end
      )

    admission = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    wrong = %{pins | provider_snapshot_pins: %{}}

    assert {:error, :provider_pin_mismatch} =
             WarmProviderRuntime.start_link(
               tools: %{"tool" => %{template: template, pins: wrong}},
               services: services,
               bearer_binding: "bearer",
               env_file: path,
               run_admission: admission,
               max_active_provider_calls: 1,
               max_waiting_provider_calls: 0
             )

    assert System.get_env(key) == nil
    assert :atomics.get(counts, 1) == 1
    assert :atomics.get(counts, 2) == 1
    assert :ok = PtcRunner.Dotenv.with_loaded_file(path, fn -> :ok end)
    assert System.get_env(key) == nil
  end

  @tag :tmp_dir
  test "retained template attestation consumes the readiness deadline before the runtime call", %{
    tmp_dir: dir
  } do
    {template, _catalog, services, pins, _counts} = fixture(dir)

    {:ok, runtime} =
      ProviderRuntime.start_link(template: template, services: services, pins: pins)

    :ok = :sys.suspend(runtime)

    on_exit(fn ->
      if Process.alive?(runtime) do
        :sys.resume(runtime)
        GenServer.stop(runtime)
      end
    end)

    reader = template.retained.reader
    padding = :binary.copy("x", 64 * 1024 * 1024)
    padded_reader = fn -> Map.put(reader.(), :readiness_test_padding, padding) end

    retained = %{
      reader: padded_reader,
      attestation:
        Attestation.attest(
          ServingTemplate,
          {template.package, template.installation_digests, template.effective_digest,
           padded_reader}
        )
    }

    padded = %{template | retained: retained}
    :erlang.trace_pattern({GenServer, :call, 3}, true, [:local])
    on_exit(fn -> :erlang.trace_pattern({GenServer, :call, 3}, false, [:local]) end)

    task =
      Task.async(fn ->
        receive do
          :check ->
            ProviderRuntime.matches_template?(
              runtime,
              padded,
              System.monotonic_time(:millisecond) + 10
            )
        end
      end)

    :erlang.trace(task.pid, true, [:call, {:tracer, self()}])
    send(task.pid, :check)
    refute Task.await(task)
    delivered = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, _, ^delivered}
    caller = task.pid
    refute_received {:trace, ^caller, :call, {GenServer, :call, [^runtime, _, _]}}
    :sys.resume(runtime)
    GenServer.stop(runtime)
  end

  @tag :tmp_dir
  test "delayed failed warm health cannot outlive the reservation deadline", %{tmp_dir: dir} do
    {template, _catalog, _services, pins, _counts} = fixture(dir)

    {:ok, services} =
      ProviderRuntimeServices.new(
        credential_resolver: fn _ -> {:ok, %{"bearer" => String.duplicate("token", 10)}} end
      )

    admission = start_supervised!({RunAdmission, max_concurrent_runs: 1})

    {:ok, warm} = start_warm(template, services, pins, admission)

    {:ok, bound} = WarmProviderRuntime.template(warm, "tool")
    gate = :sys.get_state(warm).admission

    {:ok, lease} =
      ProviderCallAdmission.checkout(gate, System.monotonic_time(:millisecond) + 1_000)

    assert {:error, :provider_cleanup_failed} = ProviderCallAdmission.complete(lease, :uncertain)
    :ok = :sys.suspend(warm)

    on_exit(fn ->
      if Process.alive?(warm) do
        :sys.resume(warm)
        GenServer.stop(warm)
      end
    end)

    parent = self()

    controller =
      spawn(fn ->
        receive do
          :resume ->
            :sys.resume(warm)
            send(parent, :health_resumed)
        end
      end)

    Process.send_after(controller, :resume, 500)

    result =
      ServingTemplate.reserve(bound, %{}, admission, System.monotonic_time(:millisecond) + 30)

    assert ServingOutcome.code(result) == :cancelled
    assert ServingOutcome.metadata(result).dispatched == false
    refute_received :health_resumed
    assert_receive :health_resumed, 1_000
    GenServer.stop(warm)
  end

  @tag :tmp_dir
  test "cached warm tools refuse reservation and activation after a live gate fences", %{
    tmp_dir: dir
  } do
    {template, _catalog, services, pins, _counts} = fixture(dir)

    manifest =
      dir |> Path.join("app.json") |> File.read!() |> Jason.decode!() |> Map.delete("providers")

    free_path = Path.join(dir, "free.json")
    File.write!(free_path, Jason.encode!(manifest))
    {:ok, free} = ServingTemplate.from_directory(free_path, Limits.defaults())

    {:ok, services} =
      ProviderRuntimeServices.new(
        activation: services.activation,
        credential_resolver: fn _ -> {:ok, %{"bearer" => String.duplicate("token", 10)}} end
      )

    admission = start_supervised!({RunAdmission, max_concurrent_runs: 4})

    {:ok, warm} =
      WarmProviderRuntime.start_link(
        tools: %{
          "provider" => %{template: template, pins: pins},
          "free" => %{
            template: free,
            pins: %{installation_config_pins: %{}, provider_snapshot_pins: %{}}
          }
        },
        services: services,
        bearer_binding: "bearer",
        run_admission: admission,
        max_active_provider_calls: 1,
        max_waiting_provider_calls: 0
      )

    on_exit(fn -> if Process.alive?(warm), do: GenServer.stop(warm) end)
    {:ok, provider} = WarmProviderRuntime.template(warm, "provider")
    {:ok, free} = WarmProviderRuntime.template(warm, "free")
    {:ok, provider_reservation} = ServingTemplate.reserve(provider, %{}, admission)
    {:ok, free_reservation} = ServingTemplate.reserve(free, %{}, admission)
    gate = :sys.get_state(warm).admission

    {:ok, lease} =
      ProviderCallAdmission.checkout(
        gate,
        System.monotonic_time(:millisecond) + 1_000
      )

    assert {:error, :provider_cleanup_failed} =
             ProviderCallAdmission.complete(lease, :uncertain)

    assert Process.alive?(gate)

    for reservation <- [free_reservation, provider_reservation] do
      result = ServingTemplate.activate(reservation)
      assert ServingOutcome.code(result) == :admission_unavailable
      assert ServingOutcome.metadata(result).dispatched == false
    end

    for cached <- [free, provider] do
      result = ServingTemplate.call(cached, %{}, admission)
      assert ServingOutcome.code(result) == :admission_unavailable
      assert ServingOutcome.metadata(result).dispatched == false
    end

    assert %{ready: false, fenced: true} = WarmProviderRuntime.snapshot(warm)
    GenServer.stop(warm)
  end

  @tag :tmp_dir
  test "reserved provider call refuses activation when its runtime quiesces", %{tmp_dir: dir} do
    {template, _catalog, services, pins, _counts} = fixture(dir)

    {:ok, runtime} =
      ProviderRuntime.start_link(template: template, services: services, pins: pins)

    on_exit(fn -> if Process.alive?(runtime), do: GenServer.stop(runtime) end)
    {:ok, bound} = ServingTemplate.with_provider_runtime(template, runtime)
    admission = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    {:ok, reservation} = ServingTemplate.reserve(bound, %{}, admission)
    assert :ok = ProviderRuntime.quiesce(runtime)
    result = ServingTemplate.activate(reservation)
    assert ServingOutcome.code(result) == :admission_unavailable
    assert ServingOutcome.metadata(result).dispatched == false
    assert :ok = ProviderRuntime.drain(runtime, System.monotonic_time(:millisecond) + 1_000)
    GenServer.stop(runtime)
  end

  @tag :tmp_dir
  test "missing provider gate permanently fences old bound templates", %{tmp_dir: dir} do
    {template, _catalog, _services, pins, _counts} = fixture(dir)

    {:ok, services} =
      ProviderRuntimeServices.new(
        credential_resolver: fn _ ->
          {:ok, %{"bearer" => String.duplicate("token", 10)}}
        end
      )

    admission = start_supervised!({RunAdmission, max_concurrent_runs: 1})

    {:ok, warm} = start_warm(template, services, pins, admission)

    on_exit(fn -> if Process.alive?(warm), do: GenServer.stop(warm) end)
    {:ok, bound} = WarmProviderRuntime.template(warm, "tool")
    gate = :sys.get_state(warm).admission
    ref = Process.monitor(gate)
    Process.exit(gate, :kill)
    assert_receive {:DOWN, ^ref, :process, ^gate, :killed}
    assert %{ready: false, fenced: true} = WarmProviderRuntime.snapshot(warm)

    assert :admission_unavailable ==
             ServingOutcome.code(ServingTemplate.call(bound, %{}, admission))

    GenServer.stop(warm)
  end

  @tag :tmp_dir
  test "warm host captures once, restores env-file scope, and fences missing admission", %{
    tmp_dir: dir
  } do
    {template, _catalog, _services, pins, counts} = fixture(dir)
    token_name = "PTC_WARM_BEARER_TEST"
    previous = System.get_env(token_name)
    token = String.duplicate("startup-token", 4)
    path = Path.join(dir, "startup.env")
    File.write!(path, token_name <> "=" <> token <> "\n")
    System.put_env(token_name, "inherited")

    on_exit(fn ->
      if previous, do: System.put_env(token_name, previous), else: System.delete_env(token_name)
    end)

    resolutions = :atomics.new(1, [])

    {:ok, services} =
      ProviderRuntimeServices.new(
        credential_resolver: fn names ->
          assert names == ["bearer"]
          :atomics.add(resolutions, 1, 1)
          {:ok, %{"bearer" => System.fetch_env!(token_name)}}
        end
      )

    admission = start_supervised!({RunAdmission, max_concurrent_runs: 2})

    {:ok, warm} =
      WarmProviderRuntime.start_link(
        tools: %{"tool" => %{template: template, pins: pins}},
        services: services,
        bearer_binding: "bearer",
        env_file: path,
        run_admission: admission,
        max_active_provider_calls: 1,
        max_waiting_provider_calls: 2
      )

    on_exit(fn -> if Process.alive?(warm), do: GenServer.stop(warm) end)
    assert System.get_env(token_name) == "inherited"
    assert :atomics.get(resolutions, 1) == 1
    assert WarmProviderRuntime.authenticate(warm, token)
    refute inspect(:sys.get_status(warm)) =~ token
    System.put_env(token_name, String.duplicate("rotated", 8))
    File.write!(path, token_name <> "=rotated-file\n")
    assert WarmProviderRuntime.authenticate(warm, token)

    assert %{ready: true, provider_call_admission: %{capacity: 1, status: :ready}} =
             WarmProviderRuntime.snapshot(warm)

    {:ok, bound} = WarmProviderRuntime.template(warm, "tool")

    for _ <- 1..2 do
      assert :success ==
               ServingOutcome.code(ServingTemplate.call(bound, %{}, admission))
    end

    assert :atomics.get(counts, 1) == 1
    assert :atomics.get(resolutions, 1) == 1

    assert :ok =
             WarmProviderRuntime.drain(
               warm,
               System.monotonic_time(:millisecond) + 1_000
             )

    assert :atomics.get(counts, 2) == 1
    refute WarmProviderRuntime.snapshot(warm).ready
    GenServer.stop(warm)
  end

  @tag :tmp_dir
  test "serving calls borrow the warm acquisition and return every per-call resource", %{
    tmp_dir: dir
  } do
    {template, _catalog, services, pins, counts} = fixture(dir)

    {:ok, runtime} =
      ProviderRuntime.start_link(template: template, services: services, pins: pins)

    on_exit(fn -> if Process.alive?(runtime), do: GenServer.stop(runtime) end)
    assert {:ok, template} = ServingTemplate.with_provider_runtime(template, runtime)
    admission = start_supervised!({RunAdmission, max_concurrent_runs: 2})

    for input <- [%{}, %{}] do
      result = ServingTemplate.call(template, input, admission)
      assert ServingOutcome.code(result) == :success
    end

    assert :atomics.get(counts, 1) == 1
    assert :atomics.get(counts, 2) == 0
    assert :ok = ProviderRuntime.drain(runtime, System.monotonic_time(:millisecond) + 1_000)
    assert :atomics.get(counts, 2) == 1
  end

  @tag :tmp_dir
  test "acquire once, concurrent borrowed executions never close shared providers", %{
    tmp_dir: dir
  } do
    {template, catalog, services, pins, counts} =
      fixture(dir,
        source_code:
          "(ns app) (defn run {:effect :write :requires [\"tool:llm-request\"]} [input] (do (tool/llm-request {}) (return input)))"
      )

    assert :atomics.get(counts, 1) == 0
    Code.ensure_loaded!(ProviderAcquisition)
    pattern = {ProviderAcquisition, :acquire, 6}
    :erlang.trace_pattern(pattern, true, [:local])
    :erlang.trace(:new, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern(pattern, false, [:local])
    end)

    assert {:ok, runtime} =
             ProviderRuntime.start_link(template: template, services: services, pins: pins)

    on_exit(fn -> if Process.alive?(runtime), do: GenServer.stop(runtime) end)
    assert ProviderRuntime.status(runtime) == :ready
    assert :atomics.get(counts, 1) == 1
    {:ok, execution} = ProviderExecution.new(catalog, services, [])
    host = start_supervised!({RunAdmission, max_concurrent_runs: 16})

    results =
      1..16
      |> Task.async_stream(
        fn _ ->
          deadline = System.monotonic_time(:millisecond) + 10_000
          {:ok, borrow} = ProviderRuntime.borrow(runtime, deadline)

          {:ok, input} =
            ExecutionInput.new(%{}, :normal, template.package.contracts.input)

          {:ok, policy} = ExecutionPolicy.new(result_projection: :json)
          {:ok, request} = RunRequest.new(template.package, input, policy)
          {:ok, prepared} = ServingTemplate.prepare_call(template, request)

          retained = %ProviderExecution.Retained{
            execution: execution,
            borrow: borrow,
            plan_identity: borrow.plan_identity
          }

          {:ok, reservation} = RunAdmission.reserve(host, deadline)

          {:ok, active} =
            RunAdmission.activate(reservation, prepared, authority = authority(), retained)

          result = RunAdmission.await(active)
          assert {:ok, outcome} = result

          assert {:ok, %{result: {:ok, _}, result_contract: :ok}} =
                   ExecutionOutcome.open(outcome, authority)

          PublicationAuthority.abort(authority)
          PreparedRun.close(prepared)
          :ok = ProviderRuntime.return(borrow)
          result
        end,
        max_concurrency: 16,
        timeout: 20_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1)), inspect(results)
    assert :atomics.get(counts, 1) == 1
    assert :atomics.get(counts, 2) == 0
    assert :atomics.get(counts, 3) == 16
    delivered = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^delivered}
    assert acquisition_calls([]) |> length() == 1
    assert :ok = ProviderRuntime.drain(runtime, System.monotonic_time(:millisecond) + 1_000)
    assert :atomics.get(counts, 2) == 1
    assert :ok = ProviderRuntime.drain(runtime, System.monotonic_time(:millisecond))
    assert :atomics.get(counts, 2) == 1
  end

  @tag :tmp_dir
  test "missing extra and wrong pins retain nothing; discovery closes its acquisition", %{
    tmp_dir: dir
  } do
    {template, _catalog, services, pins, counts} = fixture(dir)

    for config <- [
          %{},
          Map.put(pins.installation_config_pins, "extra", "sha256:" <> String.duplicate("a", 64)),
          Map.new(pins.installation_config_pins, fn {name, _} ->
            {name, "sha256:" <> String.duplicate("b", 64)}
          end)
        ] do
      assert {:error, :installation_pin_mismatch} =
               ProviderRuntime.start_link(
                 template: template,
                 services: services,
                 pins: %{pins | installation_config_pins: config}
               )
    end

    for snapshots <- [
          %{},
          Map.put(
            pins.provider_snapshot_pins,
            "mission/extra",
            "sha256:" <> String.duplicate("a", 64)
          ),
          %{"workflow/selected" => "sha256:" <> String.duplicate("b", 64)}
        ] do
      assert {:error, :provider_pin_mismatch} =
               ProviderRuntime.start_link(
                 template: template,
                 services: services,
                 pins: %{pins | provider_snapshot_pins: snapshots}
               )
    end

    assert :atomics.get(counts, 1) == :atomics.get(counts, 2)

    output =
      capture_io(fn ->
        assert {:ok, runtime} =
                 ProviderRuntime.start_link(
                   template: template,
                   services: services,
                   pins: :discover
                 )

        assert ProviderRuntime.status(runtime) == {:not_ready, :provider_runtime_required}
        GenServer.stop(runtime)
      end)

    assert Jason.decode!(output) == %{
             "installation_config_pins" => pins.installation_config_pins,
             "provider_snapshot_pins" => pins.provider_snapshot_pins
           }

    assert :atomics.get(counts, 1) == :atomics.get(counts, 2)
  end

  @tag :tmp_dir
  test "unpinnable and unsupported installations refuse readiness", %{tmp_dir: dir} do
    {template, _catalog, services, pins, counts} = fixture(dir, snapshot: false)

    assert {:error, :provider_pin_unavailable} =
             ProviderRuntime.start_link(template: template, services: services, pins: pins)

    assert :atomics.get(counts, 1) == :atomics.get(counts, 2)
    {template, _catalog, services, pins, counts} = fixture(dir, config_digest: false)

    assert {:error, :provider_pin_unavailable} =
             ProviderRuntime.start_link(template: template, services: services, pins: pins)

    assert :atomics.get(counts, 1) == :atomics.get(counts, 2)
    {template, _catalog, services, pins, counts} = fixture(dir, source: :custom)

    assert {:error, :provider_runtime_unsupported} =
             ProviderRuntime.start_link(template: template, services: services, pins: pins)

    assert :atomics.get(counts, 1) == 0
  end

  @tag :tmp_dir
  test "drain with outstanding borrows closes once and caller loss returns capacity", %{
    tmp_dir: dir
  } do
    {template, _catalog, services, pins, counts} = fixture(dir)

    {:ok, runtime} =
      ProviderRuntime.start_link(template: template, services: services, pins: pins)

    {:ok, borrow} = ProviderRuntime.borrow(runtime, System.monotonic_time(:millisecond) + 10_000)

    assert {:error, {:outstanding_borrows, 1}} =
             ProviderRuntime.drain(runtime, System.monotonic_time(:millisecond))

    assert ProviderRuntime.status(runtime) == :draining

    assert {:error, :provider_runtime_unavailable} =
             ProviderRuntime.borrow(runtime, System.monotonic_time(:millisecond) + 10_000)

    assert :ok = ProviderRuntime.return(borrow)
    assert :atomics.get(counts, 2) == 1
    GenServer.stop(runtime)
  end

  @tag :tmp_dir
  test "far-future drain deadlines remain pending when the timer is rechecked", %{tmp_dir: dir} do
    {template, _catalog, services, pins, counts} = fixture(dir)

    {:ok, runtime} =
      ProviderRuntime.start_link(template: template, services: services, pins: pins)

    deadline = System.monotonic_time(:millisecond) + 4_294_967_296
    {:ok, borrow} = ProviderRuntime.borrow(runtime, deadline)
    drain = Task.async(fn -> ProviderRuntime.drain(runtime, deadline) end)
    assert Task.yield(drain, 20) == nil
    assert ProviderRuntime.status(runtime) == :draining
    send(runtime, :drain_deadline)
    assert ProviderRuntime.status(runtime) == :draining
    assert Task.yield(drain, 20) == nil
    assert :atomics.get(counts, 2) == 0
    assert :ok = ProviderRuntime.return(borrow)
    assert :ok = Task.await(drain)
    assert :atomics.get(counts, 2) == 1
    GenServer.stop(runtime)
  end

  @tag :tmp_dir
  test "session loss permanently refuses new borrows", %{tmp_dir: dir} do
    {template, _catalog, services, pins, _counts} = fixture(dir)

    {:ok, runtime} =
      ProviderRuntime.start_link(template: template, services: services, pins: pins)

    {:ok, borrow} = ProviderRuntime.borrow(runtime, System.monotonic_time(:millisecond) + 10_000)
    :ok = ProviderSession.close(borrow.session.session)
    assert ProviderRuntime.status(runtime) == {:not_ready, :provider_runtime_lost}

    assert {:error, :provider_runtime_unavailable} =
             ProviderRuntime.borrow(runtime, System.monotonic_time(:millisecond) + 10_000)

    ProviderRuntime.return(borrow)
    GenServer.stop(runtime)
  end

  @tag :tmp_dir
  test "borrow deadline is per-call and expired builds return the borrow without closing", %{
    tmp_dir: dir
  } do
    {template, _catalog, services, pins, counts} = fixture(dir)

    {:ok, runtime} =
      ProviderRuntime.start_link(template: template, services: services, pins: pins)

    deadline = System.monotonic_time(:millisecond) - 1
    {:ok, borrow} = ProviderRuntime.borrow(runtime, deadline)
    assert {:ok, %{expires_at_ms: ^deadline}} = ProviderSession.execution_deadline(borrow.session)
    {:ok, prepared} = call_preparation(template)
    authority = authority()
    {:ok, sinks} = RunBuilder.open_prepared_sinks(prepared, authority, self())

    assert {:error, :invalid_prepared_run} =
             RunBuilder.build_borrowed_owned(
               prepared,
               borrow.registry,
               authority,
               sinks,
               borrow
             )

    refute ProviderRuntime.valid_borrow?(borrow)
    assert :ok = ProviderRuntime.return(borrow)
    assert :atomics.get(counts, 2) == 0
    PublicationAuthority.abort(authority)
    PreparedRun.close(prepared)
    assert :ok = ProviderRuntime.drain(runtime, System.monotonic_time(:millisecond))
    assert :atomics.get(counts, 2) == 1
    GenServer.stop(runtime)
  end

  @tag :tmp_dir
  test "plan mismatch and configuration failure close no shared provider", %{tmp_dir: dir} do
    {template, _catalog, services, pins, counts} = fixture(dir)

    {:ok, runtime} =
      ProviderRuntime.start_link(template: template, services: services, pins: pins)

    {:ok, borrow} = ProviderRuntime.borrow(runtime, System.monotonic_time(:millisecond) + 10_000)
    {:ok, prepared} = call_preparation(template)
    authority = authority()
    {:ok, sinks} = RunBuilder.open_prepared_sinks(prepared, authority, self())
    wrong = %{borrow | plan_identity: {:wrong, :plan, %{}}}

    assert {:error, :provider_runtime_mismatch} =
             RunBuilder.build_borrowed_owned(
               prepared,
               borrow.registry,
               authority,
               sinks,
               wrong
             )

    assert :atomics.get(counts, 2) == 0
    assert {:error, _} = RunConfig.new(provider_session: borrow.session, limits: :invalid)
    assert :ok = ProviderSession.close(borrow.session)
    assert :ok = ProviderSession.close_detailed(borrow.session)
    assert ProviderSession.alive?(borrow.session)
    ProviderRuntime.return(borrow)
    PublicationAuthority.abort(authority)
    PreparedRun.close(prepared)
    ProviderRuntime.drain(runtime, System.monotonic_time(:millisecond))
    assert :atomics.get(counts, 2) == 1
    GenServer.stop(runtime)
  end

  @tag :tmp_dir
  test "caller exit releases outstanding borrow before drain", %{tmp_dir: dir} do
    {template, _catalog, services, pins, counts} = fixture(dir)

    {:ok, runtime} =
      ProviderRuntime.start_link(template: template, services: services, pins: pins)

    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        {:ok, _borrow} =
          ProviderRuntime.borrow(runtime, System.monotonic_time(:millisecond) + 10_000)

        send(parent, :borrowed)
        receive do: (:stop -> :ok)
      end)

    assert_receive :borrowed

    task =
      Task.async(fn ->
        ProviderRuntime.drain(runtime, System.monotonic_time(:millisecond) + 10_000)
      end)

    send(caller, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    assert :ok = Task.await(task)
    assert :atomics.get(counts, 2) == 1
    GenServer.stop(runtime)
  end

  @tag :tmp_dir
  test "template catalog opt-in validates seals and limits without touching providers", %{
    tmp_dir: dir
  } do
    {template, catalog, _services, pins, counts} = fixture(dir)
    path = Path.join(dir, "app.json")

    assert {:error, :provider_runtime_required} =
             ServingTemplate.from_directory(path, Limits.installed_defaults())

    assert {:error, :invalid_installation_catalog} =
             ServingTemplate.from_directory(path, Limits.installed_defaults(), providers: %{})

    assert {:error, :invalid_installation_catalog} =
             ServingTemplate.from_directory(path, Limits.installed_defaults(),
               providers: %{catalog | attestation: <<>>}
             )

    {:ok, different} = Limits.installed(%{run_duration_ms: 1_000})

    assert {:error, :invalid_installation_catalog} =
             ServingTemplate.from_directory(path, different, providers: catalog)

    assert ServingTemplate.installation_config_digests(template) == pins.installation_config_pins
    refute inspect(template) =~ "builder"
    refute inspect(template.retained) =~ "implementations"
    assert :atomics.get(counts, 1) == 0
  end

  @tag :tmp_dir
  test "assembly and execution failures leave shared providers owned by runtime", %{tmp_dir: dir} do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})

    for {source, failure} <- [
          {~s|(ns app) (defn run {:effect :write :requires ["tool:absent"]} [input] (return input))|,
           :assembly},
          {~s|(ns app) (defn run {:effect :write} [input] (fail {"message" "failed"}))|,
           :execution}
        ] do
      {template, catalog, services, pins, counts} = fixture(dir, source_code: source)

      {:ok, runtime} =
        ProviderRuntime.start_link(template: template, services: services, pins: pins)

      {:ok, execution} = ProviderExecution.new(catalog, services, [])
      deadline = System.monotonic_time(:millisecond) + 10_000
      {:ok, borrow} = ProviderRuntime.borrow(runtime, deadline)
      {:ok, prepared} = call_preparation(template)
      authority = authority()

      retained = %ProviderExecution.Retained{
        execution: execution,
        borrow: borrow,
        plan_identity: borrow.plan_identity
      }

      {:ok, lease} = RunAdmission.reserve(host, deadline)
      {:ok, active} = RunAdmission.activate(lease, prepared, authority, retained)
      result = RunAdmission.await(active)

      case failure do
        :assembly ->
          assert {:error, _failure} = result

        :execution ->
          assert {:ok, outcome} = result
          assert {:ok, %{result: {:error, _}}} = ExecutionOutcome.open(outcome, authority)
      end

      assert :ok = ProviderRuntime.return(borrow)
      assert :atomics.get(counts, 2) == 0
      PublicationAuthority.abort(authority)
      PreparedRun.close(prepared)
      assert :ok = ProviderRuntime.drain(runtime, deadline)
      assert :atomics.get(counts, 2) == 1
      GenServer.stop(runtime)
    end
  end

  @tag :tmp_dir
  test "activation refuses a borrow belonging to another caller", %{tmp_dir: dir} do
    {template, catalog, services, pins, counts} = fixture(dir)

    {:ok, runtime} =
      ProviderRuntime.start_link(template: template, services: services, pins: pins)

    {:ok, execution} = ProviderExecution.new(catalog, services, [])
    deadline = System.monotonic_time(:millisecond) + 10_000
    {:ok, borrow} = ProviderRuntime.borrow(runtime, deadline)
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})

    task =
      Task.async(fn ->
        {:ok, prepared} = call_preparation(template)
        authority = authority()

        retained = %ProviderExecution.Retained{
          execution: execution,
          borrow: borrow,
          plan_identity: borrow.plan_identity
        }

        {:ok, lease} = RunAdmission.reserve(host, deadline)
        result = RunAdmission.activate(lease, prepared, authority, retained)
        PublicationAuthority.abort(authority)
        PreparedRun.close(prepared)
        result
      end)

    assert {:error, :invalid_provider_execution} = Task.await(task)
    assert ProviderRuntime.valid_borrow?(borrow)
    assert :atomics.get(counts, 2) == 0
    assert :ok = ProviderRuntime.return(borrow)
    assert :ok = ProviderRuntime.drain(runtime, deadline)
    assert :atomics.get(counts, 2) == 1
    GenServer.stop(runtime)
  end

  @tag :tmp_dir
  test "registry authority loss permanently refuses new borrows", %{tmp_dir: dir} do
    keys = [:llm_adapter, :host_llm_test_owner]
    previous = Map.new(keys, &{&1, Application.fetch_env(:ptc_runner, &1)})
    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ptc_runner, key, value)
        {key, :error} -> Application.delete_env(:ptc_runner, key)
      end)
    end)

    Enum.each(documents(), fn {name, contents} ->
      File.write!(Path.join(dir, name), contents)
    end)

    host_path = Path.join(dir, "host.json")

    File.write!(
      host_path,
      Jason.encode!(%{
        "credentials" => %{"key" => %{"literal" => "fixture-secret"}},
        "install" => %{
          "selected" => %{
            "source" => "llm",
            "model" => "fixture:model",
            "credential" => "key",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "installation_revision" => "warm-v1"
          }
        }
      })
    )

    {:ok, host} = HostConfig.load(host_path)
    {:ok, catalog} = HostInstallation.catalog(host)
    {:ok, services} = HostInstallation.runtime_services(host)
    on_exit(fn -> InstallationCatalog.close(catalog) end)

    {:ok, template} =
      ServingTemplate.from_directory(
        Path.join(dir, "app.json"),
        Limits.installed_defaults(),
        providers: catalog
      )

    output =
      capture_io(fn ->
        {:ok, discovery} =
          ProviderRuntime.start_link(
            template: template,
            services: services,
            pins: :discover
          )

        GenServer.stop(discovery)
      end)

    discovered = Jason.decode!(output)

    pins = %{
      installation_config_pins: discovered["installation_config_pins"],
      provider_snapshot_pins: discovered["provider_snapshot_pins"]
    }

    {:ok, runtime} =
      ProviderRuntime.start_link(template: template, services: services, pins: pins)

    deadline = System.monotonic_time(:millisecond) + 10_000
    {:ok, borrow} = ProviderRuntime.borrow(runtime, deadline)
    owner = borrow.registry.authority_owner.pid
    monitor = Process.monitor(owner)
    :ok = ProviderRegistry.close(borrow.registry)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}
    assert ProviderRuntime.status(runtime) == {:not_ready, :provider_runtime_lost}
    assert {:error, _} = ProviderRuntime.borrow(runtime, deadline)
    assert :ok = ProviderRuntime.return(borrow)
    assert :ok = ProviderRuntime.drain(runtime, deadline)
    refute ProviderSession.alive?(borrow.session)
    GenServer.stop(runtime)
  end

  @tag :tmp_dir
  test "provider-bearing construction keeps diagnostic details behind closed build codes", %{
    tmp_dir: dir
  } do
    {_template, catalog, _services, _pins, counts} = fixture(dir)
    File.write!(Path.join(dir, "main.clj"), "(ns app) (defn run [input] (")

    assert {:error, :compilation_failed} =
             ServingTemplate.from_directory(
               Path.join(dir, "app.json"),
               Limits.installed_defaults(),
               providers: catalog
             )

    assert :atomics.get(counts, 1) == 0
  end

  @tag :tmp_dir
  test "cancelled callers and dead execution workers retain admission and borrows until guardians drain",
       %{
         tmp_dir: dir
       } do
    parent = self()

    for mode <- [:cancel, :caller_death, :worker_death] do
      {template, catalog, services, pins, counts} =
        fixture(dir,
          source_code:
            ~s|(ns app) (defn run {:effect :write :requires ["tool:llm-request"]} [input] (do (tool/llm-request {}) (return input)))|,
          callback: fn _ ->
            send(parent, {:provider_started, self()})
            receive do: (:finish -> {:ok, %{}})
          end
        )

      {:ok, runtime} =
        ProviderRuntime.start_link(template: template, services: services, pins: pins)

      {:ok, execution} = ProviderExecution.new(catalog, services, [])
      {:ok, host} = RunAdmission.start_link(max_concurrent_runs: 1)
      deadline = System.monotonic_time(:millisecond) + 10_000

      {caller, caller_ref} =
        spawn_monitor(fn ->
          {:ok, borrow} = ProviderRuntime.borrow(runtime, deadline)
          {:ok, prepared} = call_preparation(template)

          retained = %ProviderExecution.Retained{
            execution: execution,
            borrow: borrow,
            plan_identity: borrow.plan_identity
          }

          {:ok, reservation} = RunAdmission.reserve(host, deadline)
          {:ok, active} = RunAdmission.activate(reservation, prepared, authority(), retained)
          send(parent, {:activated, reservation, borrow, elem(active, 2)})

          receive do
            :cancel ->
              RunAdmission.cancel(reservation)
              ProviderRuntime.return(borrow)

            :await ->
              :ok
          end

          RunAdmission.await(active)
          ProviderRuntime.return(borrow)
          receive do: (:finish -> :ok)
        end)

      assert_receive {:activated, _reservation, borrow, owner}
      owner_ref = Process.monitor(ExecutionSessionOwner.pid(owner))
      assert_receive {:provider_started, provider}
      provider_ref = Process.monitor(provider)
      [tracker] = :sys.get_state(borrow.session.session.pid).borrowed_tasks |> Map.values()

      {guardian, guardian_ref} =
        spawn_monitor(fn ->
          receive do
            {:cancel_provider_call, tracker_pid, ref, _deadline} ->
              send(parent, :guardian_draining)
              receive do: (:finish -> :ok)
              send(tracker_pid, {:provider_call_drained, ref, self(), :uncertain})
          end
        end)

      :ok = ProviderTaskTracker.attach_guardian(tracker, guardian)

      case mode do
        :cancel ->
          send(caller, :cancel)

        :caller_death ->
          Process.exit(caller, :kill)

        :worker_death ->
          worker = :sys.get_state(ExecutionSessionOwner.pid(owner)).worker_pid
          Process.exit(worker, :kill)
          send(caller, :await)
      end

      assert_receive :guardian_draining
      assert_receive {:DOWN, ^provider_ref, :process, ^provider, _}
      assert {:ok, %{in_use: 1}} = RunAdmission.snapshot(host)
      drain = Task.async(fn -> ProviderRuntime.drain(runtime, deadline) end)
      assert Task.yield(drain, 20) == nil
      assert :atomics.get(counts, 2) == 0
      send(guardian, :finish)
      assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, :normal}
      assert :ok = Task.await(drain)
      assert_receive {:DOWN, ^owner_ref, :process, _, :normal}
      assert :atomics.get(counts, 2) == 1
      if mode != :caller_death, do: send(caller, :finish)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, _}
      assert {:ok, %{in_use: 0, status: :unavailable}} = RunAdmission.snapshot(host)
      GenServer.stop(host)
      GenServer.stop(runtime)
    end
  end

  defp call_preparation(template) do
    with {:ok, input} <-
           ExecutionInput.new(%{}, :normal, template.package.contracts.input),
         {:ok, policy} <- ExecutionPolicy.new(result_projection: :json),
         {:ok, request} <- RunRequest.new(template.package, input, policy) do
      ServingTemplate.prepare_call(template, request)
    end
  end

  defp acquisition_calls(calls) do
    receive do
      {:trace, _pid, :call, {ProviderAcquisition, :acquire, _args} = call} ->
        acquisition_calls([call | calls])
    after
      0 -> calls
    end
  end

  defp authority do
    {:ok, authority} = PublicationAuthority.new([])
    authority
  end

  defp start_warm(template, services, pins, admission) do
    WarmProviderRuntime.start_link(
      tools: %{"tool" => %{template: template, pins: pins}},
      services: services,
      bearer_binding: "bearer",
      run_admission: admission,
      max_active_provider_calls: 1,
      max_waiting_provider_calls: 0
    )
  end

  defp fixture(dir, opts \\ []) do
    counts = :atomics.new(3, signed: false)
    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    {:ok, descriptor} =
      ProviderDescriptor.new(
        source: Keyword.get(opts, :source, :llm),
        installation_revision: "warm-v1",
        credential_names: [],
        authorization_mode: :none,
        data_class: :normal,
        accepts_data: [:normal],
        requires: [],
        provides: [],
        destinations: [:workflow],
        workflow_llm?: true,
        connectivity_mode: if(Keyword.get(opts, :source, :llm) == :llm, do: :probe, else: :none),
        probe_effect: if(Keyword.get(opts, :source, :llm) == :llm, do: :metadata),
        selection_validation: :declarative,
        selection_rules: rules,
        authority_fingerprint: nil,
        local_preflight: :none
      )

    {:ok, capability} =
      Capability.new(
        name: "llm-request",
        input_schema: %{"type" => "object"},
        llm_reservation: %{
          source: "llm",
          output_tokens: 100,
          tariff: nil,
          bound: fn _, _ -> {:ok, %{total_tokens: 100, cost: nil}} end
        },
        callback:
          Keyword.get(opts, :callback, fn _ ->
            :atomics.add(counts, 3, 1)
            {:ok, %{}}
          end)
      )

    {:ok, snapshot} =
      ProviderSnapshot.build(descriptor, "selected", %{}, %{
        "source" => "llm",
        "resolved_model" => "fixture/model"
      })

    builder = fn _, _ ->
      {:ok,
       %{
         credential_names: [],
         workflow_llm?: true,
         workflow_llm_route:
           %{
             source: Atom.to_string(descriptor.source),
             installation_revision: descriptor.installation_revision,
             default: false,
             structured_output_mode: descriptor.structured_output_mode,
             usage_guarantees: descriptor.usage_guarantees,
             reservation_tariff: descriptor.reservation_tariff,
             request_timeout_ms: descriptor.request_timeout_ms
           }
           |> Enum.reject(fn {key, value} ->
             is_nil(value) and not (key == :reservation_tariff and descriptor.source == :llm)
           end)
           |> Map.new(),
         preflight: fn ->
           {:ok,
            fn _ ->
              :atomics.add(counts, 1, 1)

              {:ok,
               %{
                 capabilities: [capability],
                 snapshot: if(Keyword.get(opts, :snapshot, true), do: snapshot),
                 close: fn ->
                   :atomics.add(counts, 2, 1)
                   :ok
                 end
               }}
            end}
         end
       }}
    end

    digest = "sha256:" <> String.duplicate("a", 64)

    {:ok, services} = ProviderRuntimeServices.new()

    {:ok, catalog} =
      InstallationCatalog.new(
        %{
          "selected" => %{
            descriptor: descriptor,
            implementation:
              if(Keyword.get(opts, :source, :llm) == :llm,
                do: %{builder: builder, connectivity_probe: fn _, _, _ -> {:ok, %{}} end},
                else: %{builder: builder}
              )
              |> then(fn implementation ->
                if app = Keyword.get(opts, :provider_application),
                  do: Map.put(implementation, :provider_application, app),
                  else: implementation
              end),
            authority: nil
          }
        },
        installation_config_digests:
          if(Keyword.get(opts, :config_digest, true), do: %{"selected" => digest}, else: %{}),
        runtime_binding: services.runtime_binding
      )

    Enum.each(
      Map.put(documents(), "main.clj", Keyword.get(opts, :source_code, documents()["main.clj"])),
      fn {name, contents} -> File.write!(Path.join(dir, name), contents) end
    )

    {:ok, template} =
      ServingTemplate.from_directory(Path.join(dir, "app.json"), Limits.installed_defaults(),
        providers: catalog
      )

    pins = %{
      installation_config_pins: %{"selected" => digest},
      provider_snapshot_pins: %{
        "workflow/selected" => "sha256:" <> snapshot["acquisition_identity_hash"]
      }
    }

    {template, catalog, services, pins, counts}
  end

  defp documents do
    schema = %{"type" => "object", "additionalProperties" => false}

    %{
      "app.json" =>
        Jason.encode!(%{
          "version" => 1,
          "workflow" => %{
            "components" => [%{"id" => "app", "path" => "main.clj"}],
            "entry" => "app/run"
          },
          "input" => %{"value" => %{}},
          "providers" => %{"workflow" => [%{"name" => "selected", "config" => %{}}]},
          "contracts" => %{
            "input_schema" => %{"path" => "schema.json"},
            "result_schema" => %{"path" => "schema.json"}
          }
        }),
      "schema.json" => Jason.encode!(schema),
      "main.clj" => "(ns app) (defn run {:effect :read} [input] (return input))"
    }
  end
end
