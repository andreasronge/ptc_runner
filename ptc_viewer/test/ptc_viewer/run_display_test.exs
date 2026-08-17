defmodule PtcViewer.RunDisplayTest do
  use ExUnit.Case, async: true

  test "run names and usage totals have stable user-facing projections" do
    script = Path.expand("../run_display.mjs", __DIR__)
    assert {"ok", 0} = System.cmd("node", [script], stderr_to_stdout: true)
  end
end
