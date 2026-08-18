defmodule PtcRunner.GitHooks.PreCommitTest do
  use ExUnit.Case, async: true

  alias PtcRunner.TestSupport.GitEnv

  @hook Path.expand("../../.githooks/pre-commit", __DIR__)
  @git_env GitEnv.clear()

  test "passes staged Elixir files to format and credo, not the whole tree" do
    %{repo: repo, path: path, mix_marker: mix_marker} =
      git_repo_with_staged(["lib/example.ex"])

    {output, status} = run_hook(repo, path)

    assert status == 0, output

    assert File.read!(mix_marker) == """
           cwd=repo
           arg=do
           arg=format
           arg=--check-formatted
           arg=lib/example.ex
           arg=+
           arg=compile
           arg=--warnings-as-errors
           arg=+
           arg=credo
           arg=--strict
           arg=lib/example.ex
           ---
           """
  end

  test "passes every staged Elixir file and leaves compile unscoped" do
    %{repo: repo, path: path, mix_marker: mix_marker} =
      git_repo_with_staged(["lib/b.ex", "lib/a.ex", "test/a_test.exs"])

    {output, status} = run_hook(repo, path)

    assert status == 0, output

    assert File.read!(mix_marker) == """
           cwd=repo
           arg=do
           arg=format
           arg=--check-formatted
           arg=lib/a.ex
           arg=lib/b.ex
           arg=test/a_test.exs
           arg=+
           arg=compile
           arg=--warnings-as-errors
           arg=+
           arg=credo
           arg=--strict
           arg=lib/a.ex
           arg=lib/b.ex
           arg=test/a_test.exs
           ---
           cwd=repo
           arg=test
           arg=test/a_test.exs
           arg=--exclude
           arg=clojure
           arg=--exclude
           arg=slow
           ---
           """
  end

  test "keeps a whitespace Elixir path as one Mix argument" do
    %{repo: repo, path: path, mix_marker: mix_marker} =
      git_repo_with_staged(["lib/my module.ex", "test/my module_test.exs"])

    {output, status} = run_hook(repo, path)

    assert status == 0, output

    assert File.read!(mix_marker) == """
           cwd=repo
           arg=do
           arg=format
           arg=--check-formatted
           arg=lib/my module.ex
           arg=test/my module_test.exs
           arg=+
           arg=compile
           arg=--warnings-as-errors
           arg=+
           arg=credo
           arg=--strict
           arg=lib/my module.ex
           arg=test/my module_test.exs
           ---
           cwd=repo
           arg=test
           arg=test/my module_test.exs
           arg=--exclude
           arg=clojure
           arg=--exclude
           arg=slow
           ---
           """
  end

  test "rewrites Viewer paths relative to ptc_viewer/ and skips credo there" do
    %{repo: repo, path: path, mix_marker: mix_marker} =
      git_repo_with_staged(["ptc_viewer/lib/ptc_viewer.ex"], viewer?: true)

    {output, status} = run_hook(repo, path)

    assert status == 0, output
    assert output =~ "Project: ptc_viewer/"
    refute output =~ "Project: root"

    assert File.read!(mix_marker) == """
           cwd=ptc_viewer
           arg=do
           arg=format
           arg=--check-formatted
           arg=lib/ptc_viewer.ex
           arg=+
           arg=compile
           arg=--warnings-as-errors
           ---
           """
  end

  test "skips Mix when the index has no Elixir, config, or mix files" do
    %{repo: repo, path: path, mix_marker: mix_marker} =
      git_repo_with_staged(["docs/guides/replay.md"])

    {output, status} = run_hook(repo, path)

    assert status == 0, output
    refute File.exists?(mix_marker)
  end

  test "compiles mix.lock changes without format or credo" do
    %{repo: repo, path: path, mix_marker: mix_marker} =
      git_repo_with_staged(["mix.lock"])

    {output, status} = run_hook(repo, path)

    assert status == 0, output

    assert File.read!(mix_marker) == """
           cwd=repo
           arg=do
           arg=compile
           arg=--warnings-as-errors
           ---
           """
  end

  defp git_repo_with_staged(paths, opts \\ []) do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-pre-commit-#{System.unique_integer([:positive, :monotonic])}"
      )

    repo = Path.join(root, "repo")
    bin = Path.join(root, "bin")
    mix_marker = Path.join(root, "mix-called")
    File.mkdir_p!(repo)
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(Path.join(repo, ".githooks"))
    File.cp!(@hook, Path.join(repo, ".githooks/pre-commit"))
    File.chmod!(Path.join(repo, ".githooks/pre-commit"), 0o755)

    fake_mix = Path.join(bin, "mix")

    File.write!(fake_mix, """
    #!/bin/sh
    {
      printf 'cwd=%s\\n' "$(basename "$PWD")"
      for arg in "$@"; do
        printf 'arg=%s\\n' "$arg"
      done
      printf -- '---\\n'
    } >> "$MIX_MARKER"
    exit 0
    """)

    File.chmod!(fake_mix, 0o755)

    git!(repo, ["init", "--quiet"])
    git!(repo, ["config", "user.email", "pre-commit@example.test"])
    git!(repo, ["config", "user.name", "Pre-commit Test"])

    File.write!(Path.join(repo, "mix.exs"), "{:credo, \"~> 1.7\"}\n")
    File.write!(Path.join(repo, "mix.lock"), "%{}\n")

    if opts[:viewer?] do
      File.mkdir_p!(Path.join(repo, "ptc_viewer"))

      File.write!(
        Path.join(repo, "ptc_viewer/mix.exs"),
        "defmodule PtcViewer.MixProject do\nend\n"
      )
    end

    git!(repo, ["add", "."])
    git!(repo, ["commit", "--quiet", "-m", "base"])

    Enum.each(paths, fn path ->
      full_path = Path.join(repo, path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, "staged\n")
    end)

    git!(repo, ["add", "--"] ++ paths)

    %{
      repo: repo,
      path: bin <> ":" <> System.fetch_env!("PATH"),
      mix_marker: mix_marker
    }
  end

  defp run_hook(repo, path) do
    System.cmd("bash", [Path.join(repo, ".githooks/pre-commit")],
      cd: repo,
      env: @git_env ++ [{"MIX_MARKER", mix_marker_from_path(path)}, {"PATH", path}],
      stderr_to_stdout: true
    )
  end

  defp mix_marker_from_path(path) do
    path |> String.split(":") |> hd() |> Path.dirname() |> Path.join("mix-called")
  end

  defp git!(repo, args) do
    {output, 0} =
      System.cmd("git", args, cd: repo, env: @git_env, stderr_to_stdout: true)

    String.trim(output)
  end
end
