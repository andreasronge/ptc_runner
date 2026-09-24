defmodule PtcRunner.Scripts.ToolCompilerReportingTest do
  use ExUnit.Case, async: true

  @moduletag :operator

  test "tool compiler totals preserve incomplete spend accounting" do
    node =
      System.find_executable("node") || flunk("Node.js is required for the tool compiler lab")

    {output, status} =
      System.cmd(
        node,
        ["--test", "scripts/labs/tool-compiler/reporting.test.mjs"],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
