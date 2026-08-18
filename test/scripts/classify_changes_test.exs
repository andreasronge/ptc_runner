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
             |> Map.put("docs", "true")

    assert classify(["docs/maintainers/development-setup.md"]) ==
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

  test "known standing paths do not fall through to every scope" do
    docs = only(["docs"])
    core = only(["core"])
    every_scope = only(~w(core launcher mcp_http mcp_filesystem java viewer docs))

    for {path, expected} <- [
          {"AGENTS.md", docs},
          {"CLAUDE.md", docs},
          {"usage-rules.md", docs},
          {".env.example", docs},
          {".lycheeignore", docs},
          {".gitattributes", docs},
          {"cliff.toml", docs},
          {"REUSE.toml", docs},
          {"site/index.html", docs},
          {"dev/mix/tasks/ptc.verify_docs.ex", docs},
          {".duplication-baseline.json", core},
          {".ex_dna.exs", core},
          {"conformance_inventory.json", core},
          {"bench/lisp_throughput.exs", core},
          {"Dockerfile", core},
          {".dockerignore", core},
          {"rel/overlays/bin/ptc", core},
          {"examples/kernel-tutorial/03-file-agent/agent.clj", core},
          {"examples/mcp/filesystem/src/index.ts", only(["mcp_filesystem"])},
          {".claude/skills/precommit/SKILL.md", all_false()},
          {"mise.toml", every_scope}
        ] do
      assert classify([path]) == expected, path
    end
  end

  test "unknown paths conservatively select every scope" do
    assert classify(["new-area/contract.data"]) ==
             only(~w(core launcher mcp_http mcp_filesystem java viewer docs))
  end

  test "non-canonical executable-guide entries conservatively select every scope" do
    for entry <- [
          "  docs/maintainers/development-setup.md  ",
          "./docs/maintainers/development-setup.md"
        ] do
      assert classify(["docs/maintainers/development-setup.md"], registry: entry <> "\n") ==
               only(~w(core launcher mcp_http mcp_filesystem java viewer docs))
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

  defp only(scopes) do
    Enum.reduce(scopes, all_false(), &Map.put(&2, &1, "true"))
  end

  defp all_false do
    Map.new(
      ~w(core launcher mcp_http mcp_filesystem java viewer docs),
      &{&1, "false"}
    )
  end
end
