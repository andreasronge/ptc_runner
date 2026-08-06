defmodule PtcRunner.Kernel.ProviderRuntimeServicesTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.MCPOAuth.Context, as: OAuthContext
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.ProviderRuntimeServices

  test "construction seals services without activating any runtime callback" do
    calls = :atomics.new(3, signed: false)

    activation = fn ->
      :atomics.add(calls, 1, 1)
      {:ok, nil}
    end

    resolver = fn names ->
      :atomics.add(calls, 2, 1)
      {:ok, Map.new(names, &{&1, "resolved"})}
    end

    assert {:ok, memory} = Memory.start(owner: self())
    assert {:ok, store} = Memory.store(memory)

    assert {:ok, context} =
             OAuthContext.new(
               tenant_id: "tenant",
               principal_id: "principal",
               store: store,
               deadline: Deadline.new(1_000)
             )

    parent = self()

    # The factory runs in a deadline-bound worker, so it reports to the test
    # process rather than to whichever process happens to invoke it.
    context_factory = fn deadline ->
      :atomics.add(calls, 3, 1)
      send(parent, {:context_factory_deadline, deadline})
      {:ok, context}
    end

    assert {:ok, services} =
             ProviderRuntimeServices.new(
               activation: activation,
               credential_resolver: resolver,
               oauth_mode: {:context_factory, context_factory}
             )

    assert ProviderRuntimeServices.valid?(services)
    assert services.provider_application_mode == :host_owned
    assert Enum.map(1..3, &:atomics.get(calls, &1)) == [0, 0, 0]

    assert {:ok, nil} = ProviderRuntimeServices.activate(services)
    assert Enum.map(1..3, &:atomics.get(calls, &1)) == [1, 0, 0]

    assert {:ok, %{"token" => "resolved"}} = services.credential_resolver.(["token"])
    assert Enum.map(1..3, &:atomics.get(calls, &1)) == [1, 1, 0]

    deadline = Deadline.new(1_000)
    assert {:ok, ^context} = ProviderRuntimeServices.oauth_context(services, deadline)
    assert_receive {:context_factory_deadline, ^deadline}
    assert Enum.map(1..3, &:atomics.get(calls, &1)) == [1, 1, 1]
  end

  test "defaults are process-free, credential-closed, and OAuth-disabled" do
    assert {:ok, services} = ProviderRuntimeServices.new()
    assert {:ok, nil} = ProviderRuntimeServices.activate(services)
    assert {:ok, %{}} = services.credential_resolver.([])

    assert {:error, :credential_resolver_missing} =
             services.credential_resolver.(["token"])

    assert {:error, :authorization_context_required} =
             ProviderRuntimeServices.oauth_context(services, Deadline.new(1_000))
  end

  test "the complete seal and callback results fail closed" do
    assert {:ok, services} = ProviderRuntimeServices.new()

    refute ProviderRuntimeServices.valid?(Map.put(services, :path, "/private"))

    assert {:error, :invalid_provider_runtime_services} =
             ProviderRuntimeServices.new(activation: fn -> {:ok, :not_an_authority} end)
             |> then(fn {:ok, invalid_result} ->
               ProviderRuntimeServices.activate(invalid_result)
             end)

    assert {:error, :invalid_provider_runtime_services} =
             ProviderRuntimeServices.new(oauth_mode: {:context_factory, fn -> :context end})

    assert {:error, :invalid_provider_runtime_services} =
             ProviderRuntimeServices.new(credential_resolver: fn -> {:ok, %{}} end)

    assert {:error, :invalid_provider_runtime_services} =
             ProviderRuntimeServices.new(runtime_binding: :crypto.strong_rand_bytes(32))

    assert {:error, :invalid_provider_runtime_services} =
             ProviderRuntimeServices.new(provider_application_mode: :shared_vm)

    assert {:ok, command_services} =
             ProviderRuntimeServices.new(provider_application_mode: :command_vm)

    assert ProviderRuntimeServices.valid?(command_services)

    refute ProviderRuntimeServices.valid?(%{
             command_services
             | provider_application_mode: :host_owned
           })
  end

  test "a context factory that never returns is cancelled at the operation deadline" do
    parent = self()

    {:ok, services} =
      ProviderRuntimeServices.new(
        oauth_mode:
          {:context_factory,
           fn _deadline ->
             send(parent, {:factory_entered, self()})
             receive do: (:never -> :never)
           end}
      )

    deadline = Deadline.new(150)

    # Returning at all is the assertion: an unbounded factory would hang here.
    # The timeout keeps its own classification rather than being reported as a
    # missing authorization context.
    assert {:error, :operation_deadline_expired} =
             ProviderRuntimeServices.oauth_context(services, deadline)

    assert_receive {:factory_entered, factory}, 5_000
    reference = Process.monitor(factory)
    assert_receive {:DOWN, ^reference, :process, ^factory, _reason}, 5_000
    assert Deadline.expired?(deadline)
  end

  test "an expired deadline never enters the context factory" do
    parent = self()

    {:ok, services} =
      ProviderRuntimeServices.new(
        oauth_mode: {:context_factory, fn _deadline -> send(parent, :factory_entered) end}
      )

    expired = Deadline.new(1, System.monotonic_time(:millisecond) - 10_000)

    assert {:error, :operation_deadline_expired} =
             ProviderRuntimeServices.oauth_context(services, expired)

    refute_received :factory_entered
  end
end
