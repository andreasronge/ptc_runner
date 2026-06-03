defmodule PtcRunner.Upstream.Transport.McpHttp.SseDecoderTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Upstream.Transport.McpHttp.SseDecoder

  # SseDecoder scans an SSE byte stream for the JSON-RPC response matching a
  # request id. It is a memory-DoS guard (byte cap across chunks) and a
  # liveness guard (errors when the stream closes before the response). We
  # drive both decode_binary/2 (whole-body) and decode_stream/2 (chunked).

  @opts [request_id: 7, max_bytes: 1_000]

  defp event(id), do: ~s(data: {"jsonrpc":"2.0","id":#{id},"result":{"ok":true}}\n\n)

  describe "decode_binary/2" do
    test "extracts the matching response from a single SSE event" do
      assert {:ok, msg} = SseDecoder.decode_binary(event(7), @opts)
      assert msg["id"] == 7
      assert msg["result"] == %{"ok" => true}
    end

    test "skips earlier events whose id does not match" do
      body = event(1) <> event(2) <> event(7)
      assert {:ok, %{"id" => 7}} = SseDecoder.decode_binary(body, @opts)
    end

    test "handles CRLF event boundaries and a leading space after data:" do
      body = "data: {\"id\":7,\"v\":1}\r\n\r\n"
      assert {:ok, %{"id" => 7, "v" => 1}} = SseDecoder.decode_binary(body, @opts)
    end

    test "joins multi-line data: payloads within one event" do
      body = ~s(data: {"id":7,\ndata: "v":2}\n\n)
      assert {:ok, %{"id" => 7, "v" => 2}} = SseDecoder.decode_binary(body, @opts)
    end

    test "flushes a trailing event with no terminating blank line" do
      body = ~s(data: {"id":7,"trailing":true})
      assert {:ok, %{"id" => 7, "trailing" => true}} = SseDecoder.decode_binary(body, @opts)
    end

    test "matches a response carried inside a JSON array batch" do
      body = ~s(data: [{"id":1},{"id":7,"hit":true}]\n\n)
      assert {:ok, %{"id" => 7, "hit" => true}} = SseDecoder.decode_binary(body, @opts)
    end

    test "ignores non-data lines and malformed JSON, then errors when exhausted" do
      body = ":keepalive comment\n\ndata: not-json\n\n"

      assert {:error, :stream_closed_before_response, msg} =
               SseDecoder.decode_binary(body, @opts)

      assert msg =~ "id=7"
    end

    test "empty body closes before a response" do
      assert {:error, :stream_closed_before_response, _} = SseDecoder.decode_binary("", @opts)
    end
  end

  describe "decode_stream/2 chunk boundaries" do
    test "reassembles a JSON object split across chunk boundaries" do
      chunks = ["data: {\"id\":7,", "\"split\":true}\n\n"]
      assert {:ok, %{"id" => 7, "split" => true}} = SseDecoder.decode_stream(chunks, @opts)
    end

    test "buffers multiple events across chunks and returns the matching one" do
      chunks = [event(1) <> "data: {\"id\":", "7,\"buffered\":true}\n\n"]
      assert {:ok, %{"id" => 7, "buffered" => true}} = SseDecoder.decode_stream(chunks, @opts)
    end

    test "an exhausted stream with no match closes before response" do
      chunks = [event(1), event(2)]

      assert {:error, :stream_closed_before_response, msg} =
               SseDecoder.decode_stream(chunks, @opts)

      assert msg =~ "id=7"
    end
  end

  describe "byte cap (memory-DoS guard)" do
    test "a single oversized chunk is rejected" do
      big = String.duplicate("x", 2_000)

      assert {:error, :response_too_large, msg} =
               SseDecoder.decode_binary("data: " <> big <> "\n\n", request_id: 7, max_bytes: 100)

      assert msg =~ "exceeds max_bytes (100)"
    end

    test "the cap accumulates across chunks before any match is found" do
      # Neither chunk alone exceeds the cap, but together they do; the decoder
      # must reject on the cumulative byte count, not per-chunk.
      chunks = [String.duplicate("a", 60), String.duplicate("b", 60)]

      assert {:error, :response_too_large, msg} =
               SseDecoder.decode_stream(chunks, request_id: 7, max_bytes: 100)

      assert msg =~ "120 bytes"
    end

    test "a matching response found before the cap is reached still returns ok" do
      # The matching event arrives in the first chunk; a later oversized chunk
      # is never consumed because reduce_while halts on the match.
      chunks = [event(7), String.duplicate("z", 5_000)]
      assert {:ok, %{"id" => 7}} = SseDecoder.decode_stream(chunks, request_id: 7, max_bytes: 200)
    end
  end
end
