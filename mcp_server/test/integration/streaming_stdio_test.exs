defmodule PtcRunnerMcp.Integration.StreamingStdioTest do
  @moduledoc """
  Regression: the release must reply to an `initialize` request that
  arrives over a still-open stdin pipe. This is the posture every real
  MCP client uses (Claude Desktop, Claude Code, Cursor, Cline, MCP
  Inspector) — they write one request and wait for the reply without
  closing stdin first.

  Caught in the field: `IO.binread(io, 4096)` on `:stdio` blocks until
  4096 bytes OR EOF, so a single ~250-byte `initialize` line never
  triggered a read return and the server never replied. The
  `release_stdio_test.exs` suite missed this because it pipes a temp
  file (which closes stdin / hits EOF, flushing the buffered read).

  This test drives the release as an Erlang `Port` so stdin stays
  open between writes — exactly like a real MCP client.
  """

  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Test.ReleaseRunner

  @moduletag :integration
  @moduletag :release
  @moduletag timeout: 30_000
  @no_upstreams_env [
    {~c"RELEASE_DISTRIBUTION", ~c"none"},
    {~c"PTC_RUNNER_MCP_UPSTREAMS", ~c"/nonexistent/ptc_runner_mcp_streaming_stdio_test"},
    {~c"PTC_RUNNER_MCP_RESPONSE_PROFILE", ~c"slim"}
  ]

  setup_all do
    unless ReleaseRunner.release_built?() do
      flunk(
        "release artifact not built at #{ReleaseRunner.release_bin()}. " <>
          "Run `MIX_ENV=prod mix release --overwrite` from `mcp_server/` first."
      )
    end

    :ok
  end

  test "release replies to streaming initialize without stdin EOF" do
    # Wrapper script: redirect stderr to /dev/null so the Port only
    # carries JSON-RPC replies on stdout. Otherwise log lines on the
    # child's stderr show up under the same Port `{:data, _}` channel
    # and we'd have to filter them out.
    bin = ReleaseRunner.release_bin()

    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          {:env, @no_upstreams_env},
          {:args, ["-c", "exec #{bin} start 2>/dev/null"]}
        ]
      )

    # Capture the OS pid of the `/bin/sh` we spawned so cleanup is
    # scoped to *this* test's process tree rather than `pkill -f`'ing
    # every release on the box (which would clobber a parallel test
    # run or a developer's running release).
    sh_os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    on_exit(fn ->
      try do
        Port.close(port)
      catch
        _, _ -> :ok
      end

      if sh_os_pid do
        # The wrapper does `exec #{bin} start`, so this OS pid IS the
        # BEAM process (exec replaces the shell in-place, keeping the
        # pid). Kill just that process — best-effort.
        _ = System.cmd("/bin/sh", ["-c", "kill -9 #{sh_os_pid} 2>/dev/null; true"])
      end
    end)

    init_line = Jason.encode!(ReleaseRunner.init_request(1)) <> "\n"
    true = Port.command(port, init_line)

    {reply, leftover} =
      receive_reply(port, "", 10_000)

    assert reply["id"] == 1, "expected reply for id 1, got #{inspect(reply)}"
    assert reply["result"]["protocolVersion"] in ["2025-11-25", "2025-06-18"]
    assert reply["result"]["serverInfo"]["name"] == "ptc_lisp"

    # Now drive a `tools/call` over the same still-open stdin to make
    # sure the streaming path goes all the way through the async worker
    # (start → run → reply on stdout). If this hangs the test fails
    # with a clear message instead of looking like a "no reply" issue.
    init_notif = Jason.encode!(ReleaseRunner.initialized_notif()) <> "\n"

    call =
      Jason.encode!(ReleaseRunner.tools_call_request(2, "lisp_eval", %{"program" => "(+ 1 2 3)"})) <>
        "\n"

    true = Port.command(port, init_notif)
    true = Port.command(port, call)

    {call_reply, _rest} = receive_reply(port, leftover, 10_000)
    assert call_reply["id"] == 2, "expected reply for id 2, got #{inspect(call_reply)}"
    result = call_reply["result"]
    assert result["isError"] == false, "expected isError false, got #{inspect(result)}"
    assert [%{"type" => "text", "text" => "user=> 6"}] = result["content"]
    refute Map.has_key?(result, "structuredContent")
  end

  # The release may emit log lines on stdout in addition to JSON-RPC
  # frames, and a single `{:data, _}` message may be a partial line.
  # Accumulate until we have a full line that decodes to a JSON-RPC
  # reply with an `id`.
  defp receive_reply(port, buffer, timeout_ms) do
    receive do
      {^port, {:data, chunk}} ->
        case extract_reply(buffer <> chunk) do
          {:ok, reply, rest} -> {reply, rest}
          {:incomplete, new_buffer} -> receive_reply(port, new_buffer, timeout_ms)
        end
    after
      timeout_ms ->
        flunk(
          "no JSON-RPC reply received within #{timeout_ms}ms — server " <>
            "did not respond on the streaming pipe. Buffer so far: " <>
            inspect(buffer)
        )
    end
  end

  defp extract_reply(buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [^buffer] ->
        {:incomplete, buffer}

      [line, rest] ->
        case Jason.decode(line) do
          {:ok, %{"jsonrpc" => "2.0", "id" => _} = m} -> {:ok, m, rest}
          _ -> extract_reply(rest)
        end
    end
  end
end
