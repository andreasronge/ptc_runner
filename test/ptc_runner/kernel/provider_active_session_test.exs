defmodule PtcRunner.Kernel.ProviderActiveSessionTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActiveSession
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderCredentials
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.ResourceRegistrar
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules
  alias PtcRunner.TestSupport.LLMSupport
  alias PtcRunner.TestSupport.MCPHTTPFixture

  test "active validators run in declaration order after activity is marked" do
    parent = self()

    validator = fn selection, context ->
      send(parent, {:validated, selection["mode"], context.deadline_ms})

      :ok
    end

    {:ok, prepared, catalog} = fixture(validator, ["first", "second"])

    assert {:ok, session} = open_owned(prepared, catalog, services())
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
    assert {:ok, session} = open_owned(prepared, catalog, services())
    run_deadline = ProviderSession.run_deadline(session)

    assert_receive {:selection_deadline, selection_deadline}
    assert selection_deadline == Deadline.expires_at(run_deadline)

    close(session, prepared)
  end

  test "setup admission leaves the ordinary run clock stopped until activation" do
    parent = self()

    validator = fn _selection, context ->
      send(parent, {:validated_after_run_began, context.deadline_ms})
      :ok
    end

    {:ok, prepared, catalog} = fixture(validator, ["first"])

    assert {:ok, session} =
             open_owned_setup(prepared, catalog, services())

    assert ProviderSession.run_deadline(session) == nil
    refute_received {:validated_after_run_began, _deadline_ms}

    assert {:ok, session} =
             ProviderActiveSession.begin_owned_operation(
               session,
               prepared,
               catalog,
               services(),
               :run
             )

    assert Deadline.valid?(ProviderSession.run_deadline(session))
    assert_receive {:validated_after_run_began, deadline_ms}
    assert deadline_ms <= Deadline.expires_at(ProviderSession.run_deadline(session))

    close(session, prepared)
  end

  test "execution-owned setup accepts an already consumed run without releasing it" do
    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end, ["first"])
    assert :ok = PreparedRun.consume(prepared)
    lifecycle_owner = spawn(fn -> receive do: (:stop -> :ok) end)
    parent = self()

    assert {:ok, session} =
             ProviderActiveSession.open_consumed_setup(
               prepared,
               catalog,
               services(),
               lifecycle_owner,
               fn opened ->
                 send(parent, {:owned_session, opened})
                 :ok
               end
             )

    assert_receive {:owned_session, ^session}
    assert PreparedRun.active_valid?(prepared)

    assert {:ok, session} =
             ProviderActiveSession.begin_owned_operation(
               session,
               prepared,
               catalog,
               services(),
               :run
             )

    assert :ok = ProviderSession.close(session)
    assert PreparedRun.active_valid?(prepared)
    assert :ok = PreparedRun.close(prepared)
    send(lifecycle_owner, :stop)
  end

  test "a rejected session handoff reports no provider activity" do
    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end, ["first"])
    assert {:ok, _inputs} = owned_inputs(prepared)

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             ProviderActiveSession.open_consumed_setup(
               prepared,
               catalog,
               services(),
               self(),
               fn _session -> {:error, :handoff_rejected} end
             )

    assert diagnostic.code == :internal_error
    refute diagnostic.provider_activity
    assert :ok = PreparedRun.close(prepared)
  end

  test "a session lost before begin preserves only application activity" do
    for {application, services, expected_activity, revision} <- [
          {nil, services(), false, "lost-inert-v1"},
          {:req_llm, services(:command_vm), true, "lost-application-v1"}
        ] do
      if application do
        restore_provider_applications_on_exit()
        stop_provider_applications()
      end

      {:ok, prepared, catalog} =
        fixture(
          fn _selection, _context -> :ok end,
          ["first"],
          nil,
          revision,
          application
        )

      assert {:ok, session} = open_owned_setup(prepared, catalog, services)
      session_ref = Process.monitor(session.pid)
      Process.exit(session.pid, :kill)
      assert_receive {:DOWN, ^session_ref, :process, _pid, :killed}, 1_000

      assert {:error, %CommandDiagnostic{} = diagnostic} =
               ProviderActiveSession.begin_owned_operation(
                 session,
                 prepared,
                 catalog,
                 services,
                 :run
               )

      assert diagnostic.code == :internal_error
      assert diagnostic.provider_activity == expected_activity
      assert :ok = PreparedRun.close(prepared)
    end
  end

  test "execution worker builds against sinks owned by the fixed lifecycle owner" do
    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end, ["first"])
    assert {:ok, authority} = PublicationAuthority.new([])
    assert {:ok, opened_sinks} = RunBuilder.open_prepared_sinks(prepared, authority, self())
    parent = self()

    worker =
      spawn(fn ->
        receive do
          :start_owned_build -> :ok
        end

        result =
          with {:ok, session} <-
                 ProviderActiveSession.open_consumed_setup(
                   prepared,
                   catalog,
                   services(),
                   parent,
                   fn _session -> :ok end
                 ),
               {:ok, session} <-
                 ProviderActiveSession.begin_owned_operation(
                   session,
                   prepared,
                   catalog,
                   services(),
                   :run
                 ),
               {:ok, registry} <- active_registry(),
               {:ok, credentials} <-
                 ProviderCredentials.resolve(prepared, catalog, registry, session, true),
               {:ok, built} <-
                 RunBuilder.build_active_owned(
                   prepared,
                   catalog,
                   registry,
                   session,
                   authority,
                   opened_sinks,
                   credentials
                 ) do
            {:ok, built, registry, session}
          end

        send(parent, {:owned_build, result})
      end)

    assert :ok = PreparedRun.authorize_executor(prepared, worker)
    send(worker, :start_owned_build)
    worker_ref = Process.monitor(worker)
    assert_receive {:owned_build, {:ok, built, registry, _session}}, 5_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}
    assert {:ok, owner} = EventSink.owner(built.config.event_sink)
    assert owner == self()
    assert :ok = RunBuilder.close(built.config)
    assert :ok = ProviderRegistry.close(registry)
    assert :ok = PreparedRun.close(prepared)
  end

  test "selection rejection returns the closed occurrence diagnostic" do
    {:ok, prepared, catalog} =
      fixture(fn _selection, _context -> {:error, :selection_rejected} end)

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             open_owned(prepared, catalog, services())

    assert diagnostic.phase == :active_preflight
    assert diagnostic.code == :selection_rejected
    assert diagnostic.provider_activity == true
    assert diagnostic.subject.name == "selected"
    assert diagnostic.subject.operation == :selection
    assert diagnostic.subject.occurrence == %{destination: :workflow, index: 0}

    # The execution owner owns the prepared run, so a failed opening leaves the
    # marked activity for that owner to release rather than closing it here.
    assert ProviderActivity.value(prepared.provider_activity) == true
    assert :ok = PreparedRun.close(prepared)
  end

  test "active build preserves a provider declaration failure during session cleanup" do
    # The preparation invents a dependency its sealed declaration does not have.
    # The run path plans from that declaration, so it refuses the drift itself
    # rather than discovering the unsatisfiable graph the invented dependency
    # would have produced — and it names the occurrence that drifted, because an
    # active session classifies. The failure still survives session cleanup,
    # which is what this test is here to pin.
    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end)
    assert {:ok, session} = open_owned(prepared, catalog, services())

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

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             build_owned(prepared, catalog, registry, session, [])

    assert diagnostic.phase == :provider_acquisition
    assert diagnostic.code == :provider_policy_changed
    assert diagnostic.subject.occurrence == %{destination: :workflow, index: 0}

    refute ProviderSession.alive?(session)
    assert :ok = PreparedRun.close(prepared)
  end

  test "active build resolves credentials before any provider callback" do
    # Phase-8 step 5. The order is asserted from the drained mailbox rather than
    # from three `assert_receive`s, which match anywhere in it and so would have
    # passed against either order.
    parent = self()
    {:ok, prepared, catalog} = credential_fixture()
    assert {:ok, session} = open_owned(prepared, catalog, services())

    staged = fn _selection, context ->
      send(parent, {:provider_context_deadline, context.deadline, context.deadline_ms})
      send(parent, :credential_prepared)

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

    assert {:ok, built} = build_owned(prepared, catalog, registry, session, [])
    run_deadline = ProviderSession.run_deadline(session)

    assert_receive {:provider_context_deadline, ^run_deadline, deadline_ms}
    assert deadline_ms == Deadline.expires_at(run_deadline)

    assert drained_phases() == [
             :credential_resolved,
             :credential_prepared,
             :credential_preflighted,
             :credential_acquired
           ]

    assert :ok = RunBuilder.close(built)
    assert :ok = PreparedRun.close(prepared)
  end

  test "active credential resolution is killed at the shared run deadline" do
    parent = self()
    limits = %{Limits.installed_defaults() | run_duration_ms: 1_000}
    {:ok, prepared, catalog} = credential_fixture(limits)
    assert {:ok, session} = open_owned(prepared, catalog, services())

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
            }} = build_owned(prepared, catalog, registry, session, [])

    assert_receive {:credential_resolver_started, worker}
    refute Process.alive?(worker)
    refute ProviderSession.alive?(session)
    assert :ok = PreparedRun.close(prepared)
  end

  test "credentialless active providers do not invoke the resolver" do
    parent = self()
    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end)
    assert {:ok, session} = open_owned(prepared, catalog, services())

    resolver = fn [] ->
      send(parent, :unexpected_credential_resolution)
      {:error, :unexpected_credential_resolution}
    end

    {:ok, registry} = active_registry(credential_resolver: resolver)
    assert {:ok, built} = build_owned(prepared, catalog, registry, session, [])
    refute_receive :unexpected_credential_resolution

    assert :ok = RunBuilder.close(built)
    assert :ok = PreparedRun.close(prepared)
  end

  test "active provider callbacks are killed at the shared run deadline" do
    parent = self()
    limits = %{Limits.installed_defaults() | run_duration_ms: 200}

    for blocked_phase <- [:prepare, :preflight, :acquisition] do
      {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end, ["first"], limits)
      assert {:ok, session} = open_owned(prepared, catalog, services())

      block = fn phase ->
        if phase == blocked_phase do
          send(parent, {:provider_callback_started, phase, self()})
          receive do: (:never -> :ok)
        end
      end

      staged = fn _selection, _context ->
        block.(:prepare)

        {:ok,
         %{
           credential_names: [],
           preflight: fn ->
             block.(:preflight)

             {:ok,
              fn %{} ->
                block.(:acquisition)
                {:ok, capability} = fixture_capability()
                {:ok, capability}
              end}
           end
         }}
      end

      assert {:ok, registry} =
               ProviderRegistry.new(%{"selected" => ProviderRegistry.staged(staged)},
                 installed_limits: limits
               )

      assert {:error,
              %CommandDiagnostic{
                phase: :provider_acquisition,
                code: :provider_unavailable,
                provider_activity: true,
                subject: %{
                  name: "selected",
                  operation: :acquisition,
                  occurrence: %{destination: :workflow, index: 0}
                }
              }} = build_owned(prepared, catalog, registry, session, [])

      assert_receive {:provider_callback_started, ^blocked_phase, worker}
      refute Process.alive?(worker)
      refute ProviderSession.alive?(session)
      assert :ok = PreparedRun.close(prepared)
    end
  end

  test "active preflight release is killed at the shared cleanup deadline" do
    parent = self()

    limits = %{
      Limits.installed_defaults()
      | run_duration_ms: 100,
        provider_cleanup_timeout_ms: 100
    }

    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end, ["first"], limits)
    assert {:ok, session} = open_owned(prepared, catalog, services())

    staged = fn _selection, _context ->
      {:ok,
       %{
         credential_names: [],
         preflight: fn ->
           {:ok,
            fn %{} ->
              receive do: (:never -> {:error, :unexpected_acquisition_result})
            end,
            fn ->
              send(parent, {:blocking_preflight_release, self()})
              receive do: (:never -> :ok)
            end}
         end
       }}
    end

    assert {:ok, registry} =
             ProviderRegistry.new(%{"selected" => ProviderRegistry.staged(staged)},
               installed_limits: limits
             )

    assert {:error, %CommandDiagnostic{code: :provider_unavailable}} =
             build_owned(prepared, catalog, registry, session, [])

    assert_receive {:blocking_preflight_release, release_worker}
    refute Process.alive?(release_worker)
    refute ProviderSession.alive?(session)
    assert :ok = PreparedRun.close(prepared)
  end

  test "a provider returned at the expired boundary is retained only for cleanup" do
    assert_expired_boundary_resource(false)
  end

  test "an expired provider closer survives a concurrent session close" do
    assert_expired_boundary_resource(true)
  end

  defp assert_expired_boundary_resource(close_session?) do
    parent = self()
    limits = %{Limits.installed_defaults() | run_duration_ms: 1_000}

    owner =
      spawn(fn ->
        {:ok, prepared, catalog} =
          fixture(fn _selection, _context -> :ok end, ["first"], limits)

        {:ok, session} = open_owned(prepared, catalog, services())
        send(parent, {:boundary_session, session})

        staged = fn _selection, _context ->
          {:ok,
           %{
             credential_names: [],
             preflight: fn ->
               {:ok,
                fn %{} ->
                  send(parent, {:boundary_acquisition, self()})
                  receive do: (:finish_boundary_acquisition -> :ok)
                  {:ok, capability} = fixture_capability()

                  {:ok,
                   %{
                     capabilities: [capability],
                     close: fn ->
                       send(parent, :boundary_provider_closed)
                       :ok
                     end
                   }}
                end}
             end
           }}
        end

        {:ok, registry} =
          ProviderRegistry.new(%{"selected" => ProviderRegistry.staged(staged)},
            installed_limits: limits
          )

        result = build_owned(prepared, catalog, registry, session, [])
        send(parent, {:boundary_result, result})
        :ok = PreparedRun.close(prepared)
      end)

    try do
      assert_receive {:boundary_session, session}, 1_000
      assert_receive {:boundary_acquisition, acquisition_worker}, 1_000
      acquisition_ref = Process.monitor(acquisition_worker)
      assert true = :erlang.suspend_process(owner)
      send(acquisition_worker, :finish_boundary_acquisition)
      assert_receive {:DOWN, ^acquisition_ref, :process, ^acquisition_worker, :normal}, 1_000
      wait_until_expired(ProviderSession.run_deadline(session))
      if close_session?, do: assert(:ok = ProviderSession.close(session))
      assert true = :erlang.resume_process(owner)

      if close_session? do
        assert_receive {:boundary_result, {:error, :provider_cleanup_failed}}, 1_000
      else
        assert_receive {:boundary_result,
                        {:error,
                         %CommandDiagnostic{
                           phase: :provider_acquisition,
                           code: :provider_unavailable
                         }}},
                       1_000
      end

      assert_receive :boundary_provider_closed, 1_000
      refute ProviderSession.alive?(session)
    after
      resume_if_suspended(owner)
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end
  end

  test "active credential resolution dies when its provider session closes" do
    parent = self()
    {:ok, prepared, catalog} = credential_fixture()

    resolver = fn ["secret"] ->
      send(parent, {:session_close_credential_worker, self()})
      receive do: (:never -> {:ok, %{}})
    end

    owner =
      spawn(fn ->
        {:ok, session} = open_owned(prepared, catalog, services())
        send(parent, {:session_close_credential_session, session})
        {:ok, registry} = credential_registry(resolver)
        result = build_owned(prepared, catalog, registry, session, [])
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

  test "active preflight release still runs after the provider session closes" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end)
        {:ok, session} = open_owned(prepared, catalog, services())
        send(parent, {:release_after_close_session, session})

        staged = fn _selection, _context ->
          {:ok,
           %{
             credential_names: [],
             preflight: fn ->
               {:ok,
                fn %{} ->
                  send(parent, {:release_after_close_acquisition, self()})
                  receive do: (:never -> {:error, :unexpected_acquisition_result})
                end,
                fn ->
                  send(parent, {:release_after_close_ran, self()})
                  :ok
                end}
             end
           }}
        end

        {:ok, registry} =
          ProviderRegistry.new(%{"selected" => ProviderRegistry.staged(staged)})

        result = build_owned(prepared, catalog, registry, session, [])
        send(parent, {:release_after_close_result, result})
        :ok = PreparedRun.close(prepared)
      end)

    owner_ref = Process.monitor(owner)

    assert_receive {:release_after_close_session, session}, 1_000
    assert_receive {:release_after_close_acquisition, acquisition_worker}, 1_000
    acquisition_ref = Process.monitor(acquisition_worker)
    assert :ok = ProviderSession.close(session)

    assert_receive {:DOWN, ^acquisition_ref, :process, ^acquisition_worker, :killed}, 1_000
    assert_receive {:release_after_close_ran, release_worker}, 1_000
    refute release_worker == acquisition_worker
    assert_receive {:release_after_close_result, {:error, _reason}}, 1_000
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 1_000
  end

  test "active credential resolution dies with its caller and session" do
    parent = self()
    {:ok, prepared, catalog} = credential_fixture()

    resolver = fn ["secret"] ->
      send(parent, {:caller_death_credential_worker, self()})
      receive do: (:never -> {:ok, %{}})
    end

    owner =
      spawn(fn ->
        {:ok, session} = open_owned(prepared, catalog, services())
        send(parent, {:caller_death_credential_session, session})
        {:ok, registry} = credential_registry(resolver)
        build_owned(prepared, catalog, registry, session, [])
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
    assert {:ok, first_session} = open_owned(first, first_catalog, services())
    assert {:ok, second_session} = open_owned(second, second_catalog, services())
    assert {:ok, registry} = ProviderRegistry.new(%{})

    assert {:error, :invalid_active_run} =
             build_owned(second, second_catalog, registry, first_session, [])

    refute ProviderSession.alive?(first_session)
    assert :ok = ProviderSession.close(second_session)
    assert :ok = PreparedRun.close(first)
    assert :ok = PreparedRun.close(second)
  end

  test "active build rejects cloned identity with a different run duration before preparation" do
    parent = self()
    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end)
    assert {:ok, opened_session} = open_owned(prepared, catalog, services())
    assert :ok = ProviderSession.close(opened_session)

    limits = prepared.request.package.limits
    other_limits = %{limits | run_duration_ms: limits.run_duration_ms + 1}

    assert {:ok, wrong_session} =
             ProviderSession.start_active(other_limits, prepared.attestation)

    assert {:ok, wrong_session} =
             ProviderSession.begin_operation(wrong_session, :run)

    staged = fn _selection, _context ->
      send(parent, :unexpected_provider_preparation)
      {:error, :unexpected_provider_preparation}
    end

    assert {:ok, registry} =
             ProviderRegistry.new(%{"selected" => ProviderRegistry.staged(staged)})

    assert {:error, :invalid_active_run} =
             build_owned(prepared, catalog, registry, wrong_session, [])

    refute_receive :unexpected_provider_preparation
    refute ProviderSession.alive?(wrong_session)
    assert :ok = PreparedRun.close(prepared)
  end

  test "active build claims its session once without closing it on replay" do
    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end)
    assert {:ok, session} = open_owned(prepared, catalog, services())
    assert {:ok, registry} = active_registry()

    assert {:ok, built} = build_owned(prepared, catalog, registry, session, [])
    assert built.config.run_deadline == ProviderSession.run_deadline(session)

    assert {:error, :invalid_active_run} =
             build_owned(prepared, catalog, registry, session, [])

    assert {:error, :invalid_active_run} =
             build_owned(prepared, catalog, registry, session, unknown: true)

    {:ok, other, other_catalog} = fixture(fn _selection, _context -> :ok end)
    assert {:ok, other_session} = open_owned(other, other_catalog, services())

    assert {:error, :invalid_active_run} =
             build_owned(other, other_catalog, registry, session, [])

    assert ProviderSession.alive?(session)

    assert :ok = RunBuilder.close(built)
    assert :ok = ProviderSession.close(other_session)
    assert :ok = PreparedRun.close(prepared)
    assert :ok = PreparedRun.close(other)
  end

  @tag timeout: 10_000
  test "a timed-out replay cannot close a claimed active session" do
    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end)
    assert {:ok, session} = open_owned(prepared, catalog, services())
    assert {:ok, registry} = active_registry()
    assert {:ok, built} = build_owned(prepared, catalog, registry, session, [])

    assert true = :erlang.suspend_process(session.pid)

    try do
      assert {:error, :invalid_active_run} =
               build_owned(prepared, catalog, registry, session, [])
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
               open_owned(prepared, catalog, services())
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
             open_owned(prepared, catalog, services())

    assert_receive {:validator_started, worker}
    refute Process.alive?(worker)
  end

  test "a deadline spent at the validator dispatch fence reports no activity" do
    {:ok, prepared, _catalog} = fixture(fn _selection, _context -> :ok end)

    assert {:error,
            %CommandDiagnostic{
              code: :selection_validation_timeout,
              provider_activity: false
            }} = dispatch_after_expiry(prepared, false)

    refute_received :unexpected_validator_dispatch
    assert :ok = PreparedRun.close(prepared)
  end

  test "a deadline spent at a later validator dispatch fence preserves earlier activity" do
    {:ok, prepared, _catalog} = fixture(fn _selection, _context -> :ok end)

    assert {:error,
            %CommandDiagnostic{
              code: :selection_validation_timeout,
              provider_activity: true
            }} = dispatch_after_expiry(prepared, true)

    refute_received :unexpected_validator_dispatch
    assert :ok = PreparedRun.close(prepared)
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

        send(parent, {:late_result, open_owned(prepared, catalog, services())})
      end)

    # The owner compiles its fixture and opens the execution owner's sinks
    # before the validator runs, which is slower than the default window on a
    # cold start.
    assert_receive {:late_result_worker, worker}, 5_000
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
    assert {:ok, session} = open_owned(prepared, catalog, services())
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
        open_owned(prepared, catalog, services())
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
             open_owned(prepared, other_catalog, services())

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
    assert {:ok, session} = open_owned(prepared, catalog, services())
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
              provider_activity: false
            } = diagnostic} =
             open_owned(prepared, catalog, services(:host_owned))

    assert diagnostic.subject.name == "selected"
    assert diagnostic.subject.operation == :application
    assert diagnostic.subject.occurrence == nil
    assert ProviderActivity.value(prepared.provider_activity) == true
    assert :ok = PreparedRun.close(prepared)
  end

  @tag :tmp_dir
  test "command VM startup disables dotenv readers and warms provider metadata", %{
    tmp_dir: directory
  } do
    restore_provider_applications_on_exit()
    stop_provider_applications()
    previous_adapter = Application.get_env(:ptc_runner, :llm_adapter)
    previous_owner = Application.get_env(:ptc_runner, :host_llm_test_owner)
    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())
    Application.put_env(:req_llm, :load_dotenv, true, persistent: true)
    Application.put_env(:llm_db, :load_dotenv, true, persistent: true)

    on_exit(fn ->
      restore_env(:llm_adapter, previous_adapter)
      restore_env(:host_llm_test_owner, previous_owner)
    end)

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
               open_owned(prepared, catalog, services(:command_vm))

      assert Application.get_env(:req_llm, :load_dotenv) == false
      assert Application.get_env(:llm_db, :load_dotenv) == false
      assert System.get_env(sentinel) == nil
      assert :req_llm in started_applications()
      assert :llm_db in started_applications()
      assert_receive {:host_llm_ensure_ready, warmup_pid}
      assert warmup_pid == self()

      close(session, prepared)
    end)
  end

  test "command VM sizes one ReqLLM pool from the installed provider ceiling" do
    restore_provider_applications_on_exit()
    stop_provider_applications()
    Application.delete_env(:req_llm, :finch, persistent: true)
    Application.delete_env(:req_llm, :stream_pool_protocols, persistent: true)

    {:ok, installed_limits} = Limits.installed(live_provider_tasks: 6)

    {:ok, prepared, catalog} =
      fixture(
        fn _selection, _context -> :ok end,
        ["first"],
        installed_limits,
        "installed-pool-v1",
        :req_llm,
        [],
        %{"live_provider_tasks" => 2}
      )

    assert prepared.request.package.limits.live_provider_tasks == 2
    assert catalog.installed_limits.live_provider_tasks == 6
    assert {:ok, session} = open_owned(prepared, catalog, services(:command_vm))

    assert Application.get_env(:req_llm, :stream_pool_count) == 1
    assert Application.get_env(:req_llm, :stream_pool_size) == 6

    assert %{default: default_pool} =
             ReqLLM.Application.get_finch_config() |> Keyword.fetch!(:pools)

    assert Keyword.fetch!(default_pool, :count) == 1
    assert Keyword.fetch!(default_pool, :size) == 6

    close(session, prepared)
  end

  test "one command-owned ReqLLM pool admits eight simultaneously held requests" do
    restore_provider_applications_on_exit()
    stop_provider_applications()
    Application.delete_env(:req_llm, :finch, persistent: true)
    Application.delete_env(:req_llm, :stream_pool_protocols, persistent: true)

    {:ok, prepared, catalog} =
      fixture(fn _selection, _context -> :ok end, ["first"], nil, "pool-contention-v1", :req_llm)

    assert {:ok, session} = open_owned(prepared, catalog, services(:command_vm))

    parent = self()
    release_gate = spawn(fn -> receive do: (:release -> :ok) end)

    server =
      MCPHTTPFixture.start(fn _request ->
        release_ref = Process.monitor(release_gate)
        send(parent, {:held_finch_request, self()})

        receive do
          {:DOWN, ^release_ref, :process, ^release_gate, _reason} -> {200, [], "ok"}
        end
      end)

    start_ref = make_ref()
    shared_hash_key = make_ref()

    requesters =
      Enum.map(1..8, fn _index ->
        spawn_monitor(fn ->
          send(parent, {:finch_request_ready, self()})

          receive do
            {:start_finch_request, ^start_ref} ->
              request = Finch.build(:get, server.endpoint)

              result =
                Finch.request(request, ReqLLM.Finch,
                  pool_strategy: {Finch.Pool.Strategy.Hash, shared_hash_key},
                  pool_timeout: 2_000,
                  receive_timeout: 10_000
                )

              send(parent, {:finch_request_result, self(), result})
          end
        end)
      end)

    try do
      requester_pids = Enum.map(requesters, &elem(&1, 0))

      Enum.each(requester_pids, fn requester ->
        assert_receive {:finch_request_ready, ^requester}
      end)

      Enum.each(requester_pids, &send(&1, {:start_finch_request, start_ref}))

      # The observation window deliberately exceeds the pool checkout timeout:
      # the old eight-by-one geometry can admit only one request for this shared
      # hash key before its seven waiters time out, while the one-by-eight pool
      # admits all eight even on a loaded CI scheduler.
      held = collect_held_finch_requests(8, Deadline.new(5_000), [])
      assert length(held) == 8

      send(release_gate, :release)

      Enum.each(requester_pids, fn requester ->
        assert_receive {:finch_request_result, ^requester, {:ok, %Finch.Response{status: 200}}},
                       2_000
      end)
    after
      if Process.alive?(release_gate), do: Process.exit(release_gate, :kill)
      server.close.()

      Enum.each(requesters, fn {pid, monitor} ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
      end)

      close(session, prepared)
    end
  end

  test "command VM preserves an explicit HTTP/2 ReqLLM pool" do
    restore_provider_applications_on_exit()
    stop_provider_applications()
    Application.delete_env(:req_llm, :finch, persistent: true)
    Application.put_env(:req_llm, :stream_pool_protocols, [:http2], persistent: true)
    Application.put_env(:req_llm, :stream_pool_count, 3, persistent: true)
    Application.put_env(:req_llm, :stream_pool_size, 4, persistent: true)

    {:ok, prepared, catalog} =
      fixture(fn _selection, _context -> :ok end, ["first"], nil, "http2-pool-v1", :req_llm)

    assert {:ok, session} = open_owned(prepared, catalog, services(:command_vm))
    assert Application.get_env(:req_llm, :stream_pool_protocols) == [:http2]
    assert Application.get_env(:req_llm, :stream_pool_count) == 3
    assert Application.get_env(:req_llm, :stream_pool_size) == 4

    assert %{default: default_pool} =
             ReqLLM.Application.get_finch_config() |> Keyword.fetch!(:pools)

    assert Keyword.fetch!(default_pool, :protocols) == [:http2]
    assert Keyword.fetch!(default_pool, :count) == 3
    assert Keyword.fetch!(default_pool, :size) == 4

    close(session, prepared)
  end

  test "command VM mode rejects a prestarted target while host-owned mode accepts it" do
    restore_provider_applications_on_exit()
    stop_provider_applications()
    Application.put_env(:req_llm, :load_dotenv, false, persistent: true)
    Application.put_env(:llm_db, :load_dotenv, false, persistent: true)
    Application.put_env(:req_llm, :stream_pool_count, 3, persistent: true)
    Application.put_env(:req_llm, :stream_pool_size, 4, persistent: true)
    Application.put_env(:req_llm, :finch, [name: ReqLLM.Finch], persistent: true)
    assert {:ok, _started} = Application.ensure_all_started(:req_llm)

    {:ok, command_prepared, command_catalog} =
      fixture(fn _selection, _context -> :ok end, ["first"], nil, "command-v1", :req_llm)

    assert {:error,
            %CommandDiagnostic{code: :provider_application_unavailable, provider_activity: false}} =
             open_owned(
               command_prepared,
               command_catalog,
               services(:command_vm)
             )

    assert Application.get_env(:req_llm, :stream_pool_count) == 3
    assert Application.get_env(:req_llm, :stream_pool_size) == 4
    assert Application.get_env(:req_llm, :finch) == [name: ReqLLM.Finch]

    {:ok, host_prepared, host_catalog} =
      fixture(fn _selection, _context -> :ok end, ["first"], nil, "host-v1", :req_llm)

    assert {:ok, session} =
             open_owned(host_prepared, host_catalog, services(:host_owned))

    assert Application.get_env(:req_llm, :stream_pool_count) == 3
    assert Application.get_env(:req_llm, :stream_pool_size) == 4
    assert Application.get_env(:req_llm, :finch) == [name: ReqLLM.Finch]

    close(session, host_prepared)
  end

  test "provider-free command VM admission leaves ReqLLM configuration unchanged" do
    restore_provider_applications_on_exit()
    stop_provider_applications()
    Application.put_env(:req_llm, :stream_pool_count, 3, persistent: true)
    Application.put_env(:req_llm, :stream_pool_size, 4, persistent: true)
    Application.put_env(:req_llm, :finch, [name: ReqLLM.Finch], persistent: true)

    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end)
    assert {:ok, session} = open_owned(prepared, catalog, services(:command_vm))

    assert Application.get_env(:req_llm, :stream_pool_count) == 3
    assert Application.get_env(:req_llm, :stream_pool_size) == 4
    assert Application.get_env(:req_llm, :finch) == [name: ReqLLM.Finch]
    refute :req_llm in started_applications()

    close(session, prepared)
  end

  test "command VM startup failures preserve attempted provider activity" do
    restore_provider_applications_on_exit()
    stop_provider_applications()
    Application.put_env(:req_llm, :finch, %{}, persistent: true)
    Application.delete_env(:req_llm, :stream_pool_protocols, persistent: true)
    # Seeded rather than deleted: the subject is that a failed start leaves the
    # pool geometry exactly as it found it, which an absent key cannot tell
    # apart from a start that wrote the same value another test had left behind.
    Application.put_env(:req_llm, :stream_pool_count, 5, persistent: true)
    Application.put_env(:req_llm, :stream_pool_size, 6, persistent: true)

    {:ok, prepared, catalog} =
      fixture(fn _selection, _context -> :ok end, ["first"], nil, "command-v1", :req_llm)

    assert {:error,
            %CommandDiagnostic{code: :provider_application_unavailable, provider_activity: true}} =
             open_owned(prepared, catalog, services(:command_vm))

    assert Application.get_env(:req_llm, :stream_pool_count) == 5
    assert Application.get_env(:req_llm, :stream_pool_size) == 6
    assert ProviderActivity.value(prepared.provider_activity) == true
    assert :ok = PreparedRun.close(prepared)
  end

  # The sealed descriptor is what phase-8 step 5 derives its union from, so a
  # fixture whose builder asks for a credential has to declare it too. A builder
  # asking for one its declaration omits is drift, and is refused rather than
  # resolved; that is its own regression rather than these tests' subject.
  defp credential_fixture(limits \\ nil),
    do:
      fixture(
        fn _selection, _context -> :ok end,
        ["first"],
        limits,
        "custom-v1",
        nil,
        ["secret"]
      )

  defp fixture(
         callback,
         modes \\ ["first"],
         limits \\ nil,
         revision \\ "custom-v1",
         provider_application \\ nil,
         credential_names \\ [],
         manifest_limits \\ %{}
       ) do
    limits = limits || Limits.installed_defaults()
    {:ok, rules} = rules()

    {:ok, descriptor} =
      ProviderDescriptor.new(
        source: :custom,
        installation_revision: revision,
        credential_names: credential_names,
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
      },
      "limits" => manifest_limits
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

  defp wait_until_expired(deadline) do
    if Deadline.expired?(deadline) do
      :ok
    else
      receive do
      after
        0 -> wait_until_expired(deadline)
      end
    end
  end

  defp dispatch_after_expiry(prepared, provider_activity) do
    parent = self()
    declaration = hd(prepared.provider_declarations)

    owner =
      spawn(fn ->
        deadline = Deadline.new(100)
        send(parent, {:dispatch_fenced, self(), deadline})

        receive do
          :release_dispatch ->
            dispatch = fn _timeout_ms ->
              send(parent, :unexpected_validator_dispatch)
              {:ok, :ok}
            end

            result =
              ProviderActiveSession.dispatch_validator(
                deadline,
                dispatch,
                declaration,
                provider_activity
              )

            send(parent, {:dispatch_result, self(), result})
        end
      end)

    monitor = Process.monitor(owner)

    try do
      assert_receive {:dispatch_fenced, ^owner, deadline}, 1_000
      wait_until_expired(deadline)
      send(owner, :release_dispatch)
      assert_receive {:dispatch_result, ^owner, result}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 1_000
      result
    after
      if Process.alive?(owner), do: Process.exit(owner, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp resume_if_suspended(pid) do
    if Process.alive?(pid), do: :erlang.resume_process(pid)
  catch
    :error, :badarg -> true
  end

  # The execution owner is the only session opener left, so tests take the same
  # route it does: open the owner's sinks (which consumes the prepared run),
  # hand the session to a fixed lifecycle owner, and begin the run there.
  defp open_owned(prepared, catalog, services) do
    with {:ok, _inputs} <- owned_inputs(prepared),
         {:ok, session} <- open_owned_setup(prepared, catalog, services) do
      ProviderActiveSession.begin_owned_operation(session, prepared, catalog, services, :run)
    end
  end

  defp open_owned_setup(prepared, catalog, services) do
    with {:ok, _inputs} <- owned_inputs(prepared) do
      ProviderActiveSession.open_consumed_setup(
        prepared,
        catalog,
        services,
        self(),
        fn _session -> :ok end
      )
    end
  end

  # Opened once per prepared run and remembered, because opening the sinks is
  # what consumes it. A spawned build passes the captured value explicitly,
  # since it does not inherit this process's dictionary. The sinks monitor the
  # process that opened them and exit with it, so no test teardown is needed —
  # and registering one here would raise in a spawned caller.
  defp owned_inputs(prepared) do
    case Process.get({:owned_inputs, prepared.attestation}) do
      nil ->
        with {:ok, authority} <- PublicationAuthority.new([]),
             {:ok, sinks} <- RunBuilder.open_prepared_sinks(prepared, authority, self()) do
          Process.put({:owned_inputs, prepared.attestation}, {authority, sinks})
          {:ok, {authority, sinks}}
        end

      inputs ->
        {:ok, inputs}
    end
  end

  defp owned_inputs!(prepared) do
    {:ok, inputs} = owned_inputs(prepared)
    inputs
  end

  # The provider lifecycle messages in the order they were actually sent.
  # `assert_receive` matches anywhere in the mailbox, so it cannot show order.
  defp drained_phases(accumulated \\ []) do
    receive do
      phase
      when phase in [
             :credential_resolved,
             :credential_prepared,
             :credential_preflighted,
             :credential_acquired
           ] ->
        drained_phases([phase | accumulated])
    after
      0 -> Enum.reverse(accumulated)
    end
  end

  # A faithful miniature of the phase-8 sequence `ProviderExecution` runs: step 5
  # resolves the sealed credential union before any provider callback, and the
  # execution owner closes the session whichever step fails. Resolving here
  # rather than handing over a literal map is what keeps these tests pinned to
  # the shipped derivation instead of one this file invented.
  defp build_owned(prepared, catalog, registry, session, opts) do
    case ProviderCredentials.resolve(prepared, catalog, registry, session, true) do
      {:ok, credentials} ->
        build_owned(
          owned_inputs!(prepared),
          prepared,
          catalog,
          registry,
          session,
          credentials,
          opts
        )

      {:error, _diagnostic} = error ->
        if ProviderSession.alive?(session), do: ProviderSession.close(session)
        error
    end
  end

  defp build_owned({authority, sinks}, prepared, catalog, registry, session, credentials, _opts) do
    RunBuilder.build_active_owned(
      prepared,
      catalog,
      registry,
      session,
      authority,
      sinks,
      credentials
    )
  end

  defp services(mode \\ :host_owned) do
    {:ok, services} = ProviderRuntimeServices.new(provider_application_mode: mode)
    services
  end

  defp started_applications,
    do: Application.started_applications() |> Enum.map(&elem(&1, 0))

  defp stop_provider_applications do
    LLMSupport.stop_provider_applications()
  end

  defp restore_provider_applications_on_exit do
    snapshot = LLMSupport.snapshot_provider_applications()
    on_exit(fn -> LLMSupport.restore_provider_applications(snapshot) end)
  end

  defp collect_held_finch_requests(0, _deadline, held), do: held

  defp collect_held_finch_requests(remaining, deadline, held) do
    case Deadline.remaining(deadline) do
      0 ->
        held

      timeout_ms ->
        receive do
          {:held_finch_request, holder} ->
            collect_held_finch_requests(remaining - 1, deadline, [holder | held])
        after
          timeout_ms -> held
        end
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_runner, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_runner, key, value)
end
