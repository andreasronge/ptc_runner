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

  The release defaults to the `:slim` response profile. Stateless
  `lisp_eval` results therefore return plain text only, without
  `structuredContent` or `outputSchema`. Stateful session mode is a
  separate API surface: starting with `--sessions` advertises only
  `lisp_session_*` tools and treats `lisp_eval` as unknown.
  """

  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Test.ReleaseRunner

  @moduletag :integration
  @moduletag :release
  # Each release boot spins up a fresh BEAM VM in a child process —
  # leave plenty of headroom for cold-start.
  @moduletag timeout: 60_000
  @no_upstreams_env [
    {"PTC_RUNNER_MCP_UPSTREAMS", "/nonexistent/ptc_runner_mcp_release_stdio_test"},
    {"PTC_RUNNER_MCP_RESPONSE_PROFILE", "slim"}
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

  describe "stateless mode smoke" do
    test "initialize → tools/list advertises only lisp_eval in slim profile" do
      frames = [
        ReleaseRunner.init_request(1),
        ReleaseRunner.initialized_notif(),
        ReleaseRunner.tools_list_request(2),
        ReleaseRunner.exit_notif()
      ]

      assert {:ok, replies, status, _stderr} = run_stateless(frames)
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
      refute Map.has_key?(tool, "outputSchema")
      assert tool["annotations"]["readOnlyHint"] == true
      assert tool["annotations"]["idempotentHint"] == true
      assert tool["annotations"]["destructiveHint"] == false
      assert tool["annotations"]["openWorldHint"] == false
    end

    test "lisp_eval success returns slim text" do
      frames = [
        ReleaseRunner.init_request(1),
        ReleaseRunner.initialized_notif(),
        ReleaseRunner.tools_call_request(100, "lisp_eval", %{
          "program" => "(+ 1 2)"
        }),
        ReleaseRunner.exit_notif()
      ]

      assert {:ok, replies, 0, _stderr} = run_stateless(frames)
      reply = Enum.find(replies, &(&1["id"] == 100))
      assert reply, "no reply for id 100"

      result = reply["result"]
      assert result["isError"] == false
      assert [%{"type" => "text", "text" => "user=> 3"}] = result["content"]
      refute Map.has_key?(result, "structuredContent")
    end

    test "missing `program` argument returns slim args_error text" do
      frames = [
        ReleaseRunner.init_request(1),
        ReleaseRunner.initialized_notif(),
        ReleaseRunner.tools_call_request(300, "lisp_eval", %{}),
        ReleaseRunner.exit_notif()
      ]

      assert {:ok, replies, 0, _stderr} = run_stateless(frames)
      reply = Enum.find(replies, &(&1["id"] == 300))
      assert reply, "no reply for id 300; got #{inspect(replies)}"

      result = reply["result"]
      assert result["isError"] == true
      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert String.starts_with?(text, "args_error:")
      refute Map.has_key?(result, "structuredContent")
    end
  end

  describe "session mode smoke" do
    test "tools/list advertises session tools and disables stateless lisp_eval" do
      frames = [
        ReleaseRunner.init_request(1),
        ReleaseRunner.initialized_notif(),
        ReleaseRunner.tools_list_request(2),
        ReleaseRunner.exit_notif()
      ]

      assert {:ok, replies, 0, _stderr} =
               run_sessions(frames)

      list_reply = Enum.find(replies, &(&1["id"] == 2))
      names = Enum.map(list_reply["result"]["tools"], & &1["name"])

      refute "lisp_eval" in names
      assert "lisp_session_start" in names
      assert "lisp_session_list" in names
      assert "lisp_session_eval" in names
      assert "lisp_session_inspect" in names
      assert "lisp_session_forget" in names
      assert "lisp_session_close" in names
    end

    test "lisp_eval returns unknown_tool while lisp_session_start works" do
      frames = [
        ReleaseRunner.init_request(1),
        ReleaseRunner.initialized_notif(),
        ReleaseRunner.tools_call_request(10, "lisp_eval", %{"program" => "(+ 1 2)"}),
        ReleaseRunner.tools_call_request(11, "lisp_session_start", %{"title" => "smoke"}),
        ReleaseRunner.exit_notif()
      ]

      assert {:ok, replies, 0, _stderr} = run_sessions(frames)

      disabled_eval = Enum.find(replies, &(&1["id"] == 10))
      assert disabled_eval["result"]["isError"] == true
      assert disabled_eval["result"]["structuredContent"]["reason"] == "unknown_tool"

      start = Enum.find(replies, &(&1["id"] == 11))
      assert start["result"]["isError"] == false
      assert start["result"]["structuredContent"]["status"] == "ok"
      assert is_binary(start["result"]["structuredContent"]["session_id"])
    end
  end

  describe "handshake compatibility" do
    test "initialize with compatibility-floor 2025-06-18 negotiates to 2025-06-18" do
      init_request =
        Map.put(ReleaseRunner.init_request(1), "params", %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "phase6a-integration", "version" => "1"}
        })

      frames = [init_request, ReleaseRunner.exit_notif()]

      assert {:ok, [reply], 0, _stderr} = run_stateless(frames)
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

      assert {:ok, replies, 0, _stderr} = run_stateless(frames)

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

  describe "debug tool flag" do
    test "release start forwards app CLI flags through env.sh" do
      frames = [
        ReleaseRunner.init_request(1),
        ReleaseRunner.initialized_notif(),
        ReleaseRunner.tools_list_request(2),
        ReleaseRunner.exit_notif()
      ]

      assert {:ok, replies, 0, _stderr} =
               ReleaseRunner.run_session(frames,
                 args: ["start", "--debug-tool"],
                 env: @no_upstreams_env
               )

      list_reply = Enum.find(replies, &(&1["id"] == 2))
      tools = list_reply["result"]["tools"]
      names = Enum.map(tools, & &1["name"])

      assert "lisp_eval" in names
      assert "lisp_debug" in names
    end
  end

  describe "exit notification" do
    test "release subprocess terminates with status 0 on `exit`" do
      frames = [
        ReleaseRunner.init_request(1),
        ReleaseRunner.exit_notif()
      ]

      assert {:ok, _replies, 0, _stderr} = run_stateless(frames)
    end

    test "release subprocess terminates with status 0 on stdin EOF (§ 6.4 row 1)" do
      # No `exit` frame — the runner finishes writing its frames and
      # the OS pipe hits EOF; the server detects EOF and shuts down.
      frames = [ReleaseRunner.init_request(1)]
      assert {:ok, _replies, 0, _stderr} = run_stateless(frames)
    end
  end

  defp run_stateless(frames) do
    ReleaseRunner.run_session(frames, env: @no_upstreams_env)
  end

  defp run_sessions(frames) do
    ReleaseRunner.run_session(frames, args: ["start", "--sessions"], env: @no_upstreams_env)
  end
end
