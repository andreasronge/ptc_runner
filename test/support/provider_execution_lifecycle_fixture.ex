defmodule PtcRunner.TestSupport.ProviderExecutionLifecycleFixture do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import PtcRunner.TestSupport.ProviderExecutionFixture

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession

  def start_owned_execution(fixture, operation \\ :run) do
    parent = self()

    notifier = if operation == :connect, do: nil, else: unexpected_notifier()

    caller =
      spawn(fn ->
        {:ok, owner} =
          ExecutionSessionOwner.start(
            fixture.prepared,
            fixture.authority,
            self(),
            fixture.execution,
            notifier,
            operation
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
  def release(caller, owner_pid) do
    if Process.alive?(caller), do: Process.exit(caller, :kill)
    reference = Process.monitor(owner_pid)

    receive do
      {:DOWN, ^reference, :process, ^owner_pid, _reason} -> :ok
    after
      5_000 -> Process.exit(owner_pid, :kill)
    end
  end

  # This callback deliberately fails if ordinary execution tries to notify.
  @dialyzer {:nowarn_function, unexpected_notifier: 0}
  def unexpected_notifier do
    fn _url -> flunk("ordinary provider execution must not notify authorization") end
  end

  def block_forever do
    receive do
      :never -> :never
    end
  end

  # Yielding matters more than the attempt count: a bare spin starves the very
  # worker these helpers are waiting on when schedulers are contended.
  def await_state(owner_pid, projection, attempts \\ 50_000)

  def await_state(owner_pid, projection, attempts) when attempts > 0 do
    state = :sys.get_state(owner_pid)

    if projection.(state) do
      state
    else
      :erlang.yield()
      await_state(owner_pid, projection, attempts - 1)
    end
  end

  def await_state(_owner_pid, _projection, 0), do: flunk("owner state never became ready")

  def watch(processes) do
    Map.new(processes, fn {name, pid} -> {name, {pid, Process.monitor(pid)}} end)
  end

  def assert_all_down(watched) do
    Enum.each(watched, fn {name, {pid, reference}} ->
      assert_receive {:DOWN, ^reference, :process, ^pid, _reason},
                     5_000,
                     "#{name} was left running"
    end)
  end

  def closing_acquire do
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
  def assert_session_closes_before_registry(fixture, operation) do
    parent = self()
    notifier = if operation == :connect, do: nil, else: unexpected_notifier()

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

  def trace_closes(owner_pid, flags \\ [:call]) do
    Enum.each([ProviderRegistry, ProviderSession], &Code.ensure_loaded!/1)
    assert :erlang.trace_pattern({ProviderRegistry, :close, 1}, true, [:local]) == 1
    assert :erlang.trace_pattern({ProviderSession, :close, 1}, true, [:local]) == 1
    assert :erlang.trace(owner_pid, true, flags) == 1
  end

  def next_close do
    assert_receive {:trace, _owner, :call, {module, :close, _arguments}}, 5_000
    module
  end

  def stop_trace_closes(owner_pid) do
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
  def assert_declaration_refused(fixture) do
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
end
