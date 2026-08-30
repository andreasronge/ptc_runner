defmodule PtcViewer.LiveUiTest do
  use ExUnit.Case, async: true

  test "live panel projections format limits and de-duplicate components" do
    script = Path.expand("../live_ui.mjs", __DIR__)
    assert {"ok", 0} = System.cmd("node", [script], stderr_to_stdout: true)
  end

  test "entry document carries the live run lifecycle and project controls" do
    html = Path.expand("../../priv/static/index.html", __DIR__) |> File.read!()

    assert html =~ ~s(<div id="live-project")
    assert html =~ ~s(<button id="live-clear-ended")
    refute html =~ "<script>"
  end
end
