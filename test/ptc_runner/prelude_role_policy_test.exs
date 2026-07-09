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
    assert {:error, %{reason: :unknown_policy_key, message: top_message}} =
             PreludeRolePolicy.from_map(%{
               "default_role" => "kernel_default",
               "roles" => %{},
               "profile" => "kernel_default"
             })

    assert top_message =~ ~s|"profile"|

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

  test "accepts existing atom keys without creating untrusted atoms" do
    assert {:ok, policy} =
             PreludeRolePolicy.from_map(%{
               default_role: "kernel_default",
               roles: %{
                 "kernel_default" => %{
                   prelude_store_access: :read,
                   preludes: ["agent.core@1"],
                   default_preludes: ["agent.core@1"]
                 }
               }
             })

    assert {:ok, grant} = PreludeRolePolicy.resolve(policy, nil)
    assert grant.prelude_store_access == :read
  end

  test "rejects invalid default role and invalid role names" do
    assert {:error, %{reason: :invalid_policy, message: message}} =
             PreludeRolePolicy.from_map(%{
               "default_role" => "missing",
               "roles" => %{
                 "kernel_default" => %{
                   "preludes" => ["agent.core@1"],
                   "default_preludes" => ["agent.core@1"]
                 }
               }
             })

    assert message =~ "default_role"

    assert {:error, %{reason: :invalid_role}} =
             PreludeRolePolicy.from_map(%{
               "roles" => %{
                 "bad role" => %{
                   "preludes" => ["agent.core@1"],
                   "default_preludes" => ["agent.core@1"]
                 }
               }
             })

    assert {:error, %{reason: :invalid_policy, message: access_message}} =
             PreludeRolePolicy.from_map(%{
               "roles" => %{
                 "kernel_default" => %{
                   "prelude_store_access" => "admin",
                   "preludes" => ["agent.core@1"],
                   "default_preludes" => []
                 }
               }
             })

    assert access_message =~ "prelude_store_access"

    assert {:error, %{reason: :invalid_policy, message: id_message}} =
             PreludeRolePolicy.from_map(%{
               "roles" => %{
                 "kernel_default" => %{
                   "preludes" => ["bad/id@1"],
                   "default_preludes" => []
                 }
               }
             })

    assert id_message =~ "must be a valid id@version ref"
  end

  test "empty roles reject requested roles without acting like a profile layer" do
    assert {:ok, policy} = PreludeRolePolicy.from_map(%{"roles" => %{}})

    assert {:ok, nil} = PreludeRolePolicy.resolve(policy, nil)

    assert {:error, %{reason: :role_policy_required, message: message}} =
             PreludeRolePolicy.resolve(policy, "kernel_default")

    assert message =~ "role requires a configured prelude role policy"
  end

  test "validates requested preludes type and checksum-pinned requested refs" do
    checksum = String.duplicate("b", 64)

    assert {:ok, policy} =
             PreludeRolePolicy.from_map(%{
               "default_role" => "kernel_default",
               "roles" => %{
                 "kernel_default" => %{
                   "prelude_store_access" => "none",
                   "preludes" => [
                     %{"id" => "agent.core", "version" => 1, "checksum" => checksum}
                   ],
                   "default_preludes" => []
                 }
               }
             })

    assert {:ok, grant} = PreludeRolePolicy.resolve(policy, nil)

    assert {:error, %{reason: :invalid_prelude_ref, message: message}} =
             PreludeRolePolicy.selected_refs(grant, preludes: "agent.core@1")

    assert message =~ "preludes must be a list"

    assert {:error, %{reason: :prelude_not_granted}} =
             PreludeRolePolicy.selected_refs(grant, preludes: ["agent.core@1"])

    assert {:ok, [%{"id" => "agent.core", "version" => 1, "checksum" => ^checksum}]} =
             PreludeRolePolicy.selected_refs(grant,
               preludes: [%{"id" => "agent.core", "version" => 1, "checksum" => checksum}]
             )
  end
end
