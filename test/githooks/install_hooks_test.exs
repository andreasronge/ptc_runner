defmodule PtcRunner.GitHooks.InstallHooksTest do
  use ExUnit.Case, async: true

  alias PtcRunner.TestSupport.GitEnv

  @git_env GitEnv.clear()
  @repo_root Path.expand("../..", __DIR__)

  @tag :tmp_dir
  test "installs both hooks and registers the merge driver", %{tmp_dir: dir} do
    repo = init_repo(dir)

    {output, status} = install(repo)

    assert status == 0, output
    assert output =~ "merge driver registered"

    hooks = Path.join([repo, ".git", "hooks"])
    assert File.exists?(Path.join(hooks, "pre-commit"))
    assert File.exists?(Path.join(hooks, "pre-push"))

    assert git(repo, ["config", "--get", "merge.ptc-generated.driver"]) == "true"
  end

  @tag :tmp_dir
  test "fails loudly when core.hooksPath points somewhere unwritable", %{tmp_dir: dir} do
    repo = init_repo(dir)
    # What a clone that disables hooks looks like: Git resolves the hooks
    # directory to this path, which cannot hold hook files.
    {_, 0} = System.cmd("git", ["config", "core.hooksPath", "/dev/null"], cd: repo, env: @git_env)

    {output, status} = install(repo)

    refute status == 0, "expected a non-zero exit, got:\n#{output}"
    refute output =~ "Pre-commit hook installed", "reported success it did not achieve"
    refute output =~ "installed successfully"
    assert output =~ "core.hooksPath"
  end

  @tag :tmp_dir
  test "registers the merge driver even when hook installation fails", %{tmp_dir: dir} do
    repo = init_repo(dir)
    {_, 0} = System.cmd("git", ["config", "core.hooksPath", "/dev/null"], cd: repo, env: @git_env)

    {_output, _status} = install(repo)

    assert git(repo, ["config", "--get", "merge.ptc-generated.driver"]) == "true"
  end

  @tag :tmp_dir
  test "installed hooks use mise and a safe umask in non-interactive shells", %{tmp_dir: dir} do
    repo = init_repo(dir)
    bin = Path.join(dir, "bin")
    log = Path.join(dir, "hook.log")
    File.mkdir_p!(bin)

    write_executable!(
      Path.join(bin, "mise"),
      ~S"""
      #!/usr/bin/env bash
      printf 'mise|%s\n' "$*" >> "$PTC_HOOK_LOG"
      shift
      [ "${1:-}" = "--" ] && shift
      exec "$@"
      """
    )

    tracked_hook = Path.join([repo, ".githooks", "pre-commit"])

    write_executable!(
      tracked_hook,
      ~S"""
      #!/usr/bin/env bash
      printf 'hook|%s\n' "$(umask)" >> "$PTC_HOOK_LOG"
      """
    )

    {_, 0} = install(repo)

    {output, status} =
      System.cmd(Path.join([repo, ".git", "hooks", "pre-commit"]), [],
        cd: repo,
        env:
          GitEnv.clear(
            HOME: dir,
            PATH: bin <> ":/usr/bin:/bin",
            PTC_HOOK_LOG: log
          ),
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert log |> File.read!() |> String.split("\n", trim: true) == [
             "mise|exec -- #{tracked_hook}",
             "hook|0022"
           ]
  end

  defp init_repo(dir) do
    repo = Path.join(dir, "clone")
    File.mkdir_p!(Path.join(repo, "scripts"))
    {_, 0} = System.cmd("git", ["init", "-q", "."], cd: repo, env: @git_env)

    for script <-
          ~w(install-hooks.sh pre-commit.template pre-push hook-runtime.sh mise-runtime.sh) do
      File.cp!(Path.join([@repo_root, "scripts", script]), Path.join([repo, "scripts", script]))
    end

    repo
  end

  defp install(repo) do
    System.cmd("bash", ["scripts/install-hooks.sh"],
      cd: repo,
      env: @git_env,
      stderr_to_stdout: true
    )
  end

  defp git(repo, args) do
    {output, _status} = System.cmd("git", args, cd: repo, env: @git_env, stderr_to_stdout: true)
    String.trim(output)
  end

  defp write_executable!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end
end
