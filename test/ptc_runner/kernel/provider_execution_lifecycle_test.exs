defmodule PtcRunner.Kernel.ProviderExecutionLifecycleTest do
  use ExUnit.Case, async: true
  import PtcRunner.TestSupport.ProviderExecutionLifecycleFixture
  import PtcRunner.TestSupport.ProviderExecutionFixture

  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.OwnerFailure
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.RunCoordinator

  test "caller death while provider setup blocks leaves no session, sink, or activity" do
    parent = self()

    fixture =
      provider_fixture(
        selection_validation: :active,
        selection_validator: fn _selection, _context ->
          send(parent, {:blocked_in, :selection_validation, self()})
          block_forever()
        end
      )

    started = start_owned_execution(fixture)
    assert_receive {:blocked_in, :selection_validation, validator}, 5_000
    state = :sys.get_state(started.owner_pid)
    assert ProviderSession.valid?(state.provider_session)
    assert is_nil(state.registry)

    watched =
      watch(%{
        owner: started.owner_pid,
        worker: state.worker_pid,
        session: state.provider_session.pid,
        validator: validator,
        event_sink: state.opened_sinks.event_sink.pid,
        activity: fixture.prepared.provider_activity.owner
      })

    Process.exit(started.caller, :kill)

    assert_all_down(watched)
    refute_received {:execution_result, _result}
  end

  test "caller death during provider-backed Kernel execution stops every owned resource" do
    parent = self()

    fixture =
      provider_fixture(
        body: "(return (tool/fixture {}))",
        acquire: fn _context ->
          send(parent, {:acquired, self()})
          {:ok, capability} = blocked_fixture_capability(parent)
          {:ok, %{capabilities: [capability]}}
        end
      )

    started = start_owned_execution(fixture)
    assert_receive {:acquired, _acquirer}, 5_000
    assert_receive {:fixture_running, _callback}, 5_000
    state = :sys.get_state(started.owner_pid)
    assert ProviderSession.valid?(state.provider_session)

    watched =
      watch(%{
        owner: started.owner_pid,
        worker: state.worker_pid,
        session: state.provider_session.pid,
        event_sink: state.opened_sinks.event_sink.pid,
        activity: fixture.prepared.provider_activity.owner
      })

    Process.exit(started.caller, :kill)

    assert_all_down(watched)
    refute_received {:execution_result, _result}
  end

  test "worker death releases every owner-held resource and fails the awaiting caller" do
    parent = self()

    fixture =
      provider_fixture(
        acquire: fn context ->
          scoped_root(parent, context)
          send(parent, {:blocked_in, :provider_acquire, self()})
          block_forever()
        end
      )

    started = start_owned_execution(fixture)
    assert_receive {:provider_root, root, :ok}, 5_000
    assert_receive {:blocked_in, :provider_acquire, _acquirer}, 5_000
    state = :sys.get_state(started.owner_pid)

    watched =
      watch(%{
        owner: started.owner_pid,
        session: state.provider_session.pid,
        provider_root: root,
        event_sink: state.opened_sinks.event_sink.pid,
        activity: fixture.prepared.provider_activity.owner
      })

    Process.exit(state.worker_pid, :kill)

    assert_receive {:execution_result, {:error, failure}}, 5_000

    assert {:ok, :execution_session_unavailable, true, :incomplete} =
             OwnerFailure.evidence(failure)

    assert_all_down(watched)
  end

  test "a refusing provider closer outranks the worker-death error it would hide" do
    # Acquisition commits a closer that refuses and the Kernel run then blocks,
    # so the session is committed, bound, and still owner-held when the worker
    # dies before it can reach normal Runner teardown.
    parent = self()

    fixture =
      provider_fixture(
        body: "(return (tool/fixture {}))",
        acquire: fn _context ->
          {:ok, capability} = blocked_fixture_capability(parent)
          {:ok, %{capabilities: [capability], close: fn -> :failed end}}
        end
      )

    started = start_owned_execution(fixture)
    assert_receive {:fixture_running, _callback}, 5_000
    state = :sys.get_state(started.owner_pid)

    # Killing on the acquire callback would race `ResourceRegistrar.commit/2`,
    # so wait until the session actually holds the committed closer.
    assert_eventually(fn -> :sys.get_state(state.provider_session.pid).committed != [] end)
    assert ProviderSession.alive?(state.provider_session)

    Process.exit(state.worker_pid, :kill)

    assert_receive {:execution_result, observed}, 5_000
    assert {:error, %CommandDiagnostic{} = diagnostic} = observed
    assert diagnostic.phase == :result_cleanup
    assert diagnostic.code == :provider_cleanup_failed
    assert diagnostic.provider_activity
  end

  defp blocked_fixture_capability(parent) do
    Capability.new(
      name: "fixture",
      input_schema: %{"type" => "object", "additionalProperties" => false},
      callback: fn _arguments ->
        send(parent, {:fixture_running, self()})

        receive do
          :release -> {:ok, %{}}
        end
      end
    )
  end

  test "a refusing closer outranks a post-acquisition build failure in the worker" do
    # The oversized connector snapshot fails `RunConfig.new/1` after acquisition
    # has already committed the refusing closer, which is the one shape that
    # leaves the session open for the worker itself to close.
    fixture =
      provider_fixture(
        acquire: fn _context ->
          {:ok, capability} = fixture_capability()

          {:ok,
           %{
             capabilities: [capability],
             snapshot: %{"padding" => String.duplicate("x", 300_000)},
             close: fn -> :failed end
           }}
        end
      )

    parent = self()

    caller =
      spawn(fn ->
        {:ok, owner} =
          ExecutionSessionOwner.start(
            fixture.prepared,
            fixture.authority,
            self(),
            fixture.execution,
            unexpected_notifier()
          )

        send(parent, {:execution_owner, owner})
        send(parent, {:execution_result, ExecutionSessionOwner.await(owner)})
      end)

    assert_receive {:execution_owner, owner}, 5_000
    on_exit(fn -> release(caller, ExecutionSessionOwner.pid(owner)) end)

    assert_receive {:execution_result, observed}, 5_000
    assert {:error, %CommandDiagnostic{} = diagnostic} = observed
    assert diagnostic.phase == :result_cleanup
    assert diagnostic.code == :provider_cleanup_failed
  end

  test "an unresolvable credential fails a run before any provider callback" do
    # Phase-8 step 5 is what moved: a run used to prepare and preflight every
    # selected provider and only then discover its credential was unavailable,
    # paying for callbacks against a command that could never complete. The
    # union now comes from the sealed declarations, so it can be — and is —
    # resolved while every provider is still inert.
    parent = self()

    fixture =
      provider_fixture(
        credential_names: ["fixture-key"],
        credential_resolver: fn names ->
          send(parent, {:resolved_credentials, names})
          {:error, :credential_unavailable}
        end
      )

    _started = start_owned_execution(fixture)

    assert_receive {:execution_result, {:error, %CommandDiagnostic{} = diagnostic}}, 5_000
    assert diagnostic.phase == :active_preflight
    assert diagnostic.code == :credential_unavailable
    refute diagnostic.provider_activity

    # Attribution is per alias, not per occurrence: the catalogue forbids an
    # occurrence on this pair, and the resolver answers for the whole batch
    # rather than naming which credential failed.
    assert diagnostic.subject.name == "selected"
    assert diagnostic.subject.operation == :credentials
    assert diagnostic.subject.occurrence == nil

    assert_received {:resolved_credentials, ["fixture-key"]}
    refute_received {:provider_phase, :prepare}
    refute_received {:provider_phase, :preflight}
    refute_received {:provider_phase, :acquire}
    refute_received {:provider_root, _root, _registration}
  end

  test "a credential failure after active selection validation preserves provider activity" do
    parent = self()

    fixture =
      provider_fixture(
        credential_names: ["fixture-key"],
        credential_resolver: fn _names -> {:error, :credential_unavailable} end,
        selection_validation: :active,
        selection_validator: fn _selection, _context ->
          send(parent, :selection_validated)
          :ok
        end
      )

    _started = start_owned_execution(fixture)

    assert_receive {:execution_result, {:error, %CommandDiagnostic{} = diagnostic}}, 5_000
    assert diagnostic.code == :credential_unavailable
    assert diagnostic.provider_activity
    assert_received :selection_validated
    refute_received {:provider_phase, :prepare}
  end

  test "an explicit nil provider application does not create credential activity" do
    fixture =
      provider_fixture(
        credential_names: ["fixture-key"],
        credential_resolver: fn _names -> {:error, :credential_unavailable} end,
        provider_application: nil,
        provider_application_mode: :command_vm
      )

    _started = start_owned_execution(fixture)

    assert_receive {:execution_result, {:error, %CommandDiagnostic{} = diagnostic}}, 5_000
    assert diagnostic.code == :credential_unavailable
    refute diagnostic.provider_activity
  end

  test "a run refuses a builder asking for a credential its declaration omits" do
    # The sealed declaration decides what may be read, so a builder cannot widen
    # it at run time. Connectivity gets this from `declarations_honored/2`, which
    # compares against a plan; an ordinary run has no plan, and the supplied
    # union is the guard in its place — a name the declarations never required
    # cannot appear in it, and acquisition refuses rather than resolving again.
    fixture = provider_fixture(credential_names: [], builder_credential_names: ["smuggled"])

    _started = start_owned_execution(fixture)

    assert_receive {:execution_result, {:error, %CommandDiagnostic{} = diagnostic}}, 5_000
    assert diagnostic.phase == :provider_acquisition
    assert diagnostic.code == :provider_policy_changed
    assert diagnostic.subject.name == "selected"
    assert diagnostic.subject.occurrence == %{destination: :workflow, index: 0}

    # Nothing declared a credential, so step 5 asked the resolver for nothing,
    # and the smuggled name reached it by no other route either.
    refute_received {:resolved_credentials, _names}
    assert_received {:provider_phase, :prepare}
    refute_received {:provider_phase, :preflight}
    refute_received {:provider_phase, :acquire}
    refute_received {:provider_root, _root, _registration}
  end

  test "staged preparations that disagree with sealed declarations are refused" do
    for {options, effective_class} <- [
          {[
             descriptor_accepts_data: [:normal, :private_inspection],
             staged_data_class: :private_inspection,
             staged_accepts_data: [:normal, :private_inspection]
           ], :normal},
          {[
             descriptor_data_class: :private_inspection,
             descriptor_accepts_data: [:normal, :private_inspection],
             staged_accepts_data: [:normal, :private_inspection]
           ], :private_inspection},
          {[
             descriptor_accepts_data: [:normal],
             staged_accepts_data: [:normal, :private_inspection]
           ], :normal},
          {[
             descriptor_accepts_data: [:normal, :private_inspection],
             staged_accepts_data: [:normal]
           ], :normal}
        ] do
      fixture = provider_fixture([credential_names: ["fixture-key"]] ++ options)
      assert fixture.prepared.effective_data_class == effective_class
      assert_declaration_refused(fixture)
    end
  end

  test "connectivity registry activation timeout preserves the attempted prefix" do
    parent = self()

    for {selection_validation, expected_activity} <- [
          {:declarative, false},
          {:active, true}
        ] do
      activation = fn ->
        send(parent, {:registry_activation_started, selection_validation})
        block_forever()
      end

      fixture =
        provider_fixture(
          activation: activation,
          doctor_connectivity_timeout_ms: 100,
          selection_validation: selection_validation,
          selection_validator: fn _selection, _context -> :ok end
        )

      _started = start_owned_execution(fixture, :connect)
      assert_receive {:registry_activation_started, ^selection_validation}, 5_000

      assert_receive {:execution_result, {:error, %CommandDiagnostic{} = diagnostic}}, 5_000
      assert diagnostic.phase == :active_preflight
      assert diagnostic.code == :connectivity_timeout
      assert diagnostic.provider_activity == expected_activity
    end
  end

  test "an execution from another catalog leaves the prepared run reusable" do
    fixture = provider_fixture()
    other = provider_fixture(installation_revision: "other-v1")

    assert {:error, :invalid_provider_execution} =
             RunCoordinator.execute(
               fixture.prepared,
               fixture.authority,
               other.execution,
               unexpected_notifier()
             )

    assert PreparedRun.valid?(fixture.prepared)
    assert ProviderActivity.value(fixture.prepared.provider_activity) == false

    assert {:error, :invalid_provider_execution} =
             ExecutionSessionOwner.start(
               fixture.prepared,
               fixture.authority,
               self(),
               other.execution,
               unexpected_notifier()
             )

    assert PreparedRun.valid?(fixture.prepared)
    assert :ok = PreparedRun.close(fixture.prepared)
    assert :ok = PreparedRun.close(other.prepared)
  end
end
