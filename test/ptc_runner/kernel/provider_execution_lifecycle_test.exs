defmodule PtcRunner.Kernel.ProviderExecutionLifecycleTest do
  use ExUnit.Case, async: false

  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]
  import PtcRunner.TestSupport.TestHelpers, only: [long_running_body: 0]

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.ResourceRegistrar
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules

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

  test "caller death runs a committed closer before the runtime that produced it closes" do
    # A committed provider closer belongs to the runtime that acquired it: it
    # may still release an admission, persist a token response, or reach the
    # authority the registry holds. Aborting must therefore close the session
    # first and leave that runtime standing until the closer has settled.
    parent = self()

    fixture =
      provider_fixture(
        body: long_running_body(),
        acquire: fn context ->
          scoped_root(parent, context)
          {:ok, capability} = fixture_capability()

          {:ok,
           %{
             capabilities: [capability],
             close: fn ->
               send(parent, {:provider_closing, self()})
               receive do: (:release -> :ok)
             end
           }}
        end
      )

    started = start_owned_execution(fixture)
    state = await_state(started.owner_pid, & &1.registry)

    # Killing on the acquire callback would race `ResourceRegistrar.commit/2`,
    # so wait until the session actually holds the committed closer.
    assert_eventually(fn -> :sys.get_state(state.provider_session.pid).committed != [] end)

    trace_closes(started.owner_pid)

    try do
      Process.exit(started.caller, :kill)

      # The session is the first thing the abort closes...
      assert ProviderSession == next_close()
      assert_receive {:provider_closing, closer}, 5_000

      # ...and the owner is blocked inside that close while the committed closer
      # runs, so nothing can have unwound the registry underneath it yet.
      refute_received {:trace, _owner, :call, {ProviderRegistry, :close, _arguments}}

      send(closer, :release)
      assert ProviderRegistry == next_close()
    after
      stop_trace_closes(started.owner_pid)
    end

    refute_received {:execution_result, _result}
  end

  test "caller death while acquisition blocks closes the session before the registry" do
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
    assert_receive {:blocked_in, :provider_acquire, acquirer}, 5_000
    state = :sys.get_state(started.owner_pid)
    assert ProviderSession.valid?(state.provider_session)
    assert ProviderRegistry.valid?(state.registry)

    watched =
      watch(%{
        owner: started.owner_pid,
        worker: state.worker_pid,
        session: state.provider_session.pid,
        provider_root: root,
        acquirer: acquirer,
        event_sink: state.opened_sinks.event_sink.pid,
        activity: fixture.prepared.provider_activity.owner
      })

    trace_closes(started.owner_pid)

    try do
      Process.exit(started.caller, :kill)

      assert [ProviderSession, ProviderRegistry] == [next_close(), next_close()]
      assert_all_down(watched)
    after
      stop_trace_closes(started.owner_pid)
    end

    refute_received {:execution_result, _result}
  end

  test "caller death during provider-backed Kernel execution stops every owned resource" do
    parent = self()

    fixture =
      provider_fixture(
        body: long_running_body(),
        acquire: fn _context ->
          send(parent, {:acquired, self()})
          fixture_capability()
        end
      )

    started = start_owned_execution(fixture)
    assert_receive {:acquired, _acquirer}, 5_000
    state = await_state(started.owner_pid, & &1.registry)
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

    assert_receive {:execution_result, {:error, :execution_session_unavailable}}, 5_000
    assert_all_down(watched)
  end

  test "a refusing provider closer outranks the worker-death error it would hide" do
    # Acquisition commits a closer that refuses and the Kernel run then blocks,
    # so the session is committed, bound, and still owner-held when the worker
    # dies before it can reach normal Runner teardown.
    fixture =
      provider_fixture(
        body: long_running_body(),
        acquire: fn _context ->
          {:ok, capability} = fixture_capability()
          {:ok, %{capabilities: [capability], close: fn -> :failed end}}
        end
      )

    started = start_owned_execution(fixture)
    state = await_state(started.owner_pid, & &1.registry)

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
            &never_notify/1
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
    assert diagnostic.provider_activity

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

  test "a staged preparation stricter than its sealed declaration is refused" do
    # Preparation, phase-5 identity, and the sinks the owner opened before any
    # provider ran all come from the sealed descriptor. A builder preparing as
    # :private_inspection while its descriptor declares :normal contradicts
    # that declaration, so the run stops while every provider is still inert.
    fixture =
      provider_fixture(
        credential_names: ["fixture-key"],
        descriptor_accepts_data: [:normal, :private_inspection],
        staged_data_class: :private_inspection,
        staged_accepts_data: [:normal, :private_inspection]
      )

    assert fixture.prepared.effective_data_class == :normal
    assert_declaration_refused(fixture)
  end

  test "a staged preparation weaker than its sealed declaration is refused just as firmly" do
    # The safe direction still contradicts the declaration the effective data
    # class, event policy, and opened sinks were derived from, so it is refused
    # rather than accepted because it happens to be stricter than needed.
    fixture =
      provider_fixture(
        credential_names: ["fixture-key"],
        descriptor_data_class: :private_inspection,
        descriptor_accepts_data: [:normal, :private_inspection],
        staged_accepts_data: [:normal, :private_inspection]
      )

    assert fixture.prepared.effective_data_class == :private_inspection
    assert_declaration_refused(fixture)
  end

  test "a staged preparation accepting more classes than it declared is refused" do
    # Phase 5 admitted this occurrence against the declared accepted classes.
    # A builder that widens them at run time answers a different information
    # flow question than the one the sealed plan approved.
    fixture =
      provider_fixture(
        credential_names: ["fixture-key"],
        descriptor_accepts_data: [:normal],
        staged_accepts_data: [:normal, :private_inspection]
      )

    assert_declaration_refused(fixture)
  end

  test "a staged preparation accepting fewer classes than it declared is refused" do
    fixture =
      provider_fixture(
        credential_names: ["fixture-key"],
        descriptor_accepts_data: [:normal, :private_inspection],
        staged_accepts_data: [:normal]
      )

    assert_declaration_refused(fixture)
  end

  test "connectivity closes its provider session inside the runtime that acquired it" do
    # A connectivity acquisition commits real closers to the session, so
    # unwinding the registry first would run them against a runtime that is
    # already gone. An independent review found the inversion; this is what
    # would have caught it.
    fixture = provider_fixture([connectivity_mode: :acquisition] ++ closing_acquire())
    assert_session_closes_before_registry(fixture, :connect)
  end

  test "an execution from another catalog leaves the prepared run reusable" do
    fixture = provider_fixture()
    other = provider_fixture(installation_revision: "other-v1")

    assert {:error, :invalid_provider_execution} =
             RunCoordinator.execute(
               fixture.prepared,
               fixture.authority,
               other.execution,
               &never_notify/1
             )

    assert PreparedRun.valid?(fixture.prepared)
    assert ProviderActivity.value(fixture.prepared.provider_activity) == false

    assert {:error, :invalid_provider_execution} =
             ExecutionSessionOwner.start(
               fixture.prepared,
               fixture.authority,
               self(),
               other.execution,
               &never_notify/1
             )

    assert PreparedRun.valid?(fixture.prepared)
    assert :ok = PreparedRun.close(fixture.prepared)
    assert :ok = PreparedRun.close(other.prepared)
  end

  defp start_owned_execution(fixture) do
    parent = self()

    caller =
      spawn(fn ->
        {:ok, owner} =
          ExecutionSessionOwner.start(
            fixture.prepared,
            fixture.authority,
            self(),
            fixture.execution,
            &never_notify/1
          )

        send(parent, {:execution_owner, owner})
        send(parent, {:execution_result, ExecutionSessionOwner.await(owner)})
      end)

    assert_receive {:execution_owner, owner}, 5_000
    owner_pid = ExecutionSessionOwner.pid(owner)
    on_exit(fn -> release(caller, owner_pid) end)
    %{caller: caller, owner: owner, owner_pid: owner_pid}
  end

  # Every test here deliberately blocks provider work in an unlinked caller, so
  # a failed assertion must still tear the run down instead of leaving the
  # caller, owner, worker, and registered roots behind for later tests.
  defp release(caller, owner_pid) do
    if Process.alive?(caller), do: Process.exit(caller, :kill)
    reference = Process.monitor(owner_pid)

    receive do
      {:DOWN, ^reference, :process, ^owner_pid, _reason} -> :ok
    after
      5_000 -> Process.exit(owner_pid, :kill)
    end
  end

  defp never_notify(_url), do: flunk("ordinary provider execution must not notify authorization")

  defp block_forever do
    receive do
      :never -> :never
    end
  end

  # Yielding matters more than the attempt count: a bare spin starves the very
  # worker these helpers are waiting on when schedulers are contended.
  defp await_state(owner_pid, projection, attempts \\ 50_000)

  defp await_state(owner_pid, projection, attempts) when attempts > 0 do
    state = :sys.get_state(owner_pid)

    if projection.(state) do
      state
    else
      :erlang.yield()
      await_state(owner_pid, projection, attempts - 1)
    end
  end

  defp await_state(_owner_pid, _projection, 0), do: flunk("owner state never became ready")

  defp watch(processes) do
    Map.new(processes, fn {name, pid} -> {name, {pid, Process.monitor(pid)}} end)
  end

  defp assert_all_down(watched) do
    Enum.each(watched, fn {name, {pid, reference}} ->
      assert_receive {:DOWN, ^reference, :process, ^pid, _reason},
                     5_000,
                     "#{name} was left running"
    end)
  end

  defp closing_acquire do
    parent = self()

    [
      acquire: fn context ->
        scoped_root(parent, context)
        {:ok, capability} = fixture_capability()

        {:ok,
         %{
           capabilities: [capability],
           snapshot: nil,
           close: fn ->
             send(parent, :provider_closed)
             :ok
           end
         }}
      end
    ]
  end

  # One invariant, asserted for each operation that owns a provider session:
  # the session closes while the runtime that produced its resources is still
  # alive. Connectivity takes no notifier at all, which is itself part of its
  # contract.
  defp assert_session_closes_before_registry(fixture, operation) do
    parent = self()
    notifier = if operation == :connect, do: nil, else: &never_notify/1

    caller =
      spawn(fn ->
        receive do: (:go -> :ok)

        {:ok, owner} =
          ExecutionSessionOwner.start(
            fixture.prepared,
            fixture.authority,
            self(),
            fixture.execution,
            notifier,
            operation
          )

        send(parent, {:execution_result, ExecutionSessionOwner.await(owner)})
      end)

    # Tracing the caller before it starts anything makes the owner and its
    # worker inherit the flag, so the order below is the order the operation
    # actually closed in rather than a snapshot taken after the fact.
    trace_closes(caller, [:call, :set_on_spawn])

    try do
      send(caller, :go)
      assert_receive {:execution_result, {:ok, _evidence}}, 5_000
      assert [ProviderSession, ProviderRegistry] == [next_close(), next_close()]
      assert_received :provider_closed
    after
      stop_trace_closes(caller)
    end
  end

  defp trace_closes(owner_pid, flags \\ [:call]) do
    Enum.each([ProviderRegistry, ProviderSession], &Code.ensure_loaded!/1)
    assert :erlang.trace_pattern({ProviderRegistry, :close, 1}, true, [:local]) == 1
    assert :erlang.trace_pattern({ProviderSession, :close, 1}, true, [:local]) == 1
    assert :erlang.trace(owner_pid, true, flags) == 1
  end

  defp next_close do
    assert_receive {:trace, _owner, :call, {module, :close, _arguments}}, 5_000
    module
  end

  defp stop_trace_closes(owner_pid) do
    :erlang.trace_pattern({ProviderRegistry, :close, 1}, false, [:local])
    :erlang.trace_pattern({ProviderSession, :close, 1}, false, [:local])
    :erlang.trace(owner_pid, false, [:call])
  catch
    :error, :badarg -> false
  end

  # Every refused declaration must be refused for the same reason and before the
  # provider builds anything: no preflight, no acquisition, and no registered
  # resource root.
  #
  # Credentials are the deliberate exception, and asserting they were read is
  # what pins the ordering here. Phase-8 step 5 resolves them from the sealed
  # declarations before any provider callback runs, so a mismatch found during
  # preparation is necessarily found after resolution. Moving resolution back
  # behind preparation would leave this resolver untouched, because preparation
  # is what fails.
  defp assert_declaration_refused(fixture) do
    _started = start_owned_execution(fixture)

    # Past the phase-8 marker the reason is classified where the occurrence is
    # still in scope, so the refusal arrives as the closed acquisition code for
    # a preparation that contradicted its declaration, naming the occurrence
    # that did it rather than as a bare atom the command boundary would have
    # collapsed to `internal_error`.
    assert_receive {:execution_result, {:error, %CommandDiagnostic{} = diagnostic}}, 5_000
    assert diagnostic.phase == :provider_acquisition
    assert diagnostic.code == :provider_policy_changed
    assert diagnostic.provider_activity
    assert diagnostic.subject.name == "selected"
    assert diagnostic.subject.operation == :acquisition
    assert diagnostic.subject.occurrence == %{destination: :workflow, index: 0}
    assert_received {:resolved_credentials, ["fixture-key"]}
    refute_received {:provider_phase, :preflight}
    refute_received {:provider_phase, :acquire}
    refute_received {:provider_root, _root, _registration}
  end

  defp provider_fixture(opts \\ []) do
    parent = self()
    selection_validation = Keyword.get(opts, :selection_validation, :declarative)
    body = Keyword.get(opts, :body, "(return {\"answer\" 42})")
    credential_names = Keyword.get(opts, :credential_names, [])

    # The default acquisition registers a resource root, so a refusal test can
    # prove nothing was created rather than that nothing could have been.
    acquire =
      Keyword.get(opts, :acquire, fn context ->
        scoped_root(parent, context)
        fixture_capability()
      end)

    staged_policy =
      %{
        data_class: Keyword.get(opts, :staged_data_class),
        accepts_data: Keyword.get(opts, :staged_accepts_data)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    {:ok, descriptor} =
      ProviderDescriptor.new(
        source: :custom,
        installation_revision: Keyword.get(opts, :installation_revision, "lifecycle-v1"),
        credential_names: credential_names,
        authorization_mode: :none,
        data_class: Keyword.get(opts, :descriptor_data_class, :normal),
        accepts_data: Keyword.get(opts, :descriptor_accepts_data, [:normal]),
        requires: [],
        provides: [],
        destinations: [:workflow],
        workflow_llm?: false,
        connectivity_mode: Keyword.get(opts, :connectivity_mode, :none),
        probe_effect: nil,
        selection_validation: selection_validation,
        selection_rules: rules,
        authority_fingerprint: nil,
        local_preflight: :none
      )

    builder = fn _selection, context ->
      send(parent, {:provider_phase, :prepare})

      staged = %{
        credential_names: Keyword.get(opts, :builder_credential_names, credential_names),
        preflight: fn ->
          send(parent, {:provider_phase, :preflight})

          {:ok,
           fn %{} ->
             send(parent, {:provider_phase, :acquire})
             acquire.(context)
           end}
        end
      }

      {:ok, Map.merge(staged, staged_policy)}
    end

    implementation =
      case Keyword.get(opts, :selection_validator) do
        nil -> %{builder: builder}
        validator -> %{builder: builder, selection_validator: validator}
      end

    registration = %{descriptor: descriptor, implementation: implementation, authority: nil}

    {:ok, catalog} =
      InstallationCatalog.new(%{"selected" => registration})

    default_resolver = fn names ->
      send(parent, {:resolved_credentials, names})
      {:ok, Map.new(names, &{&1, "fixture-credential"})}
    end

    {:ok, services} =
      ProviderRuntimeServices.new(
        credential_resolver: Keyword.get(opts, :credential_resolver, default_resolver)
      )

    {:ok, execution} = ProviderExecution.new(catalog, services, [])
    {:ok, authority} = PublicationAuthority.new([])

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" => [%{"name" => "selected", "config" => %{}}],
        "mission" => []
      }
    }

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [_input] #{body})"
    }

    {:ok, request} =
      ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)

    {:ok, prepared} = RunCoordinator.prepare(request, catalog)
    on_exit(fn -> InstallationCatalog.close(catalog) end)

    %{
      prepared: prepared,
      catalog: catalog,
      execution: execution,
      authority: authority
    }
  end

  defp scoped_root(parent, context) do
    spawn(fn ->
      signal = Process.monitor(context.owner)

      send(
        parent,
        {:provider_root, self(), ResourceRegistrar.register_root(context.resource_registrar)}
      )

      receive do
        {:DOWN, ^signal, :process, _pid, _reason} -> :ok
      end
    end)
  end

  defp fixture_capability do
    Capability.new(
      name: "fixture",
      input_schema: %{"type" => "object", "additionalProperties" => false},
      callback: fn _arguments -> {:ok, %{}} end
    )
  end
end
