defmodule PtcRunnerMcp.Upstream.Http.SseDecoderTest do
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.Upstream.Http.SseDecoder

  @telemetry_event [:ptc_lisp, :upstream, :http, :sse_array_compat]
  @big_cap 1_000_000

  # Telemetry handler that forwards events back to a test pid carried
  # in the handler config. Defined as a named module function (rather
  # than an anonymous capture) to avoid `:telemetry`'s local-fun perf
  # warning in the test logs.
  def __forward_telemetry__(event, measurements, metadata, %{test_pid: pid}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  setup do
    # Each test gets a unique handler id so async tests don't fight
    # over one detached/attached telemetry handler.
    test_pid = self()
    handler_id = {:sse_decoder_test, test_pid, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        @telemetry_event,
        &__MODULE__.__forward_telemetry__/4,
        %{test_pid: test_pid}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  describe "decode_stream/2 — single-message form (2025-06-18 default)" do
    test "decodes one event with one JSON-RPC object matching request_id" do
      event = ~s(data: {"jsonrpc":"2.0","id":1,"result":{"ok":true}}\n\n)

      assert {:ok, %{"id" => 1, "result" => %{"ok" => true}}} =
               SseDecoder.decode_stream([event], request_id: 1, max_bytes: @big_cap)
    end

    test "drops a leading notification, returns the second event with the response" do
      notify = ~s(data: {"jsonrpc":"2.0","method":"upstream/progress"}\n\n)
      response = ~s(data: {"jsonrpc":"2.0","id":7,"result":42}\n\n)

      assert {:ok, %{"id" => 7, "result" => 42}} =
               SseDecoder.decode_stream([notify <> response],
                 request_id: 7,
                 max_bytes: @big_cap
               )
    end

    test "different request id then close → :stream_closed_before_response" do
      event = ~s(data: {"jsonrpc":"2.0","id":2,"result":{}}\n\n)

      assert {:error, :stream_closed_before_response, detail} =
               SseDecoder.decode_stream([event], request_id: 1, max_bytes: @big_cap)

      assert detail =~ "id=1"
    end

    test "stream closes with no events at all" do
      assert {:error, :stream_closed_before_response, detail} =
               SseDecoder.decode_stream([], request_id: 1, max_bytes: @big_cap)

      assert detail =~ "id=1"
    end
  end

  describe "decode_stream/2 — array-form backward-compat (OQ-9)" do
    test "extracts the matching id from a JSON array, drops the rest, fires telemetry" do
      payload =
        ~s([{"jsonrpc":"2.0","method":"notify"},) <>
          ~s({"jsonrpc":"2.0","id":1,"result":{"answer":42}},) <>
          ~s({"jsonrpc":"2.0","id":99,"result":"ignored"}])

      event = "data: " <> payload <> "\n\n"

      assert {:ok, %{"id" => 1, "result" => %{"answer" => 42}}} =
               SseDecoder.decode_stream([event], request_id: 1, max_bytes: @big_cap)

      assert_receive {:telemetry, @telemetry_event, %{count: 1}, %{}}
    end

    test "array with no matching id closes without response, but still fires telemetry" do
      payload = ~s([{"jsonrpc":"2.0","method":"notify"}])
      event = "data: " <> payload <> "\n\n"

      assert {:error, :stream_closed_before_response, _} =
               SseDecoder.decode_stream([event], request_id: 1, max_bytes: @big_cap)

      assert_receive {:telemetry, @telemetry_event, %{count: 1}, %{}}
    end
  end

  describe "decode_stream/2 — :max_bytes pre-decode cap" do
    test "cumulative cap aborts before second chunk is decoded" do
      # 2 KB filler chunk (well under cap, but burns 2048 of the 4096
      # budget). The second chunk pushes us over.
      filler = String.duplicate("a", 2048)
      chunk1 = "data: \"#{filler}\"\n\n"
      chunk2 = String.duplicate("b", 3072)

      cap = 4096

      assert {:error, :response_too_large, detail} =
               SseDecoder.decode_stream([chunk1, chunk2], request_id: 1, max_bytes: cap)

      cumulative = byte_size(chunk1) + byte_size(chunk2)
      assert detail =~ "#{cumulative} bytes"
      assert detail =~ "max_bytes (#{cap})"
    end

    test "single oversized chunk also trips the cap" do
      # 5 KB chunk against a 4 KB cap.
      chunk = String.duplicate("x", 5120)

      assert {:error, :response_too_large, detail} =
               SseDecoder.decode_stream([chunk], request_id: 1, max_bytes: 4096)

      assert detail =~ "5120 bytes"
      assert detail =~ "max_bytes (4096)"
    end

    test "exactly-at-cap is permitted (cap is exclusive of 'exceeds')" do
      # Cap equals chunk size: NOT a violation. Stream still has no
      # response, so we get :stream_closed_before_response, NOT
      # :response_too_large. Proves the comparison is strictly `>`.
      event = ~s(data: {"jsonrpc":"2.0","method":"notify"}\n\n)

      assert {:error, :stream_closed_before_response, _} =
               SseDecoder.decode_stream([event],
                 request_id: 1,
                 max_bytes: byte_size(event)
               )
    end
  end

  describe "decode_stream/2 — RFC compliance" do
    test "multi-line data: payloads are joined with \\n per RFC" do
      # Per RFC, multiple `data:` lines within one event are joined
      # by `\n` after stripping each `data: ` prefix. We pick a JSON
      # value that happens to be valid both as a one-liner and as a
      # multi-line concatenation: a string with an embedded `\n` is
      # the canonical proof.
      #
      # Wire bytes: `data: "line1\ndata: line2"\n\n`
      # → after extraction: `"line1\nline2"`
      # → JSON decode: "line1\nline2"
      #
      # That decoded string is not a JSON-RPC object, so it's
      # dropped. Add a real response after it to keep the test
      # asserting end-to-end behaviour.
      multi = "data: \"line1\ndata: line2\"\n\n"
      response = ~s(data: {"jsonrpc":"2.0","id":1,"result":"ok"}\n\n)

      assert {:ok, %{"id" => 1, "result" => "ok"}} =
               SseDecoder.decode_stream([multi <> response],
                 request_id: 1,
                 max_bytes: @big_cap
               )
    end

    test "boundary split across chunks reassembles correctly" do
      chunk1 = ~s(data: {"jsonrpc":"2.0","id")
      chunk2 = ~s(:1,"result":{}}\n\n)

      assert {:ok, %{"id" => 1, "result" => %{}}} =
               SseDecoder.decode_stream([chunk1, chunk2],
                 request_id: 1,
                 max_bytes: @big_cap
               )
    end

    test "ignores event:, id:, retry: lines (and unknown ones)" do
      event = """
      event: message
      id: 42
      retry: 5000
      data: {"jsonrpc":"2.0","id":1,"result":"ok"}

      """

      assert {:ok, %{"id" => 1, "result" => "ok"}} =
               SseDecoder.decode_stream([event], request_id: 1, max_bytes: @big_cap)
    end

    test "final event without trailing \\n\\n is still decoded on stream close" do
      # No `\n\n` at end; some servers omit it.
      event = ~s(data: {"jsonrpc":"2.0","id":1,"result":"ok"})

      assert {:ok, %{"id" => 1, "result" => "ok"}} =
               SseDecoder.decode_stream([event], request_id: 1, max_bytes: @big_cap)
    end

    test "tolerates \\r\\n\\r\\n event boundary (CRLF line endings)" do
      event = ~s(data: {"jsonrpc":"2.0","id":1,"result":"ok"}\r\n\r\n)

      assert {:ok, %{"id" => 1, "result" => "ok"}} =
               SseDecoder.decode_stream([event], request_id: 1, max_bytes: @big_cap)
    end
  end

  describe "decode_binary/2" do
    test "is a thin wrapper that decodes a buffered binary" do
      bytes = ~s(data: {"jsonrpc":"2.0","id":1,"result":"ok"}\n\n)

      assert {:ok, %{"id" => 1, "result" => "ok"}} =
               SseDecoder.decode_binary(bytes, request_id: 1, max_bytes: @big_cap)
    end
  end
end
