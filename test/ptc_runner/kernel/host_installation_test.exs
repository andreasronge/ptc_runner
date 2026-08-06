defmodule PtcRunner.Kernel.HostInstallationTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.HostInstallationOwner
  alias PtcRunner.Kernel.HostRuntimePayload
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderCallbackBoundary
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.SelectionRules

  @tag :tmp_dir
  test "installs only declared aliases and enforces MCP mission placement", %{tmp_dir: dir} do
    host = load_host(dir, http_config())

    assert {:ok, registry} =
             HostInstallation.catalog(host)
             |> then(fn {:ok, catalog} ->
               HostInstallation.runtime_registry(host, catalog)
             end)

    context = context(dir, :mission)

    assert {:ok, prepared} =
             ProviderRegistry.prepare(registry, "remote", %{}, context)

    assert prepared.credential_names == ["token"]

    assert {:error, :provider_destination_denied} =
             ProviderRegistry.prepare(registry, "remote", %{}, %{context | destination: :workflow})

    assert {:error, :unknown_provider} =
             ProviderRegistry.prepare(registry, "llm", %{}, %{
               context
               | destination: :workflow
             })
  end

  @tag :tmp_dir
  test "catalog construction is process-free and excludes host-private values", %{tmp_dir: dir} do
    host = load_host(dir, http_config())
    owners_before = host_installation_owners()
    assert {:ok, catalog} = HostInstallation.catalog(host)
    serialized_catalog = :erlang.term_to_binary(catalog)

    assert host_installation_owners() == owners_before
    refute Map.has_key?(catalog, :owner)
    refute Map.has_key?(catalog, :credential_resolver)
    refute serialized_catalog =~ dir
    refute serialized_catalog =~ host.path
    refute serialized_catalog =~ "test-secret"
    refute serialized_catalog =~ "https://example.test/mcp"

    assert {:ok, runtime_services} = HostInstallation.runtime_services(host)
    serialized_services = :erlang.term_to_binary(runtime_services)
    refute serialized_services =~ dir
    refute serialized_services =~ "test-secret"
    refute serialized_services =~ "https://example.test/mcp"

    assert {:error, :invalid_provider_runtime_services} =
             ProviderRuntimeServices.host_call(
               runtime_services,
               catalog.runtime_binding,
               :oauth_authorities
             )

    assert {:error, :invalid_host_runtime_payload} =
             HostRuntimePayload.invoke(runtime_services.host_payload, :oauth_authorities)

    assert {:ok, registry} =
             InstallationCatalog.runtime_registry(catalog, runtime_services)

    owner_pid = registry.authority_owner.pid
    assert Process.alive?(owner_pid)

    assert {:ok, prepared} =
             ProviderRegistry.prepare(registry, "remote", %{}, context(dir, :mission))

    assert {:ok, preflighted} = ProviderRegistry.preflight(prepared)

    for callback <- [prepared.preflight, preflighted.acquire] do
      {:env, environment} = :erlang.fun_info(callback, :env)
      captured = :erlang.term_to_binary(environment)

      refute captured =~ "test-secret"
    end

    assert :ok = ProviderRegistry.close(registry)
    refute Process.alive?(owner_pid)

    assert {:error, :provider_prepare_failed} =
             ProviderRegistry.prepare(registry, "remote", %{}, context(dir, :mission))

    assert {:error, :credential_resolution_failed} =
             ProviderRegistry.resolve_credentials(registry, ["token"])
  end

  @tag :tmp_dir
  test "an expired operation deadline never activates the host payload", %{tmp_dir: dir} do
    host = load_host(dir, http_config())
    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, services} = HostInstallation.runtime_services(host)
    parent = self()
    activation = services.activation

    # Comparing owners after the call cannot separate "never started" from
    # "started and then released"; only the first is correct once the deadline
    # has already expired, so the activation itself reports whether it ran.
    observed = fn ->
      send(parent, :activated)
      activation.()
    end

    services = replace_activation(services, observed)
    owners_before = host_installation_owners()
    expired = Deadline.from_expires_at(System.monotonic_time(:millisecond) - 1)

    assert {:error, :operation_deadline_expired} =
             InstallationCatalog.runtime_registry(catalog, services, ["remote"], expired, self())

    refute_received :activated
    assert host_installation_owners() == owners_before
  end

  @tag :tmp_dir
  test "an operation expiring during activation releases the started authority", %{tmp_dir: dir} do
    host = load_host(dir, http_config())
    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, services} = HostInstallation.runtime_services(host)
    parent = self()
    deadline = Deadline.new(50)
    activation = services.activation

    # Host-bound activation is a synchronous bootstrap exception, so the bound
    # on a slow one is that its authority is released rather than handed to a
    # registry. Publishing the real authority first lets the test name the
    # exact owner and lease that must not survive the expired operation.
    delayed = fn ->
      result = activation.()
      send(parent, {:activated, result})
      wait_until_expired(deadline)
      result
    end

    services = replace_activation(services, delayed)

    assert {:error, :operation_deadline_expired} =
             InstallationCatalog.runtime_registry(catalog, services, ["remote"], deadline, self())

    assert_received {:activated, {:ok, authority}}
    refute Process.alive?(authority.pid)
    refute Process.alive?(authority.lease_owner)
  end

  @tag :tmp_dir
  test "host-backed credential resolution runs outside the authority owner", %{tmp_dir: dir} do
    parent = self()
    host = load_host(dir, http_config())
    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, services} = HostInstallation.runtime_services(host)

    resolver = fn ["token"] ->
      send(parent, {:host_credential_resolver, self()})
      {:ok, %{"token" => "test-secret"}}
    end

    services = replace_credential_resolver(services, resolver)
    assert {:ok, registry} = InstallationCatalog.runtime_registry(catalog, services)

    owner_pid = registry.authority_owner.pid

    assert {:ok, %{"token" => "test-secret"}} =
             ProviderRegistry.resolve_credentials(registry, ["token"])

    assert_receive {:host_credential_resolver, resolver_pid}
    assert resolver_pid == self()
    refute resolver_pid == owner_pid
    lease_table = registry.authority_owner.lease_table
    assert :ok = ProviderRegistry.close(registry)
    assert :undefined = :ets.info(lease_table)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "installed provider callbacks are killed with their active deadline", %{tmp_dir: dir} do
    host = load_host(dir, http_config())
    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, services} = HostInstallation.runtime_services(host)
    assert {:ok, registry} = InstallationCatalog.runtime_registry(catalog, services)

    authority_owner = registry.authority_owner.pid

    :sys.replace_state(authority_owner, fn state ->
      Process.flag(:priority, :low)
      state
    end)

    limits = %{Limits.installed_defaults() | run_duration_ms: 500}
    assert {:ok, session} = ProviderSession.start_active(limits, "installed-deadline-boundary")
    assert {:ok, session} = ProviderSession.begin_operation(session, session.run_duration_ms)
    deadline = ProviderSession.run_deadline(session)

    active_context =
      context(dir, :mission)
      |> Map.merge(%{
        deadline: deadline,
        deadline_ms: Deadline.expires_at(deadline),
        limits: limits,
        installed_limits: limits
      })

    assert {:ok, prepared} = ProviderRegistry.prepare(registry, "remote", %{}, active_context)
    assert {:ok, preflighted} = ProviderRegistry.preflight(prepared)

    assert {:ok, credentials} =
             ProviderRegistry.resolve_credentials(registry, prepared.credential_names)

    assert 1 = :erlang.trace(authority_owner, true, [:procs, :set_on_spawn, {:tracer, self()}])
    parent = self()
    occurrence = %{provider: "remote", destination: :mission, index: 0}

    caller =
      spawn(fn ->
        result =
          ProviderCallbackBoundary.invoke(
            session,
            limits.provider_heap_words,
            occurrence,
            fn -> ProviderRegistry.acquire(preflighted, credentials) end
          )

        send(parent, {:installed_callback_result, result})
      end)

    caller_ref = Process.monitor(caller)

    try do
      assert_receive {:trace, ^authority_owner, :spawn, callback_worker, _spawned}
      callback_ref = Process.monitor(callback_worker)
      assert true = :erlang.suspend_process(callback_worker)

      assert_receive {:DOWN, ^callback_ref, :process, ^callback_worker, :killed}, 1_000

      assert_receive {:installed_callback_result,
                      {:error,
                       %CommandDiagnostic{
                         phase: :provider_acquisition,
                         code: :provider_unavailable
                       }}}

      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    after
      :erlang.trace(authority_owner, false, [:all])
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      ProviderSession.close(session)
      ProviderRegistry.close(registry)
    end
  end

  test "nested active callback heap failures remain closed diagnostics" do
    limits = Limits.installed_defaults()
    assert {:ok, session} = ProviderSession.start_active(limits, "nested-heap-boundary")
    assert {:ok, session} = ProviderSession.begin_operation(session, session.run_duration_ms)

    occurrence = %{provider: "remote", destination: :mission, index: 0}

    assert {:error,
            %CommandDiagnostic{
              phase: :provider_acquisition,
              code: :provider_unavailable,
              subject: %{name: "remote", operation: :acquisition}
            }} =
             ProviderCallbackBoundary.invoke(
               session,
               limits.provider_heap_words,
               occurrence,
               fn -> ProviderCallbackBoundary.nested_failure(:heap_exceeded) end
             )

    assert :ok = ProviderSession.close(session)
  end

  @tag :tmp_dir
  test "registry close cannot race a completed credential result past lease release", %{
    tmp_dir: dir
  } do
    parent = self()
    host = load_host(dir, http_config())
    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, services} = HostInstallation.runtime_services(host)

    resolver = fn ["token"] ->
      send(parent, {:lease_release_race_started, self()})
      receive do: (:finish -> {:ok, %{"token" => "test-secret"}})
    end

    services = replace_credential_resolver(services, resolver)
    assert {:ok, registry} = InstallationCatalog.runtime_registry(catalog, services)

    caller =
      spawn(fn ->
        result = ProviderRegistry.resolve_credentials(registry, ["token"])
        send(parent, {:lease_release_race_result, result})
      end)

    caller_ref = Process.monitor(caller)
    lease_owner = registry.authority_owner.lease_owner
    lease_fence = registry.authority_owner.lease_fence

    try do
      assert_receive {:lease_release_race_started, ^caller}
      assert true = :erlang.suspend_process(lease_owner)

      closer =
        spawn(fn ->
          result = ProviderRegistry.close(registry)
          send(parent, {:lease_release_race_close, result})
        end)

      assert_eventually(fn -> :atomics.get(lease_fence, 1) == 0 end)
      send(caller, :finish)

      refute_receive {:lease_release_race_result, _result}, 100
      :erlang.resume_process(lease_owner)

      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 2_000
      assert_receive {:lease_release_race_close, :ok}, 2_000
      refute_receive {:lease_release_race_result, _result}

      if Process.alive?(closer), do: Process.exit(closer, :kill)
    after
      if Process.alive?(lease_owner), do: :erlang.resume_process(lease_owner)
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      ProviderRegistry.close(registry)
    end
  end

  @tag :tmp_dir
  test "an unacknowledged credential lease release terminates without returning", %{tmp_dir: dir} do
    parent = self()
    host = load_host(dir, http_config())
    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, services} = HostInstallation.runtime_services(host)

    resolver = fn ["token"] ->
      send(parent, {:lease_release_timeout_started, self()})
      receive do: (:finish -> {:ok, %{"token" => "test-secret"}})
    end

    services = replace_credential_resolver(services, resolver)
    assert {:ok, registry} = InstallationCatalog.runtime_registry(catalog, services)

    caller =
      spawn(fn ->
        result = ProviderRegistry.resolve_credentials(registry, ["token"])
        send(parent, {:lease_release_timeout_result, result})
      end)

    caller_ref = Process.monitor(caller)
    lease_owner = registry.authority_owner.lease_owner

    try do
      assert_receive {:lease_release_timeout_started, ^caller}
      assert true = :erlang.suspend_process(lease_owner)
      send(caller, :finish)

      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 2_000
      refute_receive {:lease_release_timeout_result, _result}
    after
      if Process.alive?(lease_owner), do: :erlang.resume_process(lease_owner)
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      ProviderRegistry.close(registry)
    end
  end

  @tag :tmp_dir
  test "registry close cancels in-flight host-backed credential resolution", %{tmp_dir: dir} do
    parent = self()
    host = load_host(dir, http_config())
    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, services} = HostInstallation.runtime_services(host)

    resolver = fn ["token"] ->
      Process.flag(:trap_exit, true)
      send(parent, {:host_credential_resolution_started, self()})

      receive do
        {:EXIT, _lease_owner, _reason} ->
          send(parent, :host_credential_resolution_survived_link_exit)
          {:ok, %{"token" => "test-secret"}}
      end
    end

    services = replace_credential_resolver(services, resolver)
    assert {:ok, registry} = InstallationCatalog.runtime_registry(catalog, services)

    caller =
      spawn(fn ->
        result = ProviderRegistry.resolve_credentials(registry, ["token"])
        send(parent, {:host_credential_resolution_result, result})
      end)

    caller_ref = Process.monitor(caller)
    authority_owner = registry.authority_owner.pid
    lease_owner = registry.authority_owner.lease_owner

    try do
      assert_receive {:host_credential_resolution_started, ^caller}
      assert true = :erlang.suspend_process(authority_owner)
      assert true = :erlang.suspend_process(lease_owner)
      assert :ok = ProviderRegistry.close(registry)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
      refute_receive {:host_credential_resolution_result, _result}
      refute_receive :host_credential_resolution_survived_link_exit
    after
      if Process.alive?(authority_owner), do: :erlang.resume_process(authority_owner)
      if Process.alive?(lease_owner), do: :erlang.resume_process(lease_owner)
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      ProviderRegistry.close(registry)
    end
  end

  @tag :tmp_dir
  test "registry creator death drains credential resolution and its lease table", %{tmp_dir: dir} do
    parent = self()
    host = load_host(dir, http_config())
    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, services} = HostInstallation.runtime_services(host)

    resolver = fn ["token"] ->
      Process.flag(:trap_exit, true)
      send(parent, {:creator_death_credential_started, self()})
      receive do: ({:EXIT, _lease_owner, _reason} -> {:ok, %{"token" => "test-secret"}})
    end

    services = replace_credential_resolver(services, resolver)

    creator =
      spawn(fn ->
        {:ok, registry} = InstallationCatalog.runtime_registry(catalog, services)
        send(parent, {:creator_death_registry, registry})
        receive do: (:never -> :ok)
      end)

    creator_ref = Process.monitor(creator)
    assert_receive {:creator_death_registry, registry}

    caller =
      spawn(fn ->
        result = ProviderRegistry.resolve_credentials(registry, ["token"])
        send(parent, {:creator_death_credential_result, result})
      end)

    caller_ref = Process.monitor(caller)
    authority_ref = Process.monitor(registry.authority_owner.pid)
    lease_ref = Process.monitor(registry.authority_owner.lease_owner)
    lease_table = registry.authority_owner.lease_table

    assert_receive {:creator_death_credential_started, ^caller}
    Process.exit(creator, :kill)

    assert_receive {:DOWN, ^creator_ref, :process, ^creator, :killed}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
    assert_receive {:DOWN, ^authority_ref, :process, _, :normal}
    assert_receive {:DOWN, ^lease_ref, :process, _, :normal}
    assert :undefined = :ets.info(lease_table)
    refute_receive {:creator_death_credential_result, _result}
  end

  @tag :tmp_dir
  test "a registry opened for another owner outlives the process that opened it", %{tmp_dir: dir} do
    # Activation runs in a disposable worker while the registry it produces is
    # tracked and closed by a longer-lived lifecycle owner. Binding the
    # authority to the worker would revoke it the moment that worker is
    # terminated, before the resources acquired through it can be closed.
    parent = self()
    host = load_host(dir, http_config())
    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, services} = HostInstallation.runtime_services(host)

    services =
      replace_credential_resolver(services, fn ["token"] -> {:ok, %{"token" => "test-secret"}} end)

    lifecycle_owner = spawn(fn -> receive do: (:never -> :ok) end)

    on_exit(fn ->
      if Process.alive?(lifecycle_owner), do: Process.exit(lifecycle_owner, :kill)
    end)

    worker =
      spawn(fn ->
        result =
          InstallationCatalog.runtime_registry(
            catalog,
            services,
            ["remote"],
            Deadline.new(5_000),
            lifecycle_owner
          )

        send(parent, {:worker_registry, result})
        receive do: (:never -> :ok)
      end)

    worker_ref = Process.monitor(worker)
    assert_receive {:worker_registry, {:ok, registry}}
    authority_ref = Process.monitor(registry.authority_owner.pid)

    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}

    # The authority survives its opener, so the registry still works...
    assert {:ok, %{"token" => "test-secret"}} =
             ProviderRegistry.resolve_credentials(registry, ["token"])

    # ...and it is the lifecycle owner it now follows.
    Process.exit(lifecycle_owner, :kill)
    assert_receive {:DOWN, ^authority_ref, :process, _pid, :normal}, 5_000
  end

  @tag :tmp_dir
  test "catalog recipes exclude every installation payload", %{tmp_dir: dir} do
    config =
      http_config()
      |> put_in(["install"], %{
        "alpha" =>
          http_config()["install"]["remote"]
          |> put_in(["transport", "endpoint"], "https://alpha.example/only-alpha"),
        "beta" =>
          http_config()["install"]["remote"]
          |> put_in(["transport", "endpoint"], "https://beta.example/only-beta")
      })

    host = load_host(dir, config)
    assert {:ok, catalog} = HostInstallation.catalog(host)

    serialized_catalog = :erlang.term_to_binary(catalog)

    refute serialized_catalog =~ dir
    refute serialized_catalog =~ "only-alpha"
    refute serialized_catalog =~ "only-beta"
  end

  @tag :tmp_dir
  test "runtime services cannot activate a catalog from another host", %{tmp_dir: dir} do
    host_a = load_host(Path.join(dir, "a"), http_config())

    host_b =
      http_config()
      |> put_in(["credentials", "token", "literal"], "different-secret")
      |> put_in(["install", "remote", "installation_revision"], "remote-v2")
      |> put_in(
        ["install", "remote", "transport", "endpoint"],
        "https://different.example/mcp"
      )
      |> then(&load_host(Path.join(dir, "b"), &1))

    assert {:ok, catalog_a} = HostInstallation.catalog(host_a)
    assert {:ok, services_b} = HostInstallation.runtime_services(host_b)
    refute catalog_a.runtime_binding == services_b.runtime_binding

    owners_before = host_installation_owners()

    assert {:error, :invalid_provider_registry} =
             InstallationCatalog.runtime_registry(catalog_a, services_b)

    assert host_installation_owners() == owners_before
  end

  @tag :tmp_dir
  test "a copied host binding cannot forge ownerless runtime services", %{tmp_dir: dir} do
    host = load_host(dir, http_config())
    assert {:ok, catalog} = HostInstallation.catalog(host)

    assert {:error, :invalid_provider_runtime_services} =
             ProviderRuntimeServices.new(runtime_binding: catalog.runtime_binding)

    assert {:ok, generic_services} = ProviderRuntimeServices.new()

    forged_services = %{generic_services | runtime_binding: catalog.runtime_binding}

    refute ProviderRuntimeServices.valid?(forged_services)
    owners_before = host_installation_owners()

    assert {:error, :invalid_provider_registry} =
             InstallationCatalog.runtime_registry(catalog, forged_services)

    assert host_installation_owners() == owners_before
  end

  @tag :tmp_dir
  test "connectivity probes reject runtime services from another host", %{tmp_dir: dir} do
    previous_adapter = Application.get_env(:ptc_runner, :llm_adapter)
    previous_owner = Application.get_env(:ptc_runner, :host_llm_test_owner)
    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())

    on_exit(fn ->
      restore_env(:llm_adapter, previous_adapter)
      restore_env(:host_llm_test_owner, previous_owner)
    end)

    live_config = %{
      "credentials" => %{"key" => %{"literal" => "host-a-secret"}},
      "install" => %{
        "live" => %{
          "source" => "llm",
          "installation_revision" => "live-v1",
          "model" => "openrouter:deepseek/deepseek-v4-flash",
          "credential" => "key"
        }
      }
    }

    host_a = load_host(Path.join(dir, "a"), live_config)

    host_b =
      live_config
      |> put_in(["credentials", "key", "literal"], "host-b-secret")
      |> then(&load_host(Path.join(dir, "b"), &1))

    assert {:ok, catalog_a} = HostInstallation.catalog(host_a)
    assert {:ok, services_b} = HostInstallation.runtime_services(host_b)
    descriptor = catalog_a.descriptors["live"]
    implementation = catalog_a.implementations["live"]
    probe_context = context(dir, :workflow)

    assert {:ok, selection} =
             SelectionRules.normalize(descriptor.selection_rules, %{}, probe_context.limits)

    assert {:error, :invalid_provider_runtime_services} =
             implementation.connectivity_probe.(selection, probe_context, services_b)

    refute_receive {:host_llm_request, _, _}
  end

  @tag :tmp_dir
  test "runtime activation releases a returned malformed host authority", %{tmp_dir: dir} do
    host = load_host(dir, http_config())
    test_process = self()

    activation = fn ->
      {:ok, authority} = HostInstallationOwner.start(host)
      send(test_process, {:activation_owner, authority.pid})
      {:ok, %{authority | attestation: <<>>}}
    end

    assert {:ok, services} = ProviderRuntimeServices.new(activation: activation)

    assert {:error, :invalid_provider_runtime_services} =
             ProviderRuntimeServices.activate(services)

    assert_receive {:activation_owner, owner_pid}
    refute Process.alive?(owner_pid)
  end

  test "normalized preflight release runs at most once across overlapping cleanup paths" do
    releases = :atomics.new(1, signed: false)
    :ok = :atomics.put(releases, 1, 0)

    prepared = %{
      credential_names: [],
      data_class: :normal,
      accepts_data: [:normal],
      requires: [],
      provides: [],
      workflow_llm?: false,
      preflight: fn ->
        {:ok, fn %{} -> {:error, :fixture_acquisition_failed} end,
         fn ->
           :atomics.add(releases, 1, 1)
           :ok
         end}
      end
    }

    assert {:ok, preflighted} = ProviderRegistry.preflight(prepared)

    assert {:error, :fixture_acquisition_failed} =
             ProviderRegistry.acquire(preflighted, %{})

    assert :ok = ProviderRegistry.release_preflight(preflighted)
    assert :ok = ProviderRegistry.release_preflight(preflighted)
    assert :atomics.get(releases, 1) == 1
  end

  @tag :tmp_dir
  test "installed host ceilings reach manifest loading through the registry", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "main.clj"), "(ns main) (defn run [_] (return 1))")

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}},
      "limits" => %{"subordinate_evaluations" => 24}
    }

    manifest_path = Path.join(dir, "manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest))

    config =
      http_config()
      |> Map.put("limits", %{"subordinate_evaluations" => 24})

    host = load_host(dir, config)

    assert {:ok, registry} =
             HostInstallation.catalog(host)
             |> then(fn {:ok, catalog} ->
               HostInstallation.runtime_registry(host, catalog)
             end)

    assert {:ok, built} = RunBuilder.load_and_build(manifest_path, registry)
    assert built.config.limits.subordinate_evaluations == 24
    assert :ok = RunBuilder.close(built.config)
  end

  @tag :tmp_dir
  test "rejects an invalid LLM model during preflight before reading its credential", %{
    tmp_dir: dir
  } do
    config = %{
      "credentials" => %{
        "missing_key" => %{"env" => "DEFINITELY_MISSING_PTC_LLM_KEY"}
      },
      "install" => %{
        "invalid-model" => %{
          "source" => "llm",
          "installation_revision" => "invalid-model-v1",
          "model" => "definitely-not-a-model",
          "credential" => "missing_key"
        }
      }
    }

    host = load_host(dir, config)

    assert_local_preflight_parity(
      host,
      "invalid-model",
      :workflow,
      {:error, :invalid_llm_model}
    )
  end

  @tag :tmp_dir
  test "audited local preflight matches missing LLM adapters and stdio runtime files", %{
    tmp_dir: dir
  } do
    previous_adapter = Application.get_env(:ptc_runner, :llm_adapter)
    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.MissingLLMAdapter)

    on_exit(fn -> restore_env(:llm_adapter, previous_adapter) end)

    llm_host =
      load_host(dir, %{
        "credentials" => %{"key" => %{"literal" => "not-read"}},
        "install" => %{
          "live" => %{
            "source" => "llm",
            "installation_revision" => "live-v1",
            "model" => "openrouter:deepseek/deepseek-v4-flash",
            "credential" => "key"
          }
        }
      })

    assert_local_preflight_parity(llm_host, "live", :workflow, {:error, :invalid_llm_model})

    missing_executable_host =
      stdio_config("/definitely/missing-ptc-server")
      |> put_in(["runtime", "stdio_launcher"], System.find_executable("sh"))
      |> then(&load_host(Path.join(dir, "missing-executable"), &1))

    assert_local_preflight_parity(
      missing_executable_host,
      "workspace",
      :mission,
      {:error, :invalid_mcp_executable}
    )

    missing_launcher_host =
      stdio_config(System.find_executable("sh"))
      |> put_in(["runtime", "stdio_launcher"], "/definitely/missing-ptc-launcher")
      |> then(&load_host(Path.join(dir, "missing-launcher"), &1))

    assert_local_preflight_parity(
      missing_launcher_host,
      "workspace",
      :mission,
      {:error, :mcp_stdio_launcher_unavailable}
    )
  end

  @tag :tmp_dir
  test "installs live LLM aliases only in workflow with explicit credential and safe identity", %{
    tmp_dir: dir
  } do
    previous_adapter = Application.get_env(:ptc_runner, :llm_adapter)
    previous_owner = Application.get_env(:ptc_runner, :host_llm_test_owner)
    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())

    on_exit(fn ->
      restore_env(:llm_adapter, previous_adapter)
      restore_env(:host_llm_test_owner, previous_owner)
    end)

    config = %{
      "credentials" => %{"openrouter_key" => %{"literal" => "test-llm-secret"}},
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "model" => "openrouter:deepseek/deepseek-v4-flash",
          "credential" => "openrouter_key",
          "params" => %{"temperature" => 0.15, "seed" => 73, "max_tokens" => 2_048},
          "installation_revision" => "model-policy-v2",
          "accepts_data" => ["normal", "private_inspection"],
          "ceilings" => %{
            "max_request_bytes" => 200_000,
            "max_response_bytes" => 300_000
          }
        }
      }
    }

    host = load_host(dir, config)

    assert {:ok, registry} =
             HostInstallation.catalog(host)
             |> then(fn {:ok, catalog} ->
               HostInstallation.runtime_registry(host, catalog)
             end)

    workflow = context(dir, :workflow)

    assert {:ok, prepared} =
             ProviderRegistry.prepare(
               registry,
               "deepseek",
               %{"max_request_bytes" => 100_000},
               workflow
             )

    assert prepared.credential_names == ["openrouter_key"]

    assert {:error, :provider_destination_denied} =
             ProviderRegistry.prepare(registry, "deepseek", %{}, %{
               workflow
               | destination: :mission
             })

    assert {:error, :invalid_llm_selection} =
             ProviderRegistry.prepare(
               registry,
               "deepseek",
               %{"max_response_bytes" => 300_001},
               workflow
             )

    assert {:ok, preflighted} = ProviderRegistry.preflight(prepared)

    assert {:ok, credentials} =
             ProviderRegistry.resolve_credentials(registry, prepared.credential_names)

    assert credentials == %{"openrouter_key" => "test-llm-secret"}
    assert {:ok, built} = ProviderRegistry.acquire(preflighted, credentials)

    assert [%{name: "llm-request"} = capability] = built.capabilities
    assert built.accepts_data == [:normal, :private_inspection]
    assert built.data_class == :normal
    assert built.snapshot["provider"] == "deepseek"
    assert built.snapshot["acquisition"] == %{"source" => "llm"}

    assert built.snapshot["declaration"] == %{
             "name" => "deepseek",
             "source" => "llm",
             "installation_revision" => "model-policy-v2",
             "data_class" => "normal",
             "accepts_data" => ["normal", "private_inspection"],
             "authorization_mode" => "none",
             "config" => %{
               "max_request_bytes" => 100_000,
               "max_response_bytes" => 300_000
             }
           }

    assert built.snapshot["acquisition_identity_hash"] =~ ~r/\A[0-9a-f]{64}\z/
    assert built.snapshot["snapshot_hash"] =~ ~r/\A[0-9a-f]{64}\z/
    refute inspect(built.snapshot) =~ "openrouter"
    refute inspect(built.snapshot) =~ "test-llm-secret"

    assert {:ok, response} =
             capability.callback.(%{
               "messages" => [%{"role" => "user", "content" => "hello"}],
               "cache" => true
             })

    assert response["content"] == "ok"

    assert_receive {:host_llm_request, "openrouter:deepseek/deepseek-v4-flash", request}
    assert request.api_key == "test-llm-secret"
    assert request.cache == false
    assert request.temperature == 0.15
    assert request.seed == 73
    assert request.max_tokens == 2_048
  end

  @tag :tmp_dir
  test "live LLM connectivity probe makes exactly one bounded completion request", %{
    tmp_dir: dir
  } do
    previous_adapter = Application.get_env(:ptc_runner, :llm_adapter)
    previous_owner = Application.get_env(:ptc_runner, :host_llm_test_owner)
    previous_result = Application.get_env(:ptc_runner, :host_llm_test_result)
    previous_warm_words = Application.get_env(:ptc_runner, :host_llm_test_warm_words)
    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())
    Application.put_env(:ptc_runner, :host_llm_test_warm_words, 100_000)

    on_exit(fn ->
      restore_env(:llm_adapter, previous_adapter)
      restore_env(:host_llm_test_owner, previous_owner)
      restore_env(:host_llm_test_result, previous_result)
      restore_env(:host_llm_test_warm_words, previous_warm_words)
    end)

    host =
      load_host(dir, %{
        "credentials" => %{"key" => %{"literal" => "probe-secret"}},
        "install" => %{
          "live" => %{
            "source" => "llm",
            "installation_revision" => "live-v1",
            "model" => "openrouter:deepseek/deepseek-v4-flash",
            "credential" => "key",
            "params" => %{"max_tokens" => 99}
          }
        }
      })

    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, runtime_services} = HostInstallation.runtime_services(host)
    descriptor = catalog.descriptors["live"]
    implementation = catalog.implementations["live"]

    probe_context =
      dir
      |> context(:workflow)
      |> update_in([:limits], &Map.put(&1, :provider_heap_words, 20_000))

    assert is_binary(catalog.runtime_binding)
    assert descriptor.local_preflight == :audited_local
    assert descriptor.connectivity_mode == :probe
    assert descriptor.probe_effect == :completion
    assert is_function(implementation.local_preflight, 3)
    assert is_function(implementation.connectivity_probe, 3)

    assert {:ok, selection} =
             SelectionRules.normalize(descriptor.selection_rules, %{}, probe_context.limits)

    assert :ok =
             implementation.local_preflight.(selection, probe_context, runtime_services)

    assert :ok = implementation.connectivity_probe.(selection, probe_context, runtime_services)

    assert_receive {:host_llm_ensure_ready, warmup_pid}
    assert_receive {:host_llm_request, "openrouter:deepseek/deepseek-v4-flash", request}
    request_pid = Map.fetch!(request, :probe_pid)
    refute warmup_pid == request_pid
    assert request.api_key == "probe-secret"
    assert request.cache == false
    assert request.max_tokens == 1
    assert request.max_retries == 0
    assert request.req_http_options == [retry: false, redirect: false, max_retries: 0]
    assert [%{role: :user, content: "Health check."}] = request.messages
    refute_receive {:host_llm_request, _, _}

    Application.put_env(:ptc_runner, :host_llm_test_result, {:error, :unavailable})

    assert {:error, :llm_connectivity_unavailable} =
             implementation.connectivity_probe.(selection, probe_context, runtime_services)

    assert_receive {:host_llm_request, "openrouter:deepseek/deepseek-v4-flash", _request}
    refute_receive {:host_llm_request, _, _}
    assert :ok = InstallationCatalog.close(catalog)
  end

  @tag :tmp_dir
  test "preflight freezes local stdio paths before resolving credentials", %{tmp_dir: dir} do
    config =
      stdio_config(System.find_executable("sh"))
      |> put_in(["runtime", "stdio_launcher"], System.find_executable("sh"))

    host = load_host(dir, config)

    assert {:ok, registry} =
             HostInstallation.catalog(host)
             |> then(fn {:ok, catalog} ->
               HostInstallation.runtime_registry(host, catalog)
             end)

    assert {:ok, prepared} =
             ProviderRegistry.prepare(registry, "workspace", %{}, context(dir, :mission))

    assert prepared.credential_names == ["token"]
    assert {:ok, %{acquire: acquire}} = ProviderRegistry.preflight(prepared)
    assert is_function(acquire, 1)

    assert {:ok, %{"token" => "test-secret"}} =
             ProviderRegistry.resolve_credentials(registry, ["token"])
  end

  @tag :tmp_dir
  test "selection can only narrow installed visibility and ceilings", %{tmp_dir: dir} do
    host = load_host(dir, http_config())

    assert {:ok, registry} =
             HostInstallation.catalog(host)
             |> then(fn {:ok, catalog} ->
               HostInstallation.runtime_registry(host, catalog)
             end)

    context = context(dir, :mission)

    assert {:ok, _prepared} =
             ProviderRegistry.prepare(
               registry,
               "remote",
               %{"allow" => ["remote.read"], "model_visible" => []},
               context
             )

    assert {:error, :invalid_mcp_selection} =
             ProviderRegistry.prepare(
               registry,
               "remote",
               %{"model_visible" => ["remote.hidden"]},
               context
             )

    assert {:error, :invalid_mcp_selection} =
             ProviderRegistry.prepare(
               registry,
               "remote",
               %{"timeout_ms" => 5_001},
               context
             )
  end

  @tag :tmp_dir
  test "runtime MCP normalization matches the declarative canonical set order", %{tmp_dir: dir} do
    host = load_host(dir, http_config())
    assert {:ok, catalog} = HostInstallation.catalog(host)

    selection = %{
      "allow" => ["remote.read", "remote.hidden"],
      "model_visible" => ["remote.read"]
    }

    runtime =
      HostInstallation.normalize_selection(
        host.install["remote"],
        selection,
        context(dir, :mission)
      )

    declarative =
      SelectionRules.normalize(
        catalog.descriptors["remote"].selection_rules,
        selection,
        context(dir, :mission).limits
      )

    assert runtime == declarative

    assert {:ok, %{"allow" => ["remote.hidden", "remote.read"]}} =
             then(runtime, fn {:ok, normalized} -> {:ok, Map.take(normalized, ["allow"])} end)

    assert :ok = InstallationCatalog.close(catalog)
  end

  @tag :tmp_dir
  test "write-bearing MCP installations require an explicit non-empty allow list", %{tmp_dir: dir} do
    config =
      http_config()
      |> put_in(
        ["install", "remote", "tools", "write"],
        %{
          "as" => "remote.write",
          "effect" => "write",
          "model_visible" => true
        }
      )

    host = load_host(dir, config)

    assert {:ok, registry} =
             HostInstallation.catalog(host)
             |> then(fn {:ok, catalog} ->
               HostInstallation.runtime_registry(host, catalog)
             end)

    context = context(dir, :mission)

    assert {:error, :invalid_mcp_selection} =
             ProviderRegistry.prepare(registry, "remote", %{}, context)

    assert {:ok, read_only} =
             ProviderRegistry.prepare(
               registry,
               "remote",
               %{"allow" => ["remote.read"]},
               context
             )

    assert read_only.credential_names == ["token"]

    assert {:ok, write_selected} =
             ProviderRegistry.prepare(
               registry,
               "remote",
               %{"allow" => ["remote.write"]},
               context
             )

    assert write_selected.credential_names == ["token"]
  end

  @tag :tmp_dir
  test "installs one immutable trace snapshot under alias-derived mission operations", %{
    tmp_dir: dir
  } do
    trace_directory = Path.join(dir, "traces")
    File.mkdir_p!(trace_directory)

    File.write!(
      Path.join(trace_directory, "run.jsonl"),
      Jason.encode!(trace_event("captured", 1, "run-started")) <>
        "\n" <>
        Jason.encode!(trace_event("captured", 2, "run-stopped")) <> "\n"
    )

    config = %{
      "install" => %{
        "history" => %{
          "source" => "ptc_trace_snapshot",
          "installation_revision" => "trace-snapshot-v1",
          "directory" => "traces",
          "ceilings" => %{
            "max_source_bytes" => 2_000_000,
            "max_result_bytes" => 250_000
          }
        }
      }
    }

    host = load_host(dir, config)

    assert {:ok, registry} =
             HostInstallation.catalog(host)
             |> then(fn {:ok, catalog} ->
               HostInstallation.runtime_registry(host, catalog)
             end)

    mission = context(dir, :mission)

    assert {:error, :provider_destination_denied} =
             ProviderRegistry.prepare(registry, "history", %{}, %{
               mission
               | destination: :workflow
             })

    assert {:error, :invalid_trace_snapshot_selection} =
             ProviderRegistry.prepare(
               registry,
               "history",
               %{"max_result_bytes" => 250_001},
               mission
             )

    assert {:error, :invalid_trace_snapshot_selection} =
             ProviderRegistry.prepare(
               registry,
               "history",
               %{"max_result_bytes" => HostConfig.minimum_snapshot_result_bytes() - 1},
               mission
             )

    assert {:ok, built} =
             ProviderRegistry.build(
               registry,
               "history",
               %{"max_result_bytes" => 100_000},
               mission
             )

    assert Enum.map(built.capabilities, & &1.name) == [
             "history.list-runs",
             "history.get-run",
             "history.list-turns",
             "history.counters"
           ]

    callbacks = Map.new(built.capabilities, &{&1.name, &1.callback})

    assert {:ok,
            %{
              "items" => [%{"run_id" => "captured"}],
              "snapshot_hash" => content_snapshot_hash
            }} = callbacks["history.list-runs"].(%{})

    File.write!(
      Path.join(trace_directory, "run.jsonl"),
      Jason.encode!(trace_event("changed", 1, "run-started")) <> "\n"
    )

    assert {:ok,
            %{
              "items" => [%{"run_id" => "captured"}],
              "snapshot_hash" => ^content_snapshot_hash
            }} = callbacks["history.list-runs"].(%{})

    assert built.data_class == :normal
    assert built.accepts_data == [:normal, :private_inspection]
    assert built.snapshot["provider"] == "history"
    assert built.snapshot["declaration"]["source"] == "ptc_trace_snapshot"
    assert built.snapshot["declaration"]["installation_revision"] == "trace-snapshot-v1"
    assert built.snapshot["acquisition"]["run_count"] == 1
    assert built.snapshot["snapshot_hash"] =~ ~r/\A[0-9a-f]{64}\z/
    assert built.snapshot["content_snapshot_hash"] == content_snapshot_hash
    refute inspect(built.snapshot) =~ dir
    assert :ok = built.close.()
  end

  @tag :tmp_dir
  test "preparation exposes an installation that accepts only private data for run-level checks",
       %{
         tmp_dir: dir
       } do
    config =
      http_config()
      |> put_in(["install", "remote", "accepts_data"], ["private_inspection"])

    host = load_host(dir, config)

    assert {:ok, registry} =
             HostInstallation.catalog(host)
             |> then(fn {:ok, catalog} ->
               HostInstallation.runtime_registry(host, catalog)
             end)

    assert {:ok, prepared} =
             ProviderRegistry.prepare(registry, "remote", %{}, context(dir, :mission))

    assert prepared.data_class == :normal
    assert prepared.accepts_data == [:private_inspection]
  end

  @tag :tmp_dir
  test "an unstarted provider application is a host misconfiguration, not an outage", %{
    tmp_dir: dir
  } do
    previous = %{
      adapter: Application.get_env(:ptc_runner, :llm_adapter),
      owner: Application.get_env(:ptc_runner, :host_llm_test_owner),
      result: Application.get_env(:ptc_runner, :host_llm_test_result),
      application: Application.get_env(:ptc_runner, :host_llm_test_provider_application)
    }

    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())
    Application.put_env(:ptc_runner, :host_llm_test_result, {:error, :transport_boom})

    # An e2e setup_all may have started :req_llm and left it running, which would
    # quietly dissolve this test's premise. Establish the stopped state rather
    # than assuming it, and put it back afterwards.
    req_llm_running? = Enum.any?(Application.started_applications(), &(elem(&1, 0) == :req_llm))
    if req_llm_running?, do: Application.stop(:req_llm)

    on_exit(fn ->
      if req_llm_running?, do: Application.ensure_all_started(:req_llm)
    end)

    on_exit(fn ->
      restore_env(:llm_adapter, previous.adapter)
      restore_env(:host_llm_test_owner, previous.owner)
      restore_env(:host_llm_test_result, previous.result)
      restore_env(:host_llm_test_provider_application, previous.application)
    end)

    config = %{
      "credentials" => %{"key" => %{"literal" => "test-llm-secret"}},
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "model" => "openrouter:deepseek/deepseek-v4-flash",
          "credential" => "key",
          "installation_revision" => "unstarted-v1"
        }
      }
    }

    host = load_host(dir, config)
    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, registry} = HostInstallation.runtime_registry(host, catalog)
    request = %{"messages" => [%{"role" => "user", "content" => "hi"}]}

    build_capability = fn ->
      assert {:ok, %{capabilities: [capability]}} =
               ProviderRegistry.build(registry, "deepseek", %{}, context(dir, :workflow))

      capability
    end

    # An adapter whose backing application is not running: retrying cannot start
    # an OTP application, so the failure must name the real cause and be final.
    Application.put_env(
      :ptc_runner,
      :host_llm_test_provider_application,
      :req_llm
    )

    assert {:error, %PtcRunner.Kernel.ProviderError{} = stopped} =
             build_capability.().callback.(request)

    assert stopped.kind == :internal
    assert stopped.retryable? == false
    assert stopped.details =~ "req_llm"

    # A route declaring no backing application keeps the retryable transport
    # classification, so the check is not blanket.
    Application.put_env(:ptc_runner, :host_llm_test_provider_application, nil)

    assert {:error, %PtcRunner.Kernel.ProviderError{} = running} =
             build_capability.().callback.(request)

    assert running.kind == :unavailable
    assert running.retryable? == true

    # An application started and later stopped leaves the adapter raising rather
    # than returning an error tuple. The check must precede the call, or the
    # raise unwinds past it and the dispatcher reports a retryable failure.
    Application.put_env(:ptc_runner, :host_llm_test_raise, true)
    on_exit(fn -> Application.delete_env(:ptc_runner, :host_llm_test_raise) end)

    # Drop the probe messages the two invocations above produced, so the
    # refutation below can only observe a fresh adapter call.
    drain = fn drain ->
      receive do
        {:host_llm_request, _model, _request} -> drain.(drain)
      after
        0 -> :ok
      end
    end

    drain.(drain)

    Application.put_env(
      :ptc_runner,
      :host_llm_test_provider_application,
      :req_llm
    )

    assert {:error, %PtcRunner.Kernel.ProviderError{} = raised} =
             build_capability.().callback.(request)

    assert raised.kind == :internal
    assert raised.retryable? == false
    refute_receive {:host_llm_request, _model, _request}
  end

  defp context(_directory, destination) do
    {:ok, limits} = Limits.new()

    %{
      application_content_digest: String.duplicate("0", 64),
      destination: destination,
      owner: self(),
      limits: limits,
      installed_limits: limits
    }
  end

  defp http_config do
    %{
      "credentials" => %{"token" => %{"literal" => "test-secret"}},
      "install" => %{
        "remote" => %{
          "source" => "mcp",
          "installation_revision" => "remote-v1",
          "transport" => %{
            "type" => "streamable_http",
            "endpoint" => "https://example.test/mcp",
            "auth" => [%{"scheme" => "bearer", "binding" => "token"}]
          },
          "tools" => %{
            "read" => %{
              "as" => "remote.read",
              "effect" => "read",
              "model_visible" => true
            },
            "hidden" => %{
              "as" => "remote.hidden",
              "effect" => "read"
            }
          },
          "ceilings" => %{"timeout_ms" => 5_000}
        }
      }
    }
  end

  defp stdio_config(command) do
    %{
      "runtime" => %{},
      "credentials" => %{"token" => %{"literal" => "test-secret"}},
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "installation_revision" => "stdio-v1",
          "transport" => %{
            "type" => "stdio",
            "command" => command,
            "cwd" => ".",
            "inherit_environment" => false,
            "env" => %{"TOKEN" => %{"binding" => "token"}}
          },
          "tools" => %{
            "read" => %{"as" => "workspace.read", "effect" => "read"}
          }
        }
      }
    }
  end

  defp load_host(dir, body) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "host.json")
    File.write!(path, Jason.encode!(body))
    {:ok, host} = HostConfig.load(path)
    host
  end

  defp replace_credential_resolver(services, resolver),
    do: reseal_services(%{services | credential_resolver: resolver})

  defp replace_activation(services, activation),
    do: reseal_services(%{services | activation: activation})

  defp reseal_services(services) do
    payload =
      {services.activation, services.credential_resolver, services.provider_application_mode,
       services.oauth_mode, services.runtime_binding, services.host_payload}

    %{services | attestation: Attestation.attest(ProviderRuntimeServices, payload)}
  end

  defp wait_until_expired(deadline) do
    if Deadline.expired?(deadline) do
      :ok
    else
      :erlang.yield()
      wait_until_expired(deadline)
    end
  end

  defp assert_eventually(predicate, attempts \\ 10_000)

  defp assert_eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      receive do
      after
        0 -> assert_eventually(predicate, attempts - 1)
      end
    end
  end

  defp assert_eventually(_predicate, 0), do: flunk("condition did not become true")

  defp assert_local_preflight_parity(host, name, destination, expected) do
    assert {:ok, catalog} = HostInstallation.catalog(host)
    descriptor = Map.fetch!(catalog.descriptors, name)
    implementation = Map.fetch!(catalog.implementations, name)
    provider_context = context(host.directory, destination)
    assert {:ok, runtime_services} = HostInstallation.runtime_services(host)

    # An audited-local declaration cannot be sealed into an unbound catalog, so
    # a host recipe that stopped binding its catalog would fail construction
    # rather than quietly install a check phase 7 refuses to run.
    assert is_binary(catalog.runtime_binding)
    assert descriptor.local_preflight == :audited_local
    assert is_function(implementation.local_preflight, 3)

    assert {:ok, selection} =
             SelectionRules.normalize(descriptor.selection_rules, %{}, provider_context.limits)

    assert ^expected =
             implementation.local_preflight.(selection, provider_context, runtime_services)

    assert {:ok, registry} = HostInstallation.runtime_registry(host, catalog)
    assert {:ok, prepared} = ProviderRegistry.prepare(registry, name, selection, provider_context)
    assert ^expected = ProviderRegistry.preflight(prepared)
    assert :ok = ProviderRegistry.close(registry)
  end

  defp host_installation_owners do
    marker = {PtcRunner.Kernel.HostInstallationOwner, :authority}

    Process.list()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} -> List.keymember?(dictionary, marker, 0)
        nil -> false
      end
    end)
    |> MapSet.new()
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_runner, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_runner, key, value)

  defp trace_event(run_id, sequence, type) do
    %{
      "schema_version" => 1,
      "run_id" => run_id,
      "trace_id" => "trace-#{run_id}",
      "sequence" => sequence,
      "timestamp" => "2026-07-26T12:00:00Z",
      "type" => type,
      "data" => if(type == "run-stopped", do: %{"outcome" => "ok"}, else: %{})
    }
  end
end
