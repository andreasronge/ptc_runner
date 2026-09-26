defmodule PtcRunner.GitHooks.PrePublicationTest do
  use ExUnit.Case, async: true
  @moduletag :operator

  import PtcRunner.TestSupport.PrePushFixture

  alias PtcRunner.TestSupport.GitEnv

  test "detached checkout runs the hook gates for changes since the job base" do
    %{repo: repo, path: path, mix_marker: marker} = git_repo_with_change("lib/example.ex")
    prepare_snapshot(repo)

    {output, status} = run_gate(repo, path)

    assert status == 0, output
    assert output =~ "All pre-push checks passed"
    assert_core_gate_invocations(marker)
  end

  test "a failing test gate refuses publication" do
    %{repo: repo, path: path} = git_repo_with_change("lib/example.ex")
    prepare_snapshot(repo)

    {output, status} = run_gate(repo, path, [{"MIX_FAIL_GATE", "core-tests lane=library"}])

    assert status != 0
    assert output =~ "core tests (library lane) failed"
  end

  test "missing job base fails closed" do
    %{repo: repo, path: path} = git_repo_with_change("lib/example.ex")
    git!(repo, ["checkout", "--detach", "--quiet"])

    {output, status} = run_gate(repo, path)

    assert status != 0
    assert output =~ "origin/main"
  end

  defp prepare_snapshot(repo) do
    base = git!(repo, ["rev-parse", "HEAD^"])
    git!(repo, ["update-ref", "refs/remotes/origin/main", base])
    git!(repo, ["config", "core.hooksPath", "/dev/null"])
    git!(repo, ["checkout", "--detach", "--quiet"])
  end

  defp run_gate(repo, path, extra_env \\ []) do
    System.cmd(Path.join(repo, "scripts/ci/pre-publication"), [],
      cd: repo,
      env:
        GitEnv.clear() ++
          [
            {"PATH", path},
            {"MIX_MARKER", Path.join(Path.dirname(hd(String.split(path, ":"))), "mix-called")},
            {"PTC_MANAGED_OPERATION_CONTEXT", nil},
            {"PTC_OPERATION_ACTIVE", nil},
            {"FORCE_FULL_PRE_PUSH", nil}
          ] ++ extra_env,
      stderr_to_stdout: true
    )
  end
end
