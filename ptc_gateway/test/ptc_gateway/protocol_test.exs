defmodule PtcGateway.ProtocolTest do
  use ExUnit.Case, async: true

  alias PtcGateway.Protocol

  @discover_request ~s({"jsonrpc":"2.0","id":1,"method":"server/discover","params":{}})
  @list_request ~s({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}})
  @call_request ~s({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"n":1}}})
  @cancel ~s({"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}})

  test "decodes pinned requests and the cancelled notification" do
    assert {:ok, {:request, 1, "server/discover", %{}}} = Protocol.decode_line(@discover_request)
    assert {:ok, {:request, 2, "tools/list", %{}}} = Protocol.decode_line(@list_request)

    assert {:ok, {:request, 3, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 1}}}} =
             Protocol.decode_line(@call_request)

    assert {:ok, {:notification, "notifications/cancelled", %{"requestId" => 3}}} =
             Protocol.decode_line(@cancel)
  end

  test "rejects Content-Length framing and malformed JSON" do
    assert {:error, :invalid_request} =
             Protocol.decode_line("Content-Length: 12")

    assert {:error, :parse} = Protocol.decode_line("{not json")
    assert {:error, :invalid_request} = Protocol.decode_line("[]")
  end

  test "discover and tools/list envelopes match decoded fixture values" do
    discover =
      1
      |> Protocol.encode_result(Protocol.discover_result())
      |> decode_frame()

    assert discover["id"] == 1
    assert discover["result"]["supportedVersions"] == ["2026-07-28"]
    assert discover["result"]["capabilities"]["tools"] == %{}
    refute Map.has_key?(discover, "Content-Length")

    tools = [
      %{
        name: "echo",
        description: "Echo",
        input_schema: %{"type" => "object"},
        output_schema: %{"type" => "object"},
        meta: %{"ptc/application_content_digest" => "abc"}
      }
    ]

    listed =
      2
      |> Protocol.encode_result(Protocol.tools_list_result(tools))
      |> decode_frame()

    assert listed["result"]["cacheScope"] == "public"
    assert hd(listed["result"]["tools"])["name"] == "echo"
    assert hd(listed["result"]["tools"])["inputSchema"] == %{"type" => "object"}
    assert hd(listed["result"]["tools"])["_meta"]["ptc/application_content_digest"] == "abc"
  end

  test "encoded frames are one JSON document per line without Content-Length" do
    frame = Protocol.encode_result(1, %{"ok" => true})
    assert String.ends_with?(frame, "\n")
    assert length(String.split(frame, "\n", trim: true)) == 1
    refute frame =~ "Content-Length"
  end

  defp decode_frame(frame) do
    frame
    |> String.trim_trailing("\n")
    |> Jason.decode!()
  end
end
