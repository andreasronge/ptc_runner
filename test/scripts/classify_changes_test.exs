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
          {"test/ptc_runner/kernel/filesystem_mcp_e2e_test.exs", only(["mcp_filesystem"])},
          {"test/support/ptc_fs_mcp.ex", only(["mcp_filesystem"])},
          {"examples/named-mission-reader-writer/ptc-host.json",
           all_false() |> Map.put("core", "true") |> Map.put("mcp_filesystem", "true")},
          {".claude/skills/precommit/SKILL.md", all_false()},
          {".github/workflows/nightly.yml", all_false()},
          {".github/workflows/soak.yml", all_false()},
          {".github/workflows/e2e.yml", all_false()},
          {".github/workflows/pages.yml", all_false()},
          {".github/dependabot.yml", all_false()},
          {".github/workflows/launcher-release.yml", only(["launcher"])},
          {".github/workflows/release.yml", core},
          {"scripts/ci/docs.sh", docs},
          {"scripts/build_site.sh", docs},
          {"scripts/ci/launcher.sh", only(["launcher"])},
          {"scripts/ci/core-release.sh", core},
          {"scripts/ci/viewer.sh",
           all_false() |> Map.put("core", "true") |> Map.put("viewer", "true")},
          {"scripts/verify_standalone_release.sh", core},
          {"scripts/worktree.sh", core},
          {".githooks/README.md", docs},
          {".githooks/pre-push", core},
          {".formatter.exs", core},
          {".github/workflows/test.yml", every_scope},
          {"scripts/ci/classify-changes.sh", every_scope},
          {"scripts/ci/_common.sh", every_scope},
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
