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

    assert {:ok, memory} = Memory.start_link(owner: self())
    assert {:ok, store} = Memory.store(memory)

    assert {:ok, context} =
             OAuthContext.new(
               tenant_id: "tenant",
               principal_id: "principal",
               store: store,
               deadline: Deadline.new(1_000)
             )

    context_factory = fn deadline ->
      :atomics.add(calls, 3, 1)
      send(self(), {:context_factory_deadline, deadline})
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
end
