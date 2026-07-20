defmodule PtcViewer.ReplUiTest do
  use ExUnit.Case, async: true

  test "browser state ordering, page config, and run ID handoff stay fail closed" do
    script = Path.expand("../repl_ui.mjs", __DIR__)
    assert {"ok", 0} = System.cmd("node", [script], stderr_to_stdout: true)
  end

  test "entry document exposes accessible REPL controls without inline script" do
    html = Path.expand("../../priv/static/index.html", __DIR__) |> File.read!()

    assert html =~ ~s(role="tablist")
    assert html =~ ~s(role="status" aria-live="polite")
    assert html =~ ~s(<textarea id="repl-editor")
    assert html =~ ~s(<dialog id="repl-reset-dialog")
    refute html =~ "<script>"
  end
end
