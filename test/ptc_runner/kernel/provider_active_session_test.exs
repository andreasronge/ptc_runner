defmodule PtcRunner.Kernel.ProviderActiveSessionTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActiveSession
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ResourceRegistrar
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules

  test "active validators run in declaration order after activity is marked" do
    parent = self()

    validator = fn selection, context ->
      send(parent, {:validated, selection["mode"], context.deadline_ms})

      :ok
    end

    {:ok, prepared, catalog} = fixture(validator, ["first", "second"])

    assert {:ok, session} = ProviderActiveSession.open(prepared, catalog, services())
    assert_receive {:validated, "first", first_deadline}
    assert_receive {:validated, "second", second_deadline}
    assert is_integer(first_deadline)
    assert second_deadline >= first_deadline
    assert ProviderActivity.value(prepared.provider_activity) == true

    close(session, prepared)
  end

  test "active selection intersects its intrinsic timeout with the ordinary run deadline" do
    parent = self()

    limits = %{
      Limits.installed_defaults()
      | run_duration_ms: 100,
        selection_validation_timeout_ms: 1_000
    }

    validator = fn _selection, context ->
      send(parent, {:selection_deadline, context.deadline_ms})
      :ok
    end

    {:ok, prepared, catalog} = fixture(validator, ["first"], limits)
    assert {:ok, session} = ProviderActiveSession.open(prepared, catalog, services())
    run_deadline = ProviderSession.run_deadline(session)

    assert_receive {:selection_deadline, selection_deadline}
    assert selection_deadline == Deadline.expires_at(run_deadline)

    close(session, prepared)
  end

  test "selection rejection returns the closed occurrence diagnostic" do
    {:ok, prepared, catalog} =
      fixture(fn _selection, _context -> {:error, :selection_rejected} end)

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             ProviderActiveSession.open(prepared, catalog, services())

    assert diagnostic.phase == :active_preflight
    assert diagnostic.code == :selection_rejected
    assert diagnostic.provider_activity == true
    assert diagnostic.subject.name == "selected"
    assert diagnostic.subject.operation == :selection
    assert diagnostic.subject.occurrence == %{destination: :workflow, index: 0}
    assert ProviderActivity.value(prepared.provider_activity) == :unknown
  end

  test "active build preserves provider dependency failures during session cleanup" do
    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end)
    assert {:ok, session} = ProviderActiveSession.open(prepared, catalog, services())

    staged = fn _selection, _context ->
      {:ok,
       %{
         credential_names: [],
         requires: [:canonical_trace_snapshot],
         preflight: fn -> {:error, :unexpected_preflight} end
       }}
    end

    assert {:ok, registry} =
             ProviderRegistry.new(%{"selected" => ProviderRegistry.staged(staged)})

    assert {:error, :provider_dependency_unavailable} =
             RunBuilder.build_active(prepared, registry, session, [])

    refute ProviderSession.alive?(session)
    assert :ok = PreparedRun.close(prepared)
  end

  test "active build resolves credentials after every preflight and before acquisition" do
    parent = self()
    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end)
    assert {:ok, session} = ProviderActiveSession.open(prepared, catalog, services())

    staged = fn _selection, _context ->
      {:ok,
       %{
         credential_names: ["secret"],
         preflight: fn ->
           send(parent, :credential_preflighted)

           {:ok,
            fn %{"secret" => "value"} ->
              send(parent, :credential_acquired)
              {:ok, capability} = fixture_capability()
              {:ok, capability}
            end}
         end
       }}
    end

    resolver = fn ["secret"] ->
      send(parent, :credential_resolved)
      {:ok, %{"secret" => "value"}}
    end

    assert {:ok, registry} =
             ProviderRegistry.new(%{"selected" => ProviderRegistry.staged(staged)},
               credential_resolver: resolver
             )

    assert {:ok, built} = RunBuilder.build_active(prepared, registry, session, [])
    assert_receive :credential_preflighted
    assert_receive :credential_resolved
    assert_receive :credential_acquired

    assert :ok = RunBuilder.close(built)
    assert :ok = PreparedRun.close(prepared)
  end

  test "active credential resolution is killed at the shared run deadline" do
    parent = self()
    limits = %{Limits.installed_defaults() | run_duration_ms: 1_000}
    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end, ["first"], limits)
    assert {:ok, session} = ProviderActiveSession.open(prepared, catalog, services())

    resolver = fn ["secret"] ->
      send(parent, {:credential_resolver_started, self()})
      receive do: (:never -> {:ok, %{}})
    end

    assert {:ok, registry} = credential_registry(resolver, limits)

    assert {:error,
            %CommandDiagnostic{
              phase: :active_preflight,
              code: :credential_unavailable,
              provider_activity: true,
              subject: %{name: "selected", operation: :credentials, occurrence: nil}
            }} = RunBuilder.build_active(prepared, registry, session, [])

    assert_receive {:credential_resolver_started, worker}
    refute Process.alive?(worker)
    refute ProviderSession.alive?(session)
    assert :ok = PreparedRun.close(prepared)
  end

  test "credentialless active providers do not invoke the resolver" do
    parent = self()
    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end)
    assert {:ok, session} = ProviderActiveSession.open(prepared, catalog, services())

    resolver = fn [] ->
      send(parent, :unexpected_credential_resolution)
      {:error, :unexpected_credential_resolution}
    end

    {:ok, registry} = active_registry(credential_resolver: resolver)
    assert {:ok, built} = RunBuilder.build_active(prepared, registry, session, [])
    refute_receive :unexpected_credential_resolution

    assert :ok = RunBuilder.close(built)
    assert :ok = PreparedRun.close(prepared)
  end

  test "credentialless providers do not acquire after the shared deadline" do
    parent = self()
    limits = %{Limits.installed_defaults() | run_duration_ms: 500}
    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end, ["first"], limits)

    owner =
      spawn(fn ->
        {:ok, session} = ProviderActiveSession.open(prepared, catalog, services())

        staged = fn _selection, _context ->
          {:ok,
           %{
             credential_names: [],
             preflight: fn ->
               send(parent, {:credentialless_preflight, self()})
               receive do: (:finish_preflight -> :ok)

               {:ok,
                fn %{} ->
                  send(parent, :unexpected_credentialless_acquisition)
                  {:ok, capability} = fixture_capability()
                  {:ok, capability}
                end}
             end
           }}
        end

        {:ok, registry} =
          ProviderRegistry.new(%{"selected" => ProviderRegistry.staged(staged)},
            installed_limits: limits
          )

        result = RunBuilder.build_active(prepared, registry, session, [])
        assert :ok = PreparedRun.close(prepared)
        send(parent, {:credentialless_deadline_result, result})
      end)

    assert_receive {:credentialless_preflight, ^owner}
    Process.send_after(self(), :credentialless_deadline_elapsed, 600)
    assert_receive :credentialless_deadline_elapsed, 1_000
    send(owner, :finish_preflight)

    assert_receive {:credentialless_deadline_result,
                    {:error,
                     %CommandDiagnostic{
                       phase: :execution,
                       code: :run_timeout,
                       provider_activity: true
                     }}},
                   2_000

    refute_receive :unexpected_credentialless_acquisition
  end

  test "active credential resolution dies when its provider session closes" do
    parent = self()
    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end)

    resolver = fn ["secret"] ->
      send(parent, {:session_close_credential_worker, self()})
      receive do: (:never -> {:ok, %{}})
    end

    owner =
      spawn(fn ->
        {:ok, session} = ProviderActiveSession.open(prepared, catalog, services())
        send(parent, {:session_close_credential_session, session})
        {:ok, registry} = credential_registry(resolver)
        result = RunBuilder.build_active(prepared, registry, session, [])
        assert :ok = PreparedRun.close(prepared)
        send(parent, {:session_close_build_result, result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:session_close_credential_session, session}
    assert_receive {:session_close_credential_worker, worker}
    worker_ref = Process.monitor(worker)
    assert :ok = ProviderSession.close(session)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
    assert_receive {:session_close_build_result, {:error, _reason}}
    assert Process.alive?(owner)
    send(owner, :stop)
  end

  test "active credential resolution dies with its caller and session" do
    parent = self()
    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end)

    resolver = fn ["secret"] ->
      send(parent, {:caller_death_credential_worker, self()})
      receive do: (:never -> {:ok, %{}})
    end

    owner =
      spawn(fn ->
        {:ok, session} = ProviderActiveSession.open(prepared, catalog, services())
        send(parent, {:caller_death_credential_session, session})
        {:ok, registry} = credential_registry(resolver)
        RunBuilder.build_active(prepared, registry, session, [])
      end)

    assert_receive {:caller_death_credential_session, session}
    assert_receive {:caller_death_credential_worker, worker}
    worker_ref = Process.monitor(worker)
    session_ref = Process.monitor(session.pid)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
    assert_receive {:DOWN, ^session_ref, :process, _, _reason}, 2_000
    assert :ok = PreparedRun.close(prepared)
  end

  test "active build rejects a session opened for another prepared run" do
    {:ok, first, first_catalog} = fixture(fn _selection, _context -> :ok end)
    {:ok, second, second_catalog} = fixture(fn _selection, _context -> :ok end)
    assert {:ok, first_session} = ProviderActiveSession.open(first, first_catalog, services())
    assert {:ok, second_session} = ProviderActiveSession.open(second, second_catalog, services())
    assert {:ok, registry} = ProviderRegistry.new(%{})

    assert {:error, :invalid_active_run} =
             RunBuilder.build_active(second, registry, first_session, [])

    refute ProviderSession.alive?(first_session)
    assert :ok = ProviderSession.close(second_session)
    assert :ok = PreparedRun.close(first)
    assert :ok = PreparedRun.close(second)
  end

  test "active build rejects cloned identity with a different run duration before preparation" do
    parent = self()
    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end)
    assert {:ok, opened_session} = ProviderActiveSession.open(prepared, catalog, services())
    assert :ok = ProviderSession.close(opened_session)

    limits = prepared.request.package.limits
    other_limits = %{limits | run_duration_ms: limits.run_duration_ms + 1}

    assert {:ok, wrong_session} =
             ProviderSession.start_active(other_limits, prepared.attestation)

    assert {:ok, wrong_session} = ProviderSession.begin_run(wrong_session)

    staged = fn _selection, _context ->
      send(parent, :unexpected_provider_preparation)
      {:error, :unexpected_provider_preparation}
    end

    assert {:ok, registry} =
             ProviderRegistry.new(%{"selected" => ProviderRegistry.staged(staged)})

    assert {:error, :invalid_active_run} =
             RunBuilder.build_active(prepared, registry, wrong_session, [])

    refute_receive :unexpected_provider_preparation
    refute ProviderSession.alive?(wrong_session)
    assert :ok = PreparedRun.close(prepared)
  end

  test "active build claims its session once without closing it on replay" do
    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end)
    assert {:ok, session} = ProviderActiveSession.open(prepared, catalog, services())
    assert {:ok, registry} = active_registry()

    assert {:ok, built} = RunBuilder.build_active(prepared, registry, session, [])
    assert built.config.run_deadline == ProviderSession.run_deadline(session)

    assert {:error, :invalid_active_run} =
             RunBuilder.build_active(prepared, registry, session, [])

    assert {:error, :invalid_active_run} =
             RunBuilder.build_active(prepared, registry, session, unknown: true)

    {:ok, other, other_catalog} = fixture(fn _selection, _context -> :ok end)
    assert {:ok, other_session} = ProviderActiveSession.open(other, other_catalog, services())

    assert {:error, :invalid_active_run} =
             RunBuilder.build_active(other, registry, session, [])

    assert ProviderSession.alive?(session)

    assert :ok = RunBuilder.close(built)
    assert :ok = ProviderSession.close(other_session)
    assert :ok = PreparedRun.close(prepared)
    assert :ok = PreparedRun.close(other)
  end

  @tag timeout: 10_000
  test "a timed-out replay cannot close a claimed active session" do
    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end)
    assert {:ok, session} = ProviderActiveSession.open(prepared, catalog, services())
    assert {:ok, registry} = active_registry()
    assert {:ok, built} = RunBuilder.build_active(prepared, registry, session, [])

    assert true = :erlang.suspend_process(session.pid)

    try do
      assert {:error, :invalid_active_run} =
               RunBuilder.build_active(prepared, registry, session, [])
    after
      if Process.alive?(session.pid), do: :erlang.resume_process(session.pid)
    end

    assert {:error, :operation_claimed} =
             ProviderSession.claim_operation(
               session,
               prepared.request.package.limits,
               prepared.attestation
             )

    assert ProviderSession.alive?(session)
    assert :ok = RunBuilder.close(built)
    assert :ok = PreparedRun.close(prepared)
  end

  test "invalid callback results and callback exits are selection failures" do
    for callback <- [
          fn _selection, _context -> :invalid end,
          fn _selection, _context -> exit(:fixture_failure) end
        ] do
      {:ok, prepared, catalog} = fixture(callback)

      assert {:error, %CommandDiagnostic{code: :selection_validation_failed}} =
               ProviderActiveSession.open(prepared, catalog, services())
    end
  end

  test "a blocked validator is killed at its intrinsic deadline" do
    parent = self()

    validator = fn _selection, _context ->
      send(parent, {:validator_started, self()})
      receive do: (:never -> :ok)
    end

    {:ok, limits} = Limits.new(selection_validation_timeout_ms: 100)
    {:ok, prepared, catalog} = fixture(validator, ["first"], limits)

    assert {:error, %CommandDiagnostic{code: :selection_validation_timeout}} =
             ProviderActiveSession.open(prepared, catalog, services())

    assert_receive {:validator_started, worker}
    refute Process.alive?(worker)
  end

  test "a queued success is rejected after the absolute deadline" do
    parent = self()

    owner =
      spawn(fn ->
        validator = fn _selection, _context ->
          send(parent, {:late_result_worker, self()})
          receive do: (:finish -> :ok)
        end

        {:ok, limits} = Limits.new(selection_validation_timeout_ms: 100)
        {:ok, prepared, catalog} = fixture(validator, ["first"], limits)
        send(parent, {:late_result, ProviderActiveSession.open(prepared, catalog, services())})
      end)

    assert_receive {:late_result_worker, worker}
    assert true = :erlang.suspend_process(owner)
    worker_ref = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}

    Process.send_after(self(), :resume_late_result_owner, 150)
    assert_receive :resume_late_result_owner, 500
    assert true = :erlang.resume_process(owner)

    assert_receive {:late_result,
                    {:error, %CommandDiagnostic{code: :selection_validation_timeout}}},
                   2_000
  end

  test "validator roots are provisional and gone before open returns" do
    parent = self()

    validator = fn _selection, context ->
      validator_worker = self()

      root =
        spawn(fn ->
          signal_ref = Process.monitor(context.owner)
          assert :ok = ResourceRegistrar.register_root(context.resource_registrar)
          send(validator_worker, {:root_registered, self()})

          receive do
            {:DOWN, ^signal_ref, :process, _pid, _reason} -> :ok
          end
        end)

      assert_receive {:root_registered, ^root}
      send(parent, {:validator_root, root})
      :ok
    end

    {:ok, prepared, catalog} = fixture(validator)
    assert {:ok, session} = ProviderActiveSession.open(prepared, catalog, services())
    assert_receive {:validator_root, root}
    root_ref = Process.monitor(root)
    assert_receive {:DOWN, ^root_ref, :process, ^root, reason}, 2_000
    assert reason in [:normal, :noproc]

    close(session, prepared)
  end

  test "caller death kills validator work and drains its registered root" do
    parent = self()

    owner =
      spawn(fn ->
        validator = fn _selection, context ->
          validator_worker = self()

          root =
            spawn(fn ->
              signal_ref = Process.monitor(context.owner)
              assert :ok = ResourceRegistrar.register_root(context.resource_registrar)
              send(validator_worker, {:caller_death_root, self()})

              receive do
                {:DOWN, ^signal_ref, :process, _pid, _reason} -> :ok
              end
            end)

          send(parent, {:caller_death_worker, self()})
          assert_receive {:caller_death_root, ^root}
          send(parent, {:caller_death_root, root})
          receive do: (:never -> :ok)
        end

        {:ok, prepared, catalog} = fixture(validator)
        ProviderActiveSession.open(prepared, catalog, services())
      end)

    assert_receive {:caller_death_worker, worker}
    assert_receive {:caller_death_root, root}
    worker_ref = Process.monitor(worker)
    root_ref = Process.monitor(root)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
    assert_receive {:DOWN, ^root_ref, :process, ^root, _reason}, 2_000
  end

  test "a prepared run cannot be opened with another sealed catalog" do
    callback = fn _selection, _context -> :ok end
    {:ok, prepared, _catalog} = fixture(callback)
    {:ok, other_prepared, other_catalog} = fixture(callback, ["first"], nil, "other-v1")

    assert {:error, %CommandDiagnostic{phase: :internal, provider_activity: false}} =
             ProviderActiveSession.open(prepared, other_catalog, services())

    assert ProviderActivity.value(prepared.provider_activity) == false
    PreparedRun.close(prepared)
    PreparedRun.close(other_prepared)
  end

  test "callbacks receive only an absolute deadline and scoped runtime owners" do
    validator = fn _selection, context ->
      assert Deadline.valid?(context.deadline)
      assert context.deadline_ms == Deadline.expires_at(context.deadline)
      assert Deadline.remaining(context.deadline) > 0
      assert is_pid(context.owner)
      assert %ResourceRegistrar{} = context.resource_registrar
      refute Map.has_key?(context, :credential_resolver)
      :ok
    end

    {:ok, prepared, catalog} = fixture(validator)
    assert {:ok, session} = ProviderActiveSession.open(prepared, catalog, services())
    close(session, prepared)
  end

  test "host-owned mode requires the selected provider application to be running" do
    restore_provider_applications_on_exit()
    stop_provider_applications()

    {:ok, prepared, catalog} =
      fixture(fn _selection, _context -> :ok end, ["first"], nil, "custom-v1", :req_llm)

    assert {:error,
            %CommandDiagnostic{
              phase: :active_preflight,
              code: :provider_application_unavailable,
              provider_activity: true
            } = diagnostic} =
             ProviderActiveSession.open(prepared, catalog, services(:host_owned))

    assert diagnostic.subject.name == "selected"
    assert diagnostic.subject.operation == :application
    assert diagnostic.subject.occurrence == nil
    assert ProviderActivity.value(prepared.provider_activity) == :unknown
  end

  @tag :tmp_dir
  test "command VM startup disables both dotenv readers before applications start", %{
    tmp_dir: directory
  } do
    restore_provider_applications_on_exit()
    stop_provider_applications()
    Application.put_env(:req_llm, :load_dotenv, true, persistent: true)
    Application.put_env(:llm_db, :load_dotenv, true, persistent: true)

    sentinel = "PTC_PROVIDER_APPLICATION_DOTENV_SENTINEL"
    previous_sentinel = System.get_env(sentinel)
    System.delete_env(sentinel)

    on_exit(fn ->
      if previous_sentinel,
        do: System.put_env(sentinel, previous_sentinel),
        else: System.delete_env(sentinel)
    end)

    File.write!(Path.join(directory, ".env"), "#{sentinel}=must-not-load\n")

    {:ok, prepared, catalog} =
      fixture(fn _selection, _context -> :ok end, ["first"], nil, "custom-v1", :req_llm)

    File.cd!(directory, fn ->
      assert {:ok, session} =
               ProviderActiveSession.open(prepared, catalog, services(:command_vm))

      assert Application.get_env(:req_llm, :load_dotenv) == false
      assert Application.get_env(:llm_db, :load_dotenv) == false
      assert System.get_env(sentinel) == nil
      assert :req_llm in started_applications()
      assert :llm_db in started_applications()

      close(session, prepared)
    end)
  end

  test "command VM mode rejects a prestarted target while host-owned mode accepts it" do
    restore_provider_applications_on_exit()
    stop_provider_applications()
    Application.put_env(:req_llm, :load_dotenv, false, persistent: true)
    Application.put_env(:llm_db, :load_dotenv, false, persistent: true)
    assert {:ok, _started} = Application.ensure_all_started(:req_llm)

    {:ok, command_prepared, command_catalog} =
      fixture(fn _selection, _context -> :ok end, ["first"], nil, "command-v1", :req_llm)

    assert {:error,
            %CommandDiagnostic{code: :provider_application_unavailable, provider_activity: true}} =
             ProviderActiveSession.open(
               command_prepared,
               command_catalog,
               services(:command_vm)
             )

    {:ok, host_prepared, host_catalog} =
      fixture(fn _selection, _context -> :ok end, ["first"], nil, "host-v1", :req_llm)

    assert {:ok, session} =
             ProviderActiveSession.open(host_prepared, host_catalog, services(:host_owned))

    close(session, host_prepared)
  end

  defp fixture(
         callback,
         modes \\ ["first"],
         limits \\ nil,
         revision \\ "custom-v1",
         provider_application \\ nil
       ) do
    limits = limits || Limits.installed_defaults()
    {:ok, rules} = rules()

    {:ok, descriptor} =
      ProviderDescriptor.new(
        source: :custom,
        installation_revision: revision,
        credential_names: [],
        authorization_mode: :none,
        data_class: :normal,
        accepts_data: [:normal],
        requires: [],
        provides: [],
        destinations: [:workflow],
        workflow_llm?: false,
        connectivity_mode: :none,
        probe_effect: nil,
        selection_validation: :active,
        selection_rules: rules,
        authority_fingerprint: nil,
        local_preflight: :none
      )

    aliases =
      if modes == ["first"],
        do: ["selected"],
        else: Enum.map(Enum.with_index(modes), fn {_mode, index} -> "selected-#{index}" end)

    registrations =
      Map.new(aliases, fn name ->
        implementation = %{
          builder: fn _selection, _context -> {:error, :inactive_provider} end,
          selection_validator: callback
        }

        implementation =
          if provider_application,
            do: Map.put(implementation, :provider_application, provider_application),
            else: implementation

        {name,
         %{
           descriptor: descriptor,
           implementation: implementation,
           authority: nil
         }}
      end)

    {:ok, catalog} = InstallationCatalog.new(registrations, installed_limits: limits)

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" =>
          Enum.zip_with(aliases, modes, fn name, mode ->
            %{"name" => name, "config" => %{"mode" => mode}}
          end),
        "mission" => []
      }
    }

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [input] (return input))"
    }

    with {:ok, request} <-
           ApplicationPackage.request_memory("ptc.json", documents,
             installed_limits: limits,
             result_projection: :json
           ),
         {:ok, prepared} <- RunCoordinator.prepare(request, catalog) do
      {:ok, prepared, catalog}
    end
  end

  defp rules do
    SelectionRules.new(
      fields: %{
        "mode" => %{type: :string, input: true, required: true, members: "modes"}
      },
      cross_rules: [],
      named_sets: %{"modes" => ["first", "second"]}
    )
  end

  defp active_registry(opts \\ []) do
    {:ok, capability} =
      Capability.new(
        name: "fixture",
        input_schema: %{"type" => "object", "additionalProperties" => false},
        callback: fn _arguments -> {:ok, %{}} end
      )

    staged = fn _selection, _context ->
      {:ok,
       %{
         credential_names: [],
         preflight: fn -> {:ok, fn %{} -> {:ok, capability} end} end
       }}
    end

    ProviderRegistry.new(%{"selected" => ProviderRegistry.staged(staged)}, opts)
  end

  defp credential_registry(resolver, installed_limits \\ Limits.installed_defaults()) do
    staged = fn _selection, _context ->
      {:ok,
       %{
         credential_names: ["secret"],
         preflight: fn ->
           {:ok,
            fn %{"secret" => "value"} ->
              {:ok, capability} = fixture_capability()
              {:ok, capability}
            end}
         end
       }}
    end

    ProviderRegistry.new(%{"selected" => ProviderRegistry.staged(staged)},
      credential_resolver: resolver,
      installed_limits: installed_limits
    )
  end

  defp fixture_capability do
    Capability.new(
      name: "fixture.credential",
      input_schema: %{"type" => "object", "additionalProperties" => false},
      callback: fn _arguments -> {:ok, %{}} end
    )
  end

  defp close(session, prepared) do
    assert :ok = ProviderSession.close(session)
    assert :ok = PreparedRun.close(prepared)
  end

  defp services(mode \\ :host_owned) do
    {:ok, services} = ProviderRuntimeServices.new(provider_application_mode: mode)
    services
  end

  defp started_applications,
    do: Application.started_applications() |> Enum.map(&elem(&1, 0))

  defp stop_provider_applications do
    running = started_applications()

    if :req_llm in running, do: Application.stop(:req_llm)
    if :llm_db in running, do: Application.stop(:llm_db)
  end

  defp restore_provider_applications_on_exit do
    initially_running = MapSet.new(started_applications())

    on_exit(fn ->
      stop_provider_applications()
      Application.put_env(:req_llm, :load_dotenv, false, persistent: true)
      Application.put_env(:llm_db, :load_dotenv, false, persistent: true)

      if MapSet.member?(initially_running, :llm_db),
        do: Application.ensure_all_started(:llm_db)

      if MapSet.member?(initially_running, :req_llm),
        do: Application.ensure_all_started(:req_llm)
    end)
  end
end
