defmodule PtcRunnerMcp.StdioLatin1Test do
  @moduledoc """
  Phase 4 hardening (Plans/ptc-runner-mcp-aggregator.md §16 entry 1):
  the public-facing `PtcRunnerMcp.Stdio` port MUST run in raw-byte
  mode so UTF-8 bytes outside Latin1 (e.g., em-dash `—` = `0xE2 0x80
  0x94`) do not crash the entire MCP server with
  `{:no_translation, :unicode, :latin1}` before the `max_frame_bytes`
  guard can fire.

  These tests are the regression bar for that fix.

    * `configure_io_for_binary/1` is the seam that calls
      `:io.setopts(io, encoding: :latin1)`. Verifying it transitions
      a device's encoding is the targeted reproduction: pre-fix the
      IO device retained its default `encoding: :unicode`, so
      `IO.binread/2` aborted on the first non-Latin1 byte.
    * Round-tripping a `tools/call` whose program string contains
      em-dash punctuation through the harness emits a clean reply
      without corruption.
    * `IO.binwrite/2` (vs. `IO.write/2`) is used for replies so the
      raw JSON bytes are emitted verbatim under `encoding: :latin1`
      (which would otherwise escape non-Latin1 codepoints to
      `\\x{...}` and corrupt the wire format).

  StringIO doesn't honor runtime `setopts/2` (returns `:enotsup`),
  so the post-fix-state tests open StringIO with `encoding: :latin1`
  upfront — that mirrors what `:standard_io` looks like after our
  in-init `setopts` call in production.

  See also: `test/integration/streaming_stdio_test.exs` for the
  release-level streaming check; this file focuses on the unit
  contract.
  """

  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Stdio

  describe "Phase 4 hardening: raw-byte IO mode (§16 entry 1)" do
    test "configure_io_for_binary/1 is wired into Stdio.init/1" do
      # White-box check: instrument a process that traps
      # `:io.setopts/2` calls so we can prove that
      # `Stdio.start_link/1` issues the setopts request to the IO
      # device synchronously inside `init/1`, BEFORE any read
      # attempt. A pre-fix server (no `configure_io_for_binary/1`
      # call) would never send the request and this test would
      # fail with no `:setopts` recorded.

      test_pid = self()

      # Spawn an IO-server stand-in that just forwards requests
      # back to the test process so we can observe them. The
      # `getopts`/`setopts` MCP-style messages are forwarded
      # verbatim; everything else is acknowledged with a benign
      # `:eof` so `Stdio.init/1` and the reader loop don't block.
      io_pid =
        spawn_link(fn ->
          io_loop = fn loop ->
            receive do
              {:io_request, from, ref, {:setopts, opts}} ->
                send(test_pid, {:setopts_seen, opts})
                send(from, {:io_reply, ref, :ok})
                loop.(loop)

              {:io_request, from, ref, {:get_chars, _, _, _}} ->
                # Reader loop calls this. Reply with eof so the
                # reader exits cleanly and `init/1` can proceed.
                send(from, {:io_reply, ref, :eof})
                loop.(loop)

              {:io_request, from, ref, {:get_line, _, _}} ->
                send(from, {:io_reply, ref, :eof})
                loop.(loop)

              {:io_request, from, ref, _other} ->
                send(from, {:io_reply, ref, :ok})
                loop.(loop)

              :stop ->
                :ok
            end
          end

          io_loop.(io_loop)
        end)

      {:ok, stdio} =
        Stdio.start_link(
          io: io_pid,
          observer: self(),
          # Disable auto_read so the reader_loop doesn't fight
          # us for IO requests during this assertion.
          auto_read: false,
          name: :"stdio_latin1_init_probe_#{System.unique_integer([:positive])}"
        )

      # The setopts MUST land in our io server's mailbox during
      # `Stdio.init/1` — i.e., synchronously, before
      # `start_link/1` returns. After-the-fact assertion is fine
      # because `assert_receive` blocks until the message arrives
      # or times out.
      assert_receive {:setopts_seen, opts}, 1_000

      # The fix sets BOTH `binary: true` (raw bytes) and
      # `encoding: :latin1` (no UTF-8 translation). Either alone
      # would not be enough on `:standard_io`.
      assert Keyword.get(opts, :encoding) == :latin1,
             "expected encoding: :latin1, got opts: #{inspect(opts)}"

      assert Keyword.get(opts, :binary) == true,
             "expected binary: true, got opts: #{inspect(opts)}"

      GenServer.stop(stdio, :normal)
      send(io_pid, :stop)
    end

    test "configure_io_for_binary/1 tolerates a device that does not support setopts" do
      # `StringIO` returns `{:error, :enotsup}` for `setopts`. The
      # harness uses StringIO; we MUST NOT crash on devices that
      # reject the request. This is the property test for that
      # graceful degradation.
      {:ok, io} = StringIO.open(<<>>, capture_prompt: false)
      assert :ok = Stdio.configure_io_for_binary(io)
      StringIO.close(io)
    end

    test "tools/call with non-ASCII em-dash in program returns a clean reply" do
      # End-to-end round-trip: an em-dash in the program text
      # round-trips through the framing, decode, sandbox, encode,
      # and write paths without corruption. Pre-fix the server
      # would never reach the sandbox at all (the read aborted
      # at `:no_translation, :unicode, :latin1`); post-fix the
      # bytes pass through verbatim.
      #
      # The harness uses `StringIO`, which is already binary-safe
      # at the test harness level. The discriminating assertion
      # for THIS test is that the byte-perfect em-dash makes it
      # all the way back out — a regression to `IO.write/2` under
      # `encoding: :latin1` would have escaped `—` to `\\x{2014}`
      # in the reply preview.
      io = open_latin1_stringio(<<>>)
      stdio = start_stdio_with_io(io)

      try do
        bytes =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/call",
            "params" => %{
              "name" => "ptc_lisp_execute",
              "arguments" => %{"program" => ~S|(str "smart-quote em-dash —")|}
            }
          }) <> "\n"

        :ok = Stdio.feed(stdio, bytes)
        # Async tools/call worker — wait for the observer reply
        # notification (Phase 4 worker pattern, mirrors what the
        # JsonRpcHarness does internally).
        assert_receive {Stdio, :replied, frame}, 2_000

        env = frame["result"]
        assert env["isError"] == false, "envelope was: #{inspect(env)}"

        result_str = env["structuredContent"]["result"]
        # The em-dash MUST appear as its UTF-8 byte sequence
        # (0xE2 0x80 0x94). A regression to `IO.write/2` under
        # Latin1 mode would emit `\\x{2014}` instead — JSON would
        # parse but the literal codepoint would be missing.
        assert String.contains?(result_str, <<0xE2, 0x80, 0x94>>),
               "expected raw UTF-8 em-dash bytes, got: #{inspect(result_str)}"

        refute String.contains?(result_str, "\\x{2014}"),
               "result was Latin1-escaped instead of raw UTF-8: #{inspect(result_str)}"
      after
        GenServer.stop(stdio, :normal, 1_000)
        StringIO.close(io)
      end
    end

    test "outgoing reply containing non-ASCII bytes is JSON-decodable verbatim" do
      # Reads what's actually on the StringIO buffer (i.e. the
      # bytes that would have hit stdout in production) and
      # asserts it decodes as valid JSON. Pre-fix under Latin1
      # mode WITH `IO.write/2`, the em-dash codepoint inside the
      # reply preview would be emitted as the literal six-byte
      # sequence `\\x{2014}` — which, as a JSON literal, is a
      # backslash-escape that Jason rejects (`{` is not a valid
      # escape continuation).
      io = open_latin1_stringio(<<>>)
      stdio = start_stdio_with_io(io)

      try do
        bytes =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 7,
            "method" => "tools/call",
            "params" => %{
              "name" => "ptc_lisp_execute",
              "arguments" => %{"program" => ~S|(str "delta — gamma")|}
            }
          }) <> "\n"

        :ok = Stdio.feed(stdio, bytes)
        assert_receive {Stdio, :replied, _frame}, 2_000

        # Drain the StringIO's output buffer — this is exactly
        # what the wire would carry.
        {_, output} = StringIO.contents(io)

        assert is_binary(output) and byte_size(output) > 0,
               "expected non-empty StringIO output"

        # Each line must be a valid JSON-RPC frame. If `IO.write`
        # had been used under Latin1 mode, the em-dash would have
        # been emitted as `\\x{2014}` — invalid JSON.
        for line <- String.split(output, "\n", trim: true) do
          assert {:ok, _decoded} = Jason.decode(line),
                 "non-JSON line on the wire (sign of Latin1 escape regression): #{inspect(line)}"
        end

        refute String.contains?(output, "\\x{"),
               "wire bytes contain a Latin1 escape sequence: #{inspect(output)}"

        # And the raw em-dash bytes are present.
        assert String.contains?(output, <<0xE2, 0x80, 0x94>>),
               "raw UTF-8 em-dash bytes missing from wire: #{inspect(output)}"
      after
        GenServer.stop(stdio, :normal, 1_000)
        StringIO.close(io)
      end
    end

    test "frame larger than max_frame_bytes is rejected pre-decode without crashing" do
      # Phase 4 hardening invariant: the cap on raw bytes fires
      # BEFORE any UTF-8 / JSON decode happens. This is a
      # guardrail test rather than a behavioral change — the
      # existing pre-decode walker in `feed_bytes/2` was already
      # correct; we're confirming the Latin1-mode change doesn't
      # accidentally regress it. A pre-decode crash would
      # manifest as the harness either timing out or returning
      # a non-`-32700` frame.
      io = open_latin1_stringio(<<>>)
      stdio = start_stdio_with_io(io, max_frame_bytes: 256)

      try do
        big = String.duplicate("a", 1024)
        oversized = ~s({"junk":") <> big <> ~s("}\n)

        valid_followup =
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => 99, "method" => "tools/list"}) <> "\n"

        :ok = Stdio.feed(stdio, oversized <> valid_followup)
        assert_receive {Stdio, :replied, _f1}, 1_000
        assert_receive {Stdio, :replied, _f2}, 1_000

        {_, output} = StringIO.contents(io)
        replies = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
        [parse_err, list_reply] = replies
        assert parse_err["error"]["code"] == -32_700
        assert list_reply["id"] == 99
      after
        GenServer.stop(stdio, :normal, 1_000)
        StringIO.close(io)
      end
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp open_latin1_stringio(initial) do
    # StringIO.open's `:encoding` opt is the equivalent of our
    # production `:io.setopts/2` call: it puts the device in
    # raw-byte mode upfront. Tests that want to assert the
    # post-fix steady state use this; it mirrors what
    # `:standard_io` looks like after `init/1` runs.
    {:ok, io} = StringIO.open(initial, encoding: :latin1, capture_prompt: false)
    io
  end

  defp start_stdio_with_io(io, opts \\ []) do
    name = :"stdio_latin1_#{System.unique_integer([:positive])}"

    {:ok, stdio} =
      Stdio.start_link(
        Keyword.merge(
          [io: io, observer: self(), auto_read: false, name: name, max_frame_bytes: 64 * 1024],
          opts
        )
      )

    stdio
  end
end
