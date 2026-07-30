defmodule PtcRunner.Kernel.MCPOAuth.ScopeTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPOAuth.Scope

  test "parses byte-exact scope lists and serializes deterministically" do
    assert {:ok, scopes} = Scope.parse_list(["z:read", "A", "a"])
    assert {:ok, "A a z:read"} = Scope.serialize(scopes)
    assert {:ok, ^scopes} = Scope.parse_string("A a z:read")
  end

  test "supports an explicitly allowed empty host ceiling only" do
    assert {:ok, scopes} = Scope.parse_list([], allow_empty: true)
    assert MapSet.size(scopes) == 0
    assert {:error, :invalid_scope} = Scope.parse_list([])
    assert {:error, :invalid_scope} = Scope.parse_string("")
  end

  test "rejects duplicates, whitespace, unicode, and invalid token bytes" do
    invalid_lists = [
      ["read", "read"],
      ["with space"],
      ["with\ttab"],
      ["ümlaut"],
      [<<0x22>>],
      [<<0x5C>>]
    ]

    Enum.each(invalid_lists, fn values ->
      assert {:error, :invalid_scope} = Scope.parse_list(values)
    end)

    for value <- [" read", "read ", "read  write", "read\twrite", "read ü"] do
      assert {:error, :invalid_scope} = Scope.parse_string(value)
    end
  end
end
