defmodule PtcRunnerMcp.McpStdioSoakTest do
  @moduledoc """
  Soak test: drive the built `ptc_runner_mcp` Mix release as a real OS
  subprocess over stdio, exercising the production-shape transport
  (NDJSON-framed JSON-RPC over real POSIX pipes) with many stateless
  `lisp_eval` calls.

  This is the only soak test that can catch leaks living in the
  framing / stdio plumbing itself (the BEAM-internal soaks all drive
  `Tools.call/1` directly, bypassing JSON-RPC entirely).

  Session start/eval/close churn is covered by
  `session_churn_soak_test.exs`. This release driver writes all frames
  up front through `ReleaseRunner`, so it cannot substitute dynamic
  session IDs returned by `lisp_session_start`.

  ## Skips cleanly when

  * The release binary doesn't exist (run
    `MIX_ENV=prod mix release --overwrite` first).

  ## What's asserted

    1. Subprocess exits cleanly after the `exit` frame.
    2. Every iteration's `lisp_eval` reply was `status: "ok"`.

  ## What's logged

    * Total iterations + wall time, so cost-per-iteration is visible.

  ## Run

      MIX_ENV=prod mix release --overwrite
      MIX_ENV=test mix test --only soak \\
        test/soak/mcp_stdio_soak_test.exs --color

      PTC_SOAK_ITERATIONS=10000 \\
        MIX_ENV=test mix test --only soak \\
        test/soak/mcp_stdio_soak_test.exs
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Test.ReleaseRunner

  @moduletag :soak
  @moduletag timeout: :infinity

  @release_skip_reason "release binary missing - run `MIX_ENV=prod mix release --overwrite` first " <>
                         "(expected at #{ReleaseRunner.release_bin()})"

  if ReleaseRunner.release_built?() do
    alias PtcRunnerMcp.TestSupport.MemorySoak

    test "stdio stateless eval loop returns ok for every request" do
      run_stdio_soak()
    end

    defp run_stdio_soak do
      iters = MemorySoak.iteration_count()

      # Build the wire script: init -> N stateless eval calls -> exit.
      {frames, total_requests} = build_frames(iters)

      started_at = System.monotonic_time(:millisecond)

      {:ok, replies, status, stderr} =
        ReleaseRunner.run_session(frames,
          timeout_ms: max(iters * 50, 60_000),
          env: [
            # Disable any noisy telemetry sinks the soak doesn't care about.
            {"PTC_RUNNER_MCP_LOG_LEVEL", "error"}
          ]
        )

      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      assert status in [0, :normal], """
      Release exited abnormally: status=#{inspect(status)}
      stderr (last 2 KB):
      #{String.slice(stderr, max(byte_size(stderr) - 2048, 0), 2048)}
      """

      # Every `lisp_eval` reply should be `status: "ok"`. We grep
      # `structuredContent.status` on the bodies — only call-result frames
      # have it.
      bad =
        replies
        |> Enum.filter(&match?(%{"result" => %{"structuredContent" => _}}, &1))
        |> Enum.reject(fn frame ->
          get_in(frame, ["result", "structuredContent", "status"]) == "ok"
        end)

      assert bad == [],
             "#{length(bad)} eval call(s) returned non-OK status. " <>
               "First failure:\n#{inspect(Enum.at(bad, 0), pretty: true, limit: :infinity)}"

      IO.puts("""
      Stdio soak:
        iterations:  #{iters}
        requests:    #{total_requests}
        elapsed_ms:  #{elapsed_ms}
        replies:     #{length(replies)}
        per-iter ms: #{Float.round(elapsed_ms / max(iters, 1), 2)}
      """)
    end

    # ---------------------------------------------------------------------
    # Frame construction
    # ---------------------------------------------------------------------

    defp build_frames(iters) do
      eval_frames =
        Enum.map(1..iters, fn i ->
          ReleaseRunner.tools_call_request(i + 1, "lisp_eval", %{
            "program" => "(+ 1 2 3)"
          })
        end)

      frames = [ReleaseRunner.init_request(1), ReleaseRunner.initialized_notif() | eval_frames]
      {frames ++ [ReleaseRunner.exit_notif()], iters + 1}
    end
  else
    @tag skip: @release_skip_reason
    test "stdio stateless eval loop returns ok for every request"
  end
end
