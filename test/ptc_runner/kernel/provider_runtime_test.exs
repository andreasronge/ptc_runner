defmodule PtcRunner.Kernel.ProviderRuntimeTest do
  use ExUnit.Case, async: false

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  import ExUnit.CaptureIO

  alias PtcRunner.Kernel.{
    Capability,
    ExecutionInput,
    ExecutionOutcome,
    ExecutionPolicy,
    HostConfig,
    HostInstallation,
    InstallationCatalog,
    Limits,
    PreparedRun,
    ProviderAcquisition,
    ProviderDescriptor,
    ProviderExecution,
    ProviderRegistry,
    ProviderRuntime,
    ProviderRuntimeServices,
    ProviderSession,
    ProviderSnapshot,
    PublicationAuthority,
    RunAdmission,
    RunBuilder,
    RunConfig,
    RunRequest,
    SelectionRules,
    ServingTemplate
  }

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
        callback: fn _ ->
          :atomics.add(counts, 3, 1)
          {:ok, %{}}
        end
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
              ),
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
