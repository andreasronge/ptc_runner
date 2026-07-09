defmodule PtcRunner.PreludeRolePolicyTest do
  use ExUnit.Case, async: true

  alias PtcRunner.PreludeRolePolicy

  test "resolves default role with stable grant fingerprint" do
    assert {:ok, policy} =
             PreludeRolePolicy.from_map(%{
               "default_role" => "kernel_default",
               "roles" => %{
                 "kernel_default" => %{
                   "prelude_store_access" => "none",
                   "preludes" => ["agent.core@1"],
                   "default_preludes" => ["agent.core@1"]
                 }
               }
             })

    assert {:ok, grant} = PreludeRolePolicy.resolve(policy, nil)
    assert grant.role == "kernel_default"
    assert grant.prelude_store_access == :none
    assert grant.fingerprint =~ "sha256:"
    assert {:ok, ["agent.core@1"]} = PreludeRolePolicy.selected_refs(grant, [])
  end

  test "rejects unknown and MCP-only grant keys in kernel role policy" do
    assert {:error, %{reason: :unknown_policy_key, message: message}} =
             PreludeRolePolicy.from_map(%{
               "default_role" => "kernel_default",
               "roles" => %{
                 "kernel_default" => %{
                   "prelude_store_access" => "none",
                   "preludes" => ["agent.core@1"],
                   "default_preludes" => ["agent.core@1"],
                   "upstream_tools" => []
                 }
               }
             })

    assert message =~ ~s|"upstream_tools"|
  end

  test "rejects defaults outside the role prelude allowlist" do
    assert {:error, %{reason: :invalid_policy, message: message}} =
             PreludeRolePolicy.from_map(%{
               "default_role" => "kernel_default",
               "roles" => %{
                 "kernel_default" => %{
                   "prelude_store_access" => "none",
                   "preludes" => ["agent.prompt@1"],
                   "default_preludes" => ["agent.core@1"]
                 }
               }
             })

    assert message =~ "default_preludes[0] is not granted"
  end

  test "rejects duplicate prelude grants before they can widen checksum pins" do
    checksum = String.duplicate("a", 64)

    for grants <- [
          ["agent.core@1", %{"id" => "agent.core", "version" => 1, "checksum" => checksum}],
          [%{"id" => "agent.core", "version" => 1, "checksum" => checksum}, "agent.core@1"]
        ] do
      assert {:error, %{reason: :invalid_policy, message: message}} =
               PreludeRolePolicy.from_map(%{
                 "default_role" => "kernel_default",
                 "roles" => %{
                   "kernel_default" => %{
                     "prelude_store_access" => "none",
                     "preludes" => grants,
                     "default_preludes" => []
                   }
                 }
               })

      assert message =~ "duplicates agent.core@1"
    end
  end
end
