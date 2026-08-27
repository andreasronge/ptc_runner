defmodule PtcRunner.Kernel.InspectionValueIdentityTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.InspectionValueIdentity

  test "identifies deterministic JSON with domain separation and encoded size" do
    value = %{"text" => "héllo", "items" => [1, true, nil]}

    assert {:ok,
            %{
              "encoding" => "ptc-deterministic-json-v1",
              "encoded_bytes" => bytes,
              "sha256" => "sha256:" <> hash
            } = identity} = InspectionValueIdentity.identity(value)

    assert bytes == byte_size(~s({"items":[1,true,null],"text":"héllo"}))
    assert byte_size(hash) == 64
    assert InspectionValueIdentity.valid?(identity)
    assert InspectionValueIdentity.identity(value) == {:ok, identity}
    refute InspectionValueIdentity.identity(put_in(value["text"], "héllp")) == {:ok, identity}
  end

  test "rejects ambiguous keys and malformed identities" do
    assert {:error, :invalid_json} =
             InspectionValueIdentity.identity(%{"same" => 1, same: 2})

    refute InspectionValueIdentity.valid?(%{
             "encoding" => "ptc-deterministic-json-v1",
             "encoded_bytes" => -1,
             "sha256" => "sha256:" <> String.duplicate("0", 64)
           })
  end
end
