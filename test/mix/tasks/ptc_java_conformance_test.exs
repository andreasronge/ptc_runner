defmodule Mix.Tasks.Ptc.JavaConformanceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "PTC oracle defaults to the closed-dispatch subset" do
    Mix.Task.reenable("ptc.java_conformance")

    output = capture_io(fn -> Mix.Task.run("ptc.java_conformance", ["--oracle", "ptc"]) end)

    assert output =~ "ptc Java interop case(s) in closed_dispatch"
  end

  test "removed PTC-only subset is rejected as an unknown option" do
    Mix.Task.reenable("ptc.java_conformance")

    assert_raise Mix.Error, ~r/Unknown Java conformance subset "ptc-only"/, fn ->
      Mix.Task.run("ptc.java_conformance", ["--oracle", "ptc", "--subset", "ptc-only"])
    end
  end
end
