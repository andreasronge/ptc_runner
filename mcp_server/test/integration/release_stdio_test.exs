defmodule PtcRunnerMcp.Integration.ReleaseStdioTest do
  @moduledoc """
  Phase 6a — live integration test that drives the built
  `ptc_runner_mcp` Mix release as an external subprocess and exchanges
  NDJSON-framed JSON-RPC frames over a real POSIX stdio pipe (via a
  `/bin/sh -c` wrapper). This is the same end-to-end posture as
  MCP Inspector / Claude Desktop / Cursor / Cline driving the
  release, scripted from ExUnit.

  Satisfies `Plans/ptc-runner-mcp-server.md` § 15 Phase 6 (live
  integration tests) and provides the production-client gate for the
  D1 deviation in § 7.4 (unknown-tool returns a tool result, not
  `-32601`).

  This suite is excluded from the default `mix test` run via
  `test_helper.exs` and runs only when explicitly requested:

      MIX_ENV=prod mix release --overwrite
      mix test --only integration

  The release artifact is required at
  `_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp`. If absent, all
  cases here fail fast with a clear message. To produce it, run the
  command above before executing this suite.

  ## Known limitation (Phase 5 production-code bug, FOUND in Phase 6a)

  The `tools/call name: "lisp_eval"` happy-path is currently
  blocked in the release artifact: `:crypto` is not bundled into the
  Mix release, and `PtcRunnerMcp.TracePayload.redact_program/2` calls
  `:crypto.hash(:sha256, ...)` unconditionally on every `tools/call`
  whose `arguments.program` is set. The worker raises
  `UndefinedFunctionError` and no reply is emitted. Tests that need
  `tools/call` with a program present are tagged
  `@tag :skip` with a `bug:` reason — they are deferred until that
  bug is fixed (out of scope for Phase 6a per § 20.5 risk 2).

  Paths that do NOT touch `redact_program(program, level)` work
  fine: `initialize`, `tools/list`, `tools/call name: "<unknown>"`
  (D1 gate), and `tools/call name: "lisp_eval"` with no
  `program` (args_error).
  """

  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Test.ReleaseRunner

  @moduletag :integration
  @moduletag :release
  # Each release boot spins up a fresh BEAM VM in a child process —
  # leave plenty of headroom for cold-start.
  @moduletag timeout: 60_000

  setup_all do
    unless ReleaseRunner.release_built?() do
      flunk(
        "release artifact not built at #{ReleaseRunner.release_bin()}. " <>
          "Run `MIX_ENV=prod mix release --overwrite` from `mcp_server/` first."
      )
    end

    :ok
  end

  describe "handshake" do
    test "initialize → tools/list against the real release binary" do
      frames = [
        ReleaseRunner.init_request(1),
        ReleaseRunner.initialized_notif(),
        ReleaseRunner.tools_list_request(2),
        ReleaseRunner.exit_notif()
      ]

      assert {:ok, replies, status, _stderr} = ReleaseRunner.run_session(frames)
      assert status == 0, "release exit_status should be 0, got #{inspect(status)}"

      # Two responses (initialize, tools/list) — notifications and
      # `exit` produce none.
      ids = replies |> Enum.map(& &1["id"]) |> Enum.sort()
      assert ids == [1, 2], "expected replies for ids 1, 2 — got #{inspect(ids)}"

      init_reply = Enum.find(replies, &(&1["id"] == 1))
      assert init_reply["result"]["protocolVersion"] == "2025-11-25"
      assert init_reply["result"]["capabilities"]["tools"]["listChanged"] == false
      assert init_reply["result"]["serverInfo"]["name"] == "ptc_lisp"
      assert is_binary(init_reply["result"]["serverInfo"]["version"])

      list_reply = Enum.find(replies, &(&1["id"] == 2))
      tools = list_reply["result"]["tools"]
      assert is_list(tools)
      assert length(tools) == 1

      tool = hd(tools)
      assert tool["name"] == "lisp_eval"
      assert is_map(tool["inputSchema"])
      assert is_map(tool["outputSchema"])
      assert tool["annotations"]["readOnlyHint"] == true
      assert tool["annotations"]["idempotentHint"] == true
      assert tool["annotations"]["destructiveHint"] == false
      assert tool["annotations"]["openWorldHint"] == false
    end

    test "release start forwards app CLI flags through env.sh" do
      frames = [
        ReleaseRunner.init_request(1),
        ReleaseRunner.initialized_notif(),
        ReleaseRunner.tools_list_request(2),
        ReleaseRunner.exit_notif()
      ]

      assert {:ok, replies, 0, _stderr} =
               ReleaseRunner.run_session(frames, args: ["start", "--debug-tool"])

      list_reply = Enum.find(replies, &(&1["id"] == 2))
      tools = list_reply["result"]["tools"]
      names = Enum.map(tools, & &1["name"])

      assert "lisp_eval" in names
      assert "lisp_debug" in names
    end

    test "release start forwards --sessions through env.sh" do
      frames = [
        ReleaseRunner.init_request(1),
        ReleaseRunner.initialized_notif(),
        ReleaseRunner.tools_list_request(2),
        ReleaseRunner.exit_notif()
      ]

      assert {:ok, replies, 0, _stderr} =
               ReleaseRunner.run_session(frames, args: ["start", "--sessions"])

      list_reply = Enum.find(replies, &(&1["id"] == 2))
      names = Enum.map(list_reply["result"]["tools"], & &1["name"])

      assert "lisp_eval" in names
      assert "lisp_session_start" in names
      assert "lisp_session_eval" in names
      assert "lisp_session_close" in names
    end

    test "initialize with compatibility-floor 2025-06-18 negotiates to 2025-06-18" do
      init_request =
        Map.put(ReleaseRunner.init_request(1), "params", %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "phase6a-integration", "version" => "1"}
        })

      frames = [init_request, ReleaseRunner.exit_notif()]

      assert {:ok, [reply], 0, _stderr} = ReleaseRunner.run_session(frames)
      assert reply["id"] == 1
      assert reply["result"]["protocolVersion"] == "2025-06-18"
    end
  end

  describe "tools/call D1 deviation gate (§ 7.4)" do
    test "unknown tool returns tool-result with reason:unknown_tool, NOT -32601" do
      # § 7.4 D1 production-client gate: a real release subprocess
      # must answer an unknown-tool request with an MCP tool result
      # (`isError: true`), NOT a JSON-RPC `-32601 Method not found`.
      # If this assertion ever flips, v1 falls back to `-32601` per
      # the deviation contract.
      frames = [
        ReleaseRunner.init_request(1),
        ReleaseRunner.initialized_notif(),
        ReleaseRunner.tools_call_request(200, "nope_no_such_tool"),
        ReleaseRunner.exit_notif()
      ]

      assert {:ok, replies, 0, _stderr} = ReleaseRunner.run_session(frames)

      reply = Enum.find(replies, &(&1["id"] == 200))
      assert reply, "no reply for unknown-tool request id 200; got #{inspect(replies)}"

      # D1: NOT a JSON-RPC error envelope.
      refute Map.has_key?(reply, "error"),
             "D1 deviation: unknown tool MUST yield an MCP tool result, not " <>
               "a JSON-RPC `error`; got: #{inspect(reply)}"

      result = reply["result"]
      assert result["isError"] == true
      sc = result["structuredContent"]
      assert sc["status"] == "error"
      assert sc["reason"] == "unknown_tool"
      assert is_binary(sc["message"])
      assert is_binary(sc["feedback"])

      # § 10.5 isError discipline mirror block: single text content,
      # JSON-decoded text equals structuredContent.
      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert Jason.decode!(text) == sc
    end
  end

  describe "tools/call args_error path" do
    test "missing `program` argument returns reason:args_error envelope" do
      # This path does NOT trigger `redact_program(program, ...)` —
      # `program` is nil — so it survives the Phase 5 `:crypto` bug
      # and gives us a real end-to-end success-shape gate from a
      # production-style client.
      frames = [
        ReleaseRunner.init_request(1),
        ReleaseRunner.initialized_notif(),
        ReleaseRunner.tools_call_request(300, "lisp_eval", %{}),
        ReleaseRunner.exit_notif()
      ]

      assert {:ok, replies, 0, _stderr} = ReleaseRunner.run_session(frames)
      reply = Enum.find(replies, &(&1["id"] == 300))
      assert reply, "no reply for id 300; got #{inspect(replies)}"

      result = reply["result"]
      assert result["isError"] == true
      sc = result["structuredContent"]
      assert sc["status"] == "error"
      assert sc["reason"] == "args_error"
      assert is_binary(sc["message"])
    end
  end

  describe "tools/call success path (R22)" do
    # Bug "phase5-crypto-missing-from-release" was Phase 6a's diagnosis:
    # the Mix release boot script did not load `:crypto`, so
    # `TracePayload.sha256_hex/1` raised `:crypto.hash/2 is undefined`
    # for every tool call with a `program` argument. Fixed by adding
    # `:crypto` to `extra_applications` in `mcp_server/mix.exs`. The
    # @tag :skip was removed once the fix landed; this test now verifies
    # the release end-to-end success path.
    test "(+ 1 2) returns isError:false with result \"user=> 3\"" do
      frames = [
        ReleaseRunner.init_request(1),
        ReleaseRunner.initialized_notif(),
        ReleaseRunner.tools_call_request(100, "lisp_eval", %{
          "program" => "(+ 1 2)"
        }),
        ReleaseRunner.exit_notif()
      ]

      assert {:ok, replies, 0, _stderr} = ReleaseRunner.run_session(frames)
      reply = Enum.find(replies, &(&1["id"] == 100))
      assert reply, "no reply for id 100"

      result = reply["result"]
      assert result["isError"] == false
      sc = result["structuredContent"]
      assert sc["status"] == "ok"
      assert sc["result"] == "user=> 3"
    end
  end

  describe "exit notification" do
    test "release subprocess terminates with status 0 on `exit`" do
      frames = [
        ReleaseRunner.init_request(1),
        ReleaseRunner.exit_notif()
      ]

      assert {:ok, _replies, 0, _stderr} = ReleaseRunner.run_session(frames)
    end

    test "release subprocess terminates with status 0 on stdin EOF (§ 6.4 row 1)" do
      # No `exit` frame — the runner finishes writing its frames and
      # the OS pipe hits EOF; the server detects EOF and shuts down.
      frames = [ReleaseRunner.init_request(1)]
      assert {:ok, _replies, 0, _stderr} = ReleaseRunner.run_session(frames)
    end
  end
end
