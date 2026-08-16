defmodule PtcRunner.Scripts.ClassifyChangesTest do
  use ExUnit.Case, async: true

  @classifier Path.expand("../../scripts/ci/classify-changes.sh", __DIR__)

  test "routes independently testable repository areas" do
    assert classify(["docs/plans/future/note.md"]) == all_false()

    assert classify(["docs/guides/replay.md"]) ==
             all_false() |> Map.put("docs", "true")

    for generated_reference <- [
          "docs/kernel-limits-reference.md",
          "docs/prelude-reference.md"
        ] do
      assert classify([generated_reference]) ==
               all_false()
               |> Map.put("core", "true")
               |> Map.put("docs", "true")
    end

    assert classify(["docs/guides/quickstart.md"]) ==
             all_false()
             |> Map.put("core", "true")
             |> Map.put("docs", "true")

    assert classify(["ptc_runner_launcher/c_src/launcher.c"]) ==
             all_false() |> Map.put("launcher", "true")

    # The Viewer ships in the standalone release, so its own gate is not the
    # only one a change to it can break.
    assert classify(["ptc_viewer/lib/ptc_viewer.ex"]) ==
             all_false()
             |> Map.put("core", "true")
             |> Map.put("viewer", "true")

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

  test "non-canonical executable-guide entries conservatively select every scope" do
    for entry <- ["  docs/guides/quickstart.md  ", "./docs/guides/quickstart.md"] do
      assert classify(["docs/guides/quickstart.md"], registry: entry <> "\n") ==
               Map.new(all_false(), fn {scope, _value} -> {scope, "true"} end)
    end
  end

  defp classify(paths, opts \\ []) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ptc-changed-paths-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.write!(path, Enum.join(paths, "\n") <> "\n")
    on_exit(fn -> File.rm(path) end)

    env =
      case opts[:registry] do
        nil ->
          []

        contents ->
          registry = path <> "-registry"
          File.write!(registry, contents)
          on_exit(fn -> File.rm(registry) end)
          [{"PTC_EXECUTABLE_GUIDES_FILE", registry}]
      end

    {output, 0} = System.cmd(@classifier, [path], env: env, stderr_to_stdout: true)

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
