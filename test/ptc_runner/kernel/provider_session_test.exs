defmodule PtcRunner.Kernel.ProviderSessionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ResourceRegistrar

  test "committed scopes close once in reverse commit order" do
    {:ok, order} = Agent.start_link(fn -> [] end)
    {:ok, session} = ProviderSession.start(limits())
    {:ok, first} = ProviderSession.open_registrar(session)
    {:ok, second} = ProviderSession.open_registrar(session)

    assert :ok = ResourceRegistrar.activate(first)
    assert :ok = ResourceRegistrar.activate(second)
    assert :ok = ResourceRegistrar.commit(first, record_close(order, :first))
    assert :ok = ResourceRegistrar.commit(second, record_close(order, :second))

    session_monitor = Process.monitor(session.pid)
    assert :ok = ProviderSession.close(session)
    assert_receive {:DOWN, ^session_monitor, :process, _, :normal}
    assert [:second, :first] = Agent.get(order, &Enum.reverse/1)
    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
    assert [:second, :first] = Agent.get(order, &Enum.reverse/1)
  end

  test "invalid limits cannot create a provider session" do
    invalid = %{limits() | provider_cleanup_timeout_ms: 0}

    assert {:error, :invalid_provider_session} = ProviderSession.start(invalid)
  end

  test "abnormal session death cannot be reported as successful cleanup" do
    parent = self()
    {:ok, session} = ProviderSession.start(limits())
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)

    assert :ok =
             ResourceRegistrar.commit(registrar, fn ->
               send(parent, :unexpected_cleanup)
               :ok
             end)

    monitor = Process.monitor(session.pid)
    Process.exit(session.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}

    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
    refute_receive :unexpected_cleanup
  end

  test "registrars enforce activation and terminal transitions" do
    {:ok, session} = ProviderSession.start(limits())
    {:ok, aborted} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.abort(aborted)

    assert {:error, :resource_registrar_unavailable} =
             ResourceRegistrar.activate(aborted)

    {:ok, committed} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(committed)
    assert :ok = ResourceRegistrar.commit(committed, nil)

    assert {:error, :resource_registrar_unavailable} =
             ResourceRegistrar.commit(committed, nil)

    assert :ok = ProviderSession.close(session)
  end

  test "lifecycle ownership transfers once before death cleanup" do
    parent = self()

    creator =
      spawn(fn ->
        {:ok, session} = ProviderSession.start(limits())
        {:ok, committed} = ProviderSession.open_registrar(session)
        :ok = ResourceRegistrar.activate(committed)

        :ok =
          ResourceRegistrar.commit(committed, fn ->
            send(parent, :committed_closed)
            :ok
          end)

        lifecycle_owner = spawn(fn -> receive do: (:stop -> :ok) end)
        run_state = spawn(fn -> receive do: (:stop -> :ok) end)
        :ok = ProviderSession.bind_lifecycle(session, lifecycle_owner, run_state)
        send(parent, {:session_ready, session, lifecycle_owner, run_state})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:session_ready, session, lifecycle_owner, run_state}
    session_monitor = Process.monitor(session.pid)

    assert {:error, :provider_session_unavailable} =
             ProviderSession.bind_lifecycle(session, self(), run_state)

    provider = spawn(fn -> receive do: (:stop -> :ok) end)
    provider_monitor = Process.monitor(provider)
    assert :ok = ProviderSession.attach_provider(session, provider)

    Process.exit(creator, :kill)
    refute_receive :committed_closed
    assert Process.alive?(session.pid)

    Process.exit(run_state, :kill)
    assert_receive {:DOWN, ^provider_monitor, :process, ^provider, :killed}
    refute_receive :committed_closed
    assert Process.alive?(session.pid)

    Process.exit(lifecycle_owner, :kill)

    assert_receive :committed_closed
    assert_receive {:DOWN, ^session_monitor, :process, _, :normal}
  end

  test "cleanup has one shared bound" do
    {:ok, order} = Agent.start_link(fn -> [] end)
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, first} = ProviderSession.open_registrar(session)
    {:ok, second} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(first)
    assert :ok = ResourceRegistrar.activate(second)

    assert :ok = ResourceRegistrar.commit(first, record_close(order, :first))

    assert :ok =
             ResourceRegistrar.commit(second, fn ->
               receive do
                 :never -> :ok
               end
             end)

    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
    assert [:first] = Agent.get(order, &Enum.reverse/1)
    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
  end

  test "cleanup continues in reverse order after a close failure" do
    {:ok, order} = Agent.start_link(fn -> [] end)
    {:ok, session} = ProviderSession.start(limits())
    {:ok, first} = ProviderSession.open_registrar(session)
    {:ok, second} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(first)
    assert :ok = ResourceRegistrar.activate(second)
    assert :ok = ResourceRegistrar.commit(first, record_close(order, :first))
    assert :ok = ResourceRegistrar.commit(second, fn -> :failed end)

    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
    assert [:first] = Agent.get(order, &Enum.reverse/1)
  end

  test "tampered session and registrar handles are rejected" do
    {:ok, session} = ProviderSession.start(limits())
    {:ok, registrar} = ProviderSession.open_registrar(session)

    refute ProviderSession.valid?(%{session | token: make_ref()})
    refute ResourceRegistrar.valid?(%{registrar | scope: make_ref()})

    assert {:error, :provider_cleanup_failed} =
             ProviderSession.close(%{session | token: make_ref()})

    assert {:error, :resource_registrar_unavailable} =
             ResourceRegistrar.activate(%{registrar | scope: make_ref()})

    assert :ok = ProviderSession.close(session)
  end

  defp limits, do: Limits.defaults()

  defp record_close(agent, value) do
    fn ->
      Agent.update(agent, &[value | &1])
      :ok
    end
  end
end
