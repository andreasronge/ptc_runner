defmodule PtcRunner.Kernel.MCPOAuth.PrimitivesTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPOAuth.Primitives

  test "generates independent bounded state and S256 material" do
    flows = Enum.map(1..64, fn _ -> Primitives.new_flow() end)

    assert Enum.all?(flows, fn flow ->
             byte_size(flow.state) == 43 and byte_size(flow.verifier) == 43 and
               flow.state != flow.verifier and
               Primitives.valid_verifier?(flow.verifier) and
               flow.challenge ==
                 Base.url_encode64(:crypto.hash(:sha256, flow.verifier), padding: false)
           end)

    assert flows |> Enum.map(& &1.state) |> Enum.uniq() |> length() == 64
    assert flows |> Enum.map(& &1.verifier) |> Enum.uniq() |> length() == 64
  end

  test "rejects invalid verifier grammar" do
    refute Primitives.valid_verifier?(String.duplicate("a", 42))
    refute Primitives.valid_verifier?(String.duplicate("a", 129))
    refute Primitives.valid_verifier?(String.duplicate("a", 42) <> "=")
    refute Primitives.valid_verifier?(String.duplicate("a", 42) <> "/")
    assert Primitives.valid_verifier?(String.duplicate("~", 43))
  end

  test "compares state and rejects unbounded values" do
    assert Primitives.state_equal?("state", "state")
    refute Primitives.state_equal?("state", "other")
    refute Primitives.state_equal?(String.duplicate("x", 257), String.duplicate("x", 257))
  end

  test "retains unrelated endpoint queries and rejects owned collisions" do
    params = [{"response_type", "code"}, {"state", "a b"}]

    assert {:ok, "https://auth.example/authorize?route=%2fraw&x=1&response_type=code&state=a+b"} =
             Primitives.authorization_url(
               "https://auth.example/authorize?route=%2fraw&x=1",
               params
             )

    assert {:error, :invalid_endpoint} =
             Primitives.authorization_url(
               "https://auth.example/authorize?st%61te=attacker",
               params
             )

    assert {:error, :invalid_endpoint} =
             Primitives.authorization_url(
               "https://auth.example/authorize?response_mode=fragment",
               params
             )

    assert {:error, :invalid_endpoint} =
             Primitives.authorization_url("https://auth.example/authorize?x=%GG", params)
  end

  test "rejects raw terminal control characters in discovered endpoints" do
    params = [{"response_type", "code"}, {"state", "state"}]

    for control <- ["\n", "\e]52;c;payload\a", <<0xC2, 0x9B>>] do
      assert {:error, :invalid_endpoint} =
               Primitives.authorization_url(
                 "https://auth.example/authorize" <> control,
                 params
               )
    end
  end

  test "token endpoint rejects collisions even though parameters use the form body" do
    assert {:ok, "https://auth.example/token?tenant=one"} =
             Primitives.token_endpoint("https://auth.example/token?tenant=one")

    assert {:error, :invalid_endpoint} =
             Primitives.token_endpoint("https://auth.example/token?grant_type=other")
  end

  test "client secret basic form-encodes both values before base64" do
    assert {:ok, "Basic " <> encoded} =
             Primitives.client_secret_basic("id: ü", "secret&= value")

    assert Base.decode64!(encoded) ==
             "id%3A+%C3%BC:secret%26%3D+value"
  end
end
