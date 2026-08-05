defmodule PtcRunner.Kernel.ProviderExecutionLifecycleTest do
  use ExUnit.Case, async: false

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

  test "caller death while acquisition blocks closes the registry before the session" do
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

      assert [ProviderRegistry, ProviderSession] == [next_close(), next_close()]
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
        body: "(loop [] (recur))",
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
        body: "(loop [] (recur))",
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

  defp await_state(owner_pid, projection, attempts \\ 1_000)

  defp await_state(owner_pid, projection, attempts) when attempts > 0 do
    state = :sys.get_state(owner_pid)

    if projection.(state) do
      state
    else
      await_state(owner_pid, projection, attempts - 1)
    end
  end

  defp await_state(_owner_pid, _projection, 0), do: flunk("owner state never became ready")

  defp assert_eventually(callback, attempts \\ 50_000)

  defp assert_eventually(callback, attempts) when attempts > 0 do
    if callback.(), do: :ok, else: assert_eventually(callback, attempts - 1)
  end

  defp assert_eventually(_callback, 0), do: flunk("condition did not become true")

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

  defp trace_closes(owner_pid) do
    Enum.each([ProviderRegistry, ProviderSession], &Code.ensure_loaded!/1)
    assert :erlang.trace_pattern({ProviderRegistry, :close, 1}, true, [:local]) == 1
    assert :erlang.trace_pattern({ProviderSession, :close, 1}, true, [:local]) == 1
    assert :erlang.trace(owner_pid, true, [:call]) == 1
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

  defp provider_fixture(opts \\ []) do
    selection_validation = Keyword.get(opts, :selection_validation, :declarative)
    body = Keyword.get(opts, :body, "(return {\"answer\" 42})")
    acquire = Keyword.get(opts, :acquire, fn _context -> fixture_capability() end)

    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    {:ok, descriptor} =
      ProviderDescriptor.new(
        source: :custom,
        installation_revision: Keyword.get(opts, :installation_revision, "lifecycle-v1"),
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
        selection_validation: selection_validation,
        selection_rules: rules,
        authority_fingerprint: nil,
        local_preflight: :none
      )

    builder = fn _selection, context ->
      {:ok, %{credential_names: [], preflight: fn -> {:ok, fn %{} -> acquire.(context) end} end}}
    end

    implementation =
      case Keyword.get(opts, :selection_validator) do
        nil -> %{builder: builder}
        validator -> %{builder: builder, selection_validator: validator}
      end

    registration = %{descriptor: descriptor, implementation: implementation, authority: nil}

    {:ok, catalog} =
      InstallationCatalog.new(%{"selected" => registration})

    {:ok, services} = ProviderRuntimeServices.new()
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
