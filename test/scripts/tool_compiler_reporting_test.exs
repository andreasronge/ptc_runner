defmodule PtcRunner.Scripts.ToolCompilerReportingTest do
  use ExUnit.Case, async: true

  @moduletag :operator

  alias PtcRunner.TestSupport.TestHelpers

  if reason = TestHelpers.executable_skip_reason(["node"]) do
    @moduletag skip: reason
  end

  test "tool compiler totals preserve incomplete spend accounting" do
    {output, status} =
      System.cmd(
        System.find_executable("node"),
        ["--test", "scripts/labs/tool-compiler/reporting.test.mjs"],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
