defmodule PtcRunner.Kernel.MCPOAuth.BearerChallengeTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPOAuth.BearerChallenge

  test "combines fields and ignores other schemes around one Bearer challenge" do
    assert {:ok,
            %{
              "scope" => "read write",
              "resource_metadata" => "https://mcp.example/.well-known/resource"
            }} =
             BearerChallenge.parse([
               ~s(Digest realm="a,b"),
               ~s(Bearer scope="read write", resource_metadata="https://mcp.example/.well-known/resource"),
               ~s(Basic realm="other")
             ])
  end

  test "ignores a padded token68 challenge from another scheme" do
    assert {:ok, %{"scope" => "read"}} =
             BearerChallenge.parse([
               "Basic YWJjZA==",
               ~s(Bearer scope="read")
             ])
  end

  test "accepts zero Bearer challenges" do
    assert {:ok, nil} = BearerChallenge.parse([])
    assert {:ok, nil} = BearerChallenge.parse([~s(Basic realm="example")])
  end

  test "rejects multiple Bearer challenges and case-insensitive duplicate parameters" do
    assert {:error, :invalid_bearer_challenge} =
             BearerChallenge.parse([~s(Bearer scope="read", Bearer scope="read")])

    assert {:error, :invalid_bearer_challenge} =
             BearerChallenge.parse([~s(Bearer scope="read", SCOPE="write")])
  end

  test "does not split quoted commas and rejects malformed quoting" do
    assert {:ok, %{"error_description" => "a,b"}} =
             BearerChallenge.parse([~s(Bearer error_description="a,b")])

    assert {:error, :invalid_bearer_challenge} =
             BearerChallenge.parse([~s(Bearer scope="unterminated)])
  end

  test "rejects Bearer token68 and comma-confusable parameter shapes" do
    assert {:error, :invalid_bearer_challenge} =
             BearerChallenge.parse(["Bearer abc=="])

    assert {:error, :invalid_bearer_challenge} =
             BearerChallenge.parse([~s(Bearer scope="read", =confused)])
  end
end
