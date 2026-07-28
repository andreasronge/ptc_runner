defmodule PtcRunner.GitHooks.PrePushTest do
  use ExUnit.Case, async: true

  @hook Path.expand("../../.githooks/pre-push", __DIR__)
  @git_env ~w(
    GIT_ALTERNATE_OBJECT_DIRECTORIES
    GIT_CONFIG
    GIT_CONFIG_PARAMETERS
    GIT_CONFIG_COUNT
    GIT_OBJECT_DIRECTORY
    GIT_DIR
    GIT_WORK_TREE
    GIT_IMPLICIT_WORK_TREE
    GIT_GRAFT_FILE
    GIT_INDEX_FILE
    GIT_NO_REPLACE_OBJECTS
    GIT_REPLACE_REF_BASE
    GIT_PREFIX
    GIT_SHALLOW_FILE
    GIT_COMMON_DIR
  )
           |> Enum.map(&{&1, nil})

  test "planning-only changes skip the full gate" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("docs/plans/kernel-notes.md")

    {output, status} = run_hook(repo, path)

    assert status == 0
    assert output =~ "Docs-only push, skipping full pre-push gate"
    refute File.exists?(mix_marker)
  end

  @tag :slow
  test "full gate runs tests and the canonical prepush alias once" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("lib/example.ex")

    {output, status} = run_hook(repo, path)

    assert status == 0
    assert output =~ ~r/Tests passed in \d+s/
    assert output =~ ~r/Pre-push checks passed in \d+s/

    assert mix_marker |> File.read!() |> String.split("\n", trim: true) ==
             ["test --exclude clojure", "prepush"]
  end

  defp git_repo_with_change(changed_path) do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-pre-push-#{System.unique_integer([:positive, :monotonic])}"
      )

    repo = Path.join(root, "repo")
    bin = Path.join(root, "bin")
    mix_marker = Path.join(root, "mix-called")
    File.mkdir_p!(repo)
    File.mkdir_p!(bin)

    on_exit(fn -> File.rm_rf!(root) end)

    fake_mix = Path.join(bin, "mix")

    File.write!(fake_mix, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$MIX_MARKER\"\nexit 0\n")
    File.chmod!(fake_mix, 0o755)

    git!(repo, ["init", "--quiet"])
    git!(repo, ["config", "user.email", "pre-push@example.test"])
    git!(repo, ["config", "user.name", "Pre-push Test"])

    File.write!(Path.join(repo, "mix.exs"), "{:dialyxir, \"~> 1.4\"}\n")
    write_changed_file!(repo, changed_path, "before\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--quiet", "-m", "base"])
    write_changed_file!(repo, changed_path, "after\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--quiet", "-m", "change"])

    %{repo: repo, path: bin <> ":" <> System.fetch_env!("PATH"), mix_marker: mix_marker}
  end

  defp run_hook(repo, path) do
    base = git!(repo, ["rev-parse", "HEAD^"])
    head = git!(repo, ["rev-parse", "HEAD"])
    refs = "refs/heads/test #{head} refs/heads/test #{base}\n"

    System.cmd(
      "bash",
      ["-c", "printf '%s' \"$HOOK_REFS\" | \"$HOOK_PATH\""],
      cd: repo,
      env:
        @git_env ++
          [
            {"HOOK_PATH", @hook},
            {"HOOK_REFS", refs},
            {"MIX_MARKER",
             Path.join(path |> String.split(":") |> hd() |> Path.dirname(), "mix-called")},
            {"PATH", path}
          ],
      stderr_to_stdout: true
    )
  end

  defp write_changed_file!(repo, path, contents) do
    full_path = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, contents)
  end

  defp git!(repo, args) do
    {output, 0} =
      System.cmd("git", args, cd: repo, env: @git_env, stderr_to_stdout: true)

    String.trim(output)
  end
end
