defmodule PtcRunnerMcp.TelemetryProfileTest do
  @moduledoc """
  Phase 0 acceptance test for §11.5 / §12.1: telemetry on
  `[:ptc_runner, :lisp, :execute, :start | :stop]` carries
  `caller: :mcp` AND `profile: :mcp_no_tools` when an MCP `tools/call`
  request is processed end-to-end via `Tools.call_validated/3` (the
  request-handler decoration point per §11.3).

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §11.5, §12.1.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Tools

  @events [
    [:ptc_runner, :lisp, :execute, :start],
    [:ptc_runner, :lisp, :execute, :stop]
  ]

  setup do
    test_pid = self()
    handler_id = "phase0-profile-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      @events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "MCP request handler emits caller: :mcp and profile: :mcp_no_tools" do
    env = Tools.call_validated("(+ 1 2)", %{}, nil)
    assert env["isError"] == false

    assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :start], _,
                    %{caller: :mcp, profile: :mcp_no_tools}}

    assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :stop], _,
                    %{caller: :mcp, profile: :mcp_no_tools}}
  end
end
