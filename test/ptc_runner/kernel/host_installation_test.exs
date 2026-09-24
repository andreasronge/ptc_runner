defmodule PtcRunner.Kernel.HostInstallationTest do
  # The cases that set app env, stop :req_llm, capture :stderr, or assert the VM-wide set of
  # HostInstallationOwner processes live in HostInstallationGlobalStateTest.
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]
  import PtcRunner.TestSupport.HostInstallationFixtures

  @stdio_fixture Path.expand("../../support/mcp_stdio_fixture.exs", __DIR__)

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.HostInstallationOwner
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderCallbackBoundary
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.SelectionRules
  alias PtcRunner.TestSupport.LLMSupport
  alias PtcRunner.TestSupport.RunLifecycle

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
    assert {:ok, session} = ProviderSession.begin_operation(session, :run)
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
      assert_receive {:trace, ^authority_owner, :spawn, _callback_guard, _spawned}
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
    assert {:ok, session} = ProviderSession.begin_operation(session, :run)

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

    assert {:ok, built} =
             manifest_path
             |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
             |> RunLifecycle.build(registry)

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
          "structured_output_mode" => "unsupported",
          "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
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
  test "normalizes an unsupported ReqLLM provider for active host diagnostics", %{tmp_dir: dir} do
    LLMSupport.admit_provider_application!()

    host =
      load_host(dir, %{
        "credentials" => %{"key" => %{"literal" => "not-read"}},
        "install" => %{
          "live" => %{
            "source" => "llm",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "installation_revision" => "live-v1",
            "model" => "logger:future-model",
            "credential" => "key"
          }
        }
      })

    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, registry} = HostInstallation.runtime_registry(host, catalog)

    assert {:ok, prepared} =
             ProviderRegistry.prepare(registry, "live", %{}, context(dir, :workflow))

    assert {:error, :invalid_llm_model} = ProviderRegistry.preflight(prepared)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "openai_codex fails local preflight before credentials", %{tmp_dir: dir} do
    host =
      load_host(dir, %{
        "credentials" => %{"key" => %{"literal" => "test-llm-secret"}},
        "install" => %{
          "codex" => %{
            "source" => "llm",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "model" => "openai_codex:future-chat-1408",
            "credential" => "key",
            "installation_revision" => "codex-v1"
          }
        }
      })

    assert_local_preflight_parity(
      host,
      "codex",
      :workflow,
      {:error, :unsupported_model_option}
    )
  end

  @tag :tmp_dir
  test "LLM max_calls uses the host ceiling when it sits below per-name", %{tmp_dir: dir} do
    host =
      load_host(dir, %{
        "credentials" => %{"openrouter_key" => %{"literal" => "test-llm-secret"}},
        "install" => %{
          "deepseek" => %{
            "source" => "llm",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
            "credential" => "openrouter_key",
            "installation_revision" => "max-calls-v1",
            "ceilings" => %{"max_calls" => 4}
          }
        }
      })

    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, registry} = HostInstallation.runtime_registry(host, catalog)
    workflow = context(dir, :workflow)

    assert {:ok, prepared} = ProviderRegistry.prepare(registry, "deepseek", %{}, workflow)
    assert prepared.workflow_llm_route.max_calls == 4

    assert {:ok, narrowed} =
             ProviderRegistry.prepare(registry, "deepseek", %{"max_calls" => 2}, workflow)

    assert narrowed.workflow_llm_route.max_calls == 2

    assert {:error, :invalid_llm_selection} =
             ProviderRegistry.prepare(registry, "deepseek", %{"max_calls" => 8}, workflow)
  end

  @tag :tmp_dir
  test "live structured_output_mode is copied onto the workflow LLM route", %{tmp_dir: dir} do
    host =
      load_host(dir, %{
        "credentials" => %{"openrouter_key" => %{"literal" => "test-llm-secret"}},
        "install" => %{
          "deepseek" => %{
            "source" => "llm",
            "structured_output_mode" => "json_schema",
            "usage_guarantees" => %{"tokens" => true, "cost_currency" => nil},
            "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
            "credential" => "openrouter_key",
            "installation_revision" => "model-policy-v3"
          }
        }
      })

    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, registry} = HostInstallation.runtime_registry(host, catalog)

    assert catalog.descriptors["deepseek"].structured_output_mode == :json_schema

    assert {:ok, prepared} =
             ProviderRegistry.prepare(registry, "deepseek", %{}, context(dir, :workflow))

    assert prepared.workflow_llm_route.structured_output_mode == :json_schema
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
  test "stdio compatibility environment pins UTF-8 for locale-sensitive servers", %{
    tmp_dir: dir
  } do
    {:ok, launcher} = PtcRunnerLauncher.executable_path()
    marker = Path.join(dir, "unicode-server-methods")

    config =
      stdio_config(System.find_executable("elixir"))
      |> put_in(["runtime", "stdio_launcher"], launcher)
      |> put_in(["install", "workspace", "transport", "args"], [
        @stdio_fixture,
        marker,
        "mcp-unicode"
      ])
      # This test exercises locale propagation, not the default startup
      # deadline. Booting an Elixir source fixture can exceed five seconds
      # while the full CI suite is under load.
      |> put_in(["install", "workspace", "ceilings"], %{"timeout_ms" => 20_000})
      |> put_in(["install", "workspace", "transport", "start_timeout_ms"], 20_000)
      |> put_in(["install", "workspace", "transport", "inherit_environment"], true)
      |> put_in(["install", "workspace", "tools"], %{
        "unicode" => %{"as" => "workspace.unicode", "effect" => "read"}
      })

    host = load_host(dir, config)
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 20_000)
    build_context = %{context(dir, :mission) | limits: limits, installed_limits: limits}

    assert {:ok, registry} =
             HostInstallation.catalog(host)
             |> then(fn {:ok, catalog} ->
               HostInstallation.runtime_registry(host, catalog)
             end)

    assert {:ok, %{capabilities: [capability], close: close}} =
             ProviderRegistry.build(registry, "workspace", %{}, build_context)

    on_exit(fn -> close.() end)

    assert {:ok, %{"text" => ["behaviour — correct"]}} = capability.callback.(%{}, nil)
    assert File.read!(marker) =~ "tools/call"
  end

  @tag :tmp_dir
  test "selection can grant host-hidden visibility and must stay within installed names and ceilings",
       %{tmp_dir: dir} do
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

    assert {:ok, _hidden_visible} =
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
               %{"model_visible" => ["remote.missing"]},
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
      Path.join(trace_directory, "captured.jsonl"),
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
             "history.runs",
             "history.open",
             "history.read",
             "history.counters"
           ]

    callbacks = Map.new(built.capabilities, &{&1.name, &1.callback})

    assert {:ok,
            %{
              "items" => [%{"run_id" => "captured"}],
              "snapshot_hash" => content_snapshot_hash
            }} = callbacks["history.runs"].(%{})

    File.write!(
      Path.join(trace_directory, "captured.jsonl"),
      Jason.encode!(trace_event("changed", 1, "run-started")) <> "\n"
    )

    assert {:ok,
            %{
              "items" => [%{"run_id" => "captured"}],
              "snapshot_hash" => ^content_snapshot_hash
            }} = callbacks["history.runs"].(%{})

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
  test "installs a private-authorized trace snapshot with private data policy", %{tmp_dir: dir} do
    trace_directory = Path.join(dir, "traces")
    File.mkdir_p!(trace_directory)

    File.write!(
      Path.join(trace_directory, "private-run.private.jsonl"),
      Jason.encode!(trace_event("private-run", 1, "run-started")) <>
        "\n" <> Jason.encode!(trace_event("private-run", 2, "run-stopped")) <> "\n"
    )

    host =
      load_host(dir, %{
        "install" => %{
          "history" => %{
            "source" => "ptc_private_trace_snapshot",
            "installation_revision" => "private-trace-v1",
            "directory" => "traces"
          }
        }
      })

    assert {:ok, registry} =
             HostInstallation.catalog(host)
             |> then(fn {:ok, catalog} ->
               HostInstallation.runtime_registry(host, catalog)
             end)

    assert {:ok, built} = ProviderRegistry.build(registry, "history", %{}, context(dir, :mission))
    list_runs = Enum.find(built.capabilities, &(&1.name == "history.runs"))

    assert {:ok, %{"items" => [%{"run_id" => "private-run", "source" => "private"}]}} =
             list_runs.callback.(%{"view" => "full"})

    assert built.data_class == :private_inspection
    assert built.accepts_data == [:normal, :private_inspection]
    assert built.snapshot["declaration"]["source"] == "ptc_private_trace_snapshot"
    assert built.snapshot["acquisition"]["source"] == "ptc_private_trace_snapshot"
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

  defp wait_until_expired(deadline) do
    if Deadline.expired?(deadline) do
      :ok
    else
      :erlang.yield()
      wait_until_expired(deadline)
    end
  end

  defp trace_event(run_id, sequence, type) do
    data =
      case type do
        "run-started" ->
          %{"missions" => %{}}

        "run-stopped" ->
          %{
            "outcome" => "ok",
            "usage" => %{"llm_budget" => %{"total_tokens" => nil, "cost" => nil}}
          }
      end

    %{
      "schema_version" => 2,
      "run_id" => run_id,
      "trace_id" => "trace-#{run_id}",
      "sequence" => sequence,
      "timestamp" => "2026-07-26T12:00:00Z",
      "type" => type,
      "data" => data
    }
  end
end
