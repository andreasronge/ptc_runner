defmodule PtcRunner.Scripts.DocHistoryGateTest do
  use ExUnit.Case, async: true
  @moduletag :operator

  alias PtcRunner.TestSupport.GitEnv

  @gate Path.expand("../../scripts/doc_history_gate.sh", __DIR__)

  setup do
    repo =
      Path.join(
        System.tmp_dir!(),
        "ptc-doc-history-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(repo) end)
    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: repo, env: GitEnv.clear())
    {:ok, repo: repo}
  end

  test "a page without references passes", %{repo: repo} do
    write(repo, "docs/guide.md", "Plain current behavior. Item #12 and ## Heading.\n")

    assert {output, 0} = run(repo, "check")
    assert output =~ "no new issue or pull-request references"
  end

  test "a new reference fails and names the page and line", %{repo: repo} do
    write(repo, "docs/maintainers/probe.md", "ok\nreplaces the old path (#2025)\n")

    assert {output, 1} = run(repo, "check")
    assert output =~ "docs/maintainers/probe.md has 1 lines with issue or pull-request references"
    assert output =~ "2:replaces the old path (#2025)"
  end

  test "issue and pull-request URLs count", %{repo: repo} do
    write(
      repo,
      "README.md",
      "see https://github.com/o/r/issues/42\nand https://github.com/o/r/pull/7\n"
    )

    assert {output, 1} = run(repo, "check")
    assert output =~ "README.md has 2"
  end

  test "a blessed reference passes but a second one on the page fails", %{repo: repo} do
    write(repo, "docs/old.md", "history (#1643)\n")
    assert {_, 0} = run(repo, "bless")
    assert {_, 0} = run(repo, "check")

    write(repo, "docs/old.md", "history (#1643)\nand again (#1987)\n")
    assert {output, 1} = run(repo, "check")
    assert output =~ "docs/old.md has 2 lines with issue or pull-request references, baseline 1"
  end

  test "plans, research and generated pages are out of scope", %{repo: repo} do
    for path <-
          ~w(docs/plans/x.md docs/research/r.md docs/conformance/c.md docs/function-reference.md) do
      write(repo, path, "tracked in #1234\n")
    end

    assert {_, 0} = run(repo, "check")
  end

  defp write(repo, path, content) do
    full = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
    {_, 0} = System.cmd("git", ["add", path], cd: repo, env: GitEnv.clear())
  end

  defp run(repo, mode) do
    System.cmd(@gate, [mode],
      cd: repo,
      env: GitEnv.clear(),
      stderr_to_stdout: true
    )
  end
end
