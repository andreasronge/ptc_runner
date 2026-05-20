defmodule PtcRunnerMcp.StdioTest do
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Test.JsonRpcHarness

  setup do
    {:ok, harness} = JsonRpcHarness.start(max_frame_bytes: 1024)
    on_exit(fn -> JsonRpcHarness.stop(harness) end)
    {:ok, harness: harness}
  end

  test "initialize round-trip", %{harness: h} do
    [reply] =
      JsonRpcHarness.roundtrip(
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        },
        h
      )

    assert reply["id"] == 1
    assert reply["result"]["protocolVersion"] == "2025-11-25"
  end

  test "tools/call lisp_eval (+ 1 2) returns success envelope", %{harness: h} do
    [reply] =
      JsonRpcHarness.roundtrip(
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{
            "name" => "lisp_eval",
            "arguments" => %{"program" => "(+ 1 2)"}
          }
        },
        h
      )

    env = reply["result"]
    assert env["isError"] == false
    assert env["structuredContent"]["status"] == "ok"
    assert env["structuredContent"]["result"] == "user=> 3"
  end

  test "unknown tool name returns unknown_tool tool result", %{harness: h} do
    [reply] =
      JsonRpcHarness.roundtrip(
        %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{"name" => "nope"}
        },
        h
      )

    refute Map.has_key?(reply, "error")
    assert reply["result"]["isError"] == true
    assert reply["result"]["structuredContent"]["reason"] == "unknown_tool"
  end

  test "foo/bar returns JSON-RPC -32601", %{harness: h} do
    [reply] =
      JsonRpcHarness.roundtrip(
        %{"jsonrpc" => "2.0", "id" => 4, "method" => "foo/bar"},
        h
      )

    assert reply["error"]["code"] == -32_601
  end

  test "malformed JSON line returns -32700", %{harness: h} do
    [reply] = JsonRpcHarness.roundtrip("{not json}\n", h)
    assert reply["error"]["code"] == -32_700
    assert reply["id"] == nil
  end

  test "frame larger than max_frame_bytes returns -32700 and resyncs at next newline", %{
    harness: h
  } do
    # 1500 bytes > 1024 cap.
    big = String.duplicate("a", 1500)
    oversized_line = ~s({"junk":") <> big <> ~s("}\n)

    # After the oversized line, send a valid one. Both should land in
    # the same feed call.
    valid =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 9, "method" => "tools/list"}) <> "\n"

    replies = JsonRpcHarness.roundtrip(oversized_line <> valid, h)

    [parse_err, list_reply] = replies
    assert parse_err["error"]["code"] == -32_700
    assert list_reply["id"] == 9
    assert [%{"name" => "lisp_eval"}] = list_reply["result"]["tools"]
  end

  test "two consecutive frames in one feed are dispatched in order", %{harness: h} do
    bytes =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "a",
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-11-25"}
      }) <>
        "\n" <>
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => "b", "method" => "tools/list"}) <>
        "\n"

    [first, second] = JsonRpcHarness.roundtrip(bytes, h)
    assert first["id"] == "a"
    assert second["id"] == "b"
  end

  test "exit notification halts dispatch of trailing frames in the same chunk", %{harness: h} do
    # Buffered scenario: client sends `exit` followed by another request
    # in the same read chunk. Server must not dispatch (or reply to)
    # the trailing frame.
    bytes =
      Jason.encode!(%{"jsonrpc" => "2.0", "method" => "exit"}) <>
        "\n" <>
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 99, "method" => "tools/list"}) <>
        "\n"

    replies = JsonRpcHarness.roundtrip(bytes, h)

    # No reply for `exit` (notification); no reply for the trailing
    # `tools/list` because the loop is `:exited`.
    assert replies == []
  end

  test "stdout reply lines are valid JSON, one per line", %{harness: h} do
    [reply] =
      JsonRpcHarness.roundtrip(
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"},
        h
      )

    # If we got here, harness JSON-decoded the reply successfully —
    # i.e., the line on stdout was valid JSON terminated by \n.
    assert is_map(reply)
  end
end
