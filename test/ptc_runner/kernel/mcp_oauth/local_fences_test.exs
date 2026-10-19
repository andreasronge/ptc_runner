defmodule PtcRunner.Kernel.MCPOAuth.LocalFencesTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPOAuth.LocalFences
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory

  test "fences belong to the store and disappear when it closes" do
    {:ok, memory} = Memory.start(owner: self())
    {:ok, store} = Memory.store(memory)

    key =
      struct!(PtcRunner.Kernel.MCPOAuth.GrantKey,
        resource: "https://mcp.example",
        issuer: "https://auth.example",
        client_id: "client",
        tenant_id: "tenant",
        principal_id: "principal",
        principal_epoch: 1,
        installation_id: "installation",
        authority_epoch: 1,
        authority_fingerprint: "fingerprint"
      )

    identity = LocalFences.identity(store, key)
    operation = make_ref()
    assert :ok = LocalFences.block(identity, operation, {:rejected_generation, 1})
    assert {:error, :authorization_required} = LocalFences.admit(identity, 1, MapSet.new())
    assert :ok = LocalFences.admit(identity, 2, MapSet.new())

    assert :ok =
             LocalFences.block(
               identity,
               operation,
               {:scope_requirement, 2, MapSet.new(["write"])}
             )

    assert {:error, :authorization_required} =
             LocalFences.admit(identity, 3, MapSet.new(["read"]))

    assert {:error, :authorization_required} =
             LocalFences.admit(identity, 2, MapSet.new(["write"]))

    assert :ok = LocalFences.admit(identity, 3, MapSet.new(["write"]))
    assert :ok = LocalFences.block(identity, operation, {:rejected_generation, 3})
    ref = Process.monitor(memory.pid)
    assert :ok = Memory.close(memory)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    source = File.read!(LocalFences.module_info(:compile)[:source])
    refute source =~ ":persistent_term"

    refute Enum.any?(:persistent_term.get(), fn
             {{{LocalFences, :fence}, _, _}, _} -> true
             _ -> false
           end)

    assert {:error, :authorization_required} = LocalFences.admit(identity, 1, MapSet.new())
  end
end
