defmodule PtcRunner.Scripts.ClassifyChangesTest do
  use ExUnit.Case, async: true

  @classifier Path.expand("../../scripts/classify_changes.sh", __DIR__)

  test "routes independently testable repository areas" do
    assert classify(["docs/plans/future/note.md"]) == all_false()

    assert classify(["docs/guides/replay.md"]) ==
             all_false() |> Map.put("docs", "true")

    assert classify(["ptc_runner_launcher/c_src/launcher.c"]) ==
             all_false() |> Map.put("launcher", "true")

    assert classify(["ptc_viewer/lib/ptc_viewer.ex"]) ==
             all_false() |> Map.put("viewer", "true")

    assert classify(["lib/ptc_runner/lisp/eval.ex"]) ==
             all_false()
             |> Map.put("core", "true")
             |> Map.put("java", "true")
             |> Map.put("mcp_filesystem", "true")

    assert classify(["lib/ptc_runner/kernel/mcp_source.ex"]) ==
             all_false()
             |> Map.put("core", "true")
             |> Map.put("mcp_http", "true")
             |> Map.put("mcp_filesystem", "true")
  end

  test "unknown paths conservatively select every scope" do
    assert classify(["new-area/contract.data"]) ==
             Map.new(all_false(), fn {scope, _value} -> {scope, "true"} end)
  end

  defp classify(paths) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ptc-changed-paths-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.write!(path, Enum.join(paths, "\n") <> "\n")
    on_exit(fn -> File.rm(path) end)

    {output, 0} = System.cmd(@classifier, [path], stderr_to_stdout: true)

    output
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [scope, value] = String.split(line, "=", parts: 2)
      {scope, value}
    end)
  end

  defp all_false do
    Map.new(
      ~w(core launcher mcp_http mcp_filesystem java viewer docs),
      &{&1, "false"}
    )
  end
end
