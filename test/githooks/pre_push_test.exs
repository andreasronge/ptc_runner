defmodule PtcRunner.GitHooks.PrePushTest do
  use ExUnit.Case, async: true

  alias PtcRunner.TestSupport.GitEnv

  @hook Path.expand("../../.githooks/pre-push", __DIR__)
  @git_env GitEnv.clear()

  test "planning-only changes skip the full gate" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("docs/plans/kernel-notes.md")

    {output, status} = run_hook(repo, path)

    assert status == 0
    assert output =~ "Plan-only push, skipping full pre-push gate"
    refute File.exists?(mix_marker)
  end

  test "guide-only changes run only the documentation gate" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("docs/guides/replay.md")

    {output, status} = run_hook(repo, path)

    assert status == 0
    assert output =~ "Documentation-only push, running the ExDoc warnings gate"

    assert mix_marker |> File.read!() |> String.split("\n", trim: true) ==
             ["deps.get --check-locked", "docs --warnings-as-errors"]
  end

  test "launcher-only changes run the launcher gate" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("ptc_runner_launcher/c_src/launcher.c")

    {output, status} = run_hook(repo, path)

    assert status == 0
    assert output =~ "Launcher checks passed"

    assert mix_marker |> File.read!() |> String.split("\n", trim: true) ==
             ["precommit"]
  end

  test "launcher gate receives an explicit test concurrency limit" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("ptc_runner_launcher/c_src/launcher.c")

    {output, status} = run_hook(repo, path, [{"PTC_PRE_PUSH_MAX_CASES", "2"}])

    assert status == 0
    assert output =~ "Test concurrency: 2 cases"

    assert mix_marker |> File.read!() |> String.split("\n", trim: true) ==
             ["precommit --max-cases 2"]
  end

  test "Viewer-only changes do not run the root gate" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("ptc_viewer/lib/ptc_viewer.ex")

    {output, status} = run_hook(repo, path)

    assert status == 0
    assert output =~ "Project: ptc_viewer/"
    refute output =~ "Project: root"

    assert mix_marker |> File.read!() |> String.split("\n", trim: true) ==
             ["test --exclude clojure"]
  end

  @tag :slow
  test "full gate runs tests and the canonical prepush alias once" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("lib/example.ex")

    {output, status} = run_hook(repo, path)

    assert status == 0
    assert output =~ ~r/Tests passed in \d+s/
    assert output =~ ~r/Pre-push checks passed in \d+s/

    assert output =~ "Phase timings:"
    assert output =~ ~r/root \(:ptc_runner\) tests\s+\d+s/
    assert output =~ ~r/root mix prepush \(incl\. dialyzer\)\s+\d+s/

    assert mix_marker |> File.read!() |> String.split("\n", trim: true) ==
             ["test --exclude clojure", "prepush"]
  end

  @tag :slow
  test "mixed documentation and core changes validate documentation first" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_changes(["docs/guides/replay.md", "lib/example.ex"])

    {output, status} = run_hook(repo, path)

    assert status == 0
    assert output =~ "Documentation"
    assert output =~ "Project: root"

    assert mix_marker |> File.read!() |> String.split("\n", trim: true) ==
             [
               "deps.get --check-locked",
               "docs --warnings-as-errors",
               "test --exclude clojure",
               "prepush"
             ]
  end

  @tag :slow
  test "full gate accepts an explicit test concurrency limit" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("lib/example.ex")

    {output, status} = run_hook(repo, path, [{"PTC_PRE_PUSH_MAX_CASES", "2"}])

    assert status == 0
    assert output =~ "Test concurrency: 2 cases"

    assert mix_marker |> File.read!() |> String.split("\n", trim: true) ==
             ["test --exclude clojure --max-cases 2", "prepush"]
  end

  test "full gate rejects an invalid test concurrency limit" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("lib/example.ex")

    {output, status} = run_hook(repo, path, [{"PTC_PRE_PUSH_MAX_CASES", "many"}])

    assert status != 0
    assert output =~ "PTC_PRE_PUSH_MAX_CASES must be a positive integer"
    refute File.exists?(mix_marker)
  end

  test "documentation routing rejects an invalid test concurrency limit" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("docs/guides/replay.md")

    {output, status} = run_hook(repo, path, [{"PTC_PRE_PUSH_MAX_CASES", "many"}])

    assert status != 0
    assert output =~ "PTC_PRE_PUSH_MAX_CASES must be a positive integer"
    refute File.exists?(mix_marker)
  end

  test "documentation dependency setup rejects an uncommitted lockfile repair" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("docs/guides/replay.md")

    {output, status} = run_hook(repo, path, [{"MIX_MUTATE_LOCK", "1"}])

    assert status != 0
    assert output =~ "Documentation dependency setup failed"
    refute File.exists?(Path.join(repo, "mix.lock"))

    assert mix_marker |> File.read!() |> String.split("\n", trim: true) ==
             ["deps.get --check-locked"]
  end

  defp git_repo_with_change(changed_path) do
    git_repo_with_changes([changed_path])
  end

  defp git_repo_with_changes(changed_paths) do
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

    File.write!(fake_mix, """
    #!/bin/sh
    printf '%s\n' "$*" >> "$MIX_MARKER"
    if [ "${MIX_MUTATE_LOCK:-}" = "1" ] && [ "$*" = "deps.get --check-locked" ]; then
      exit 1
    fi
    exit 0
    """)

    File.chmod!(fake_mix, 0o755)

    git!(repo, ["init", "--quiet"])
    git!(repo, ["config", "user.email", "pre-push@example.test"])
    git!(repo, ["config", "user.name", "Pre-push Test"])

    File.write!(Path.join(repo, "mix.exs"), "{:dialyxir, \"~> 1.4\"}\n")
    Enum.each(changed_paths, &write_changed_file!(repo, &1, "before\n"))
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--quiet", "-m", "base"])
    Enum.each(changed_paths, &write_changed_file!(repo, &1, "after\n"))
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--quiet", "-m", "change"])

    %{repo: repo, path: bin <> ":" <> System.fetch_env!("PATH"), mix_marker: mix_marker}
  end

  defp run_hook(repo, path, extra_env \\ []) do
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
            {"PTC_PRE_PUSH_MAX_CASES", nil},
            {"PATH", path}
          ] ++ extra_env,
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
