defmodule PtcRunner.GitHooks.PrePublicationTest do
  use ExUnit.Case, async: true
  @moduletag :operator

  import PtcRunner.TestSupport.PrePushFixture

  alias PtcRunner.TestSupport.GitEnv

  test "detached checkout runs the hook gates for changes since the job base" do
    %{repo: repo, path: path, mix_marker: marker} = git_repo_with_change("lib/example.ex")
    snapshot = prepare_snapshot(repo)

    {output, status} = run_gate(snapshot, path)

    assert status == 0, output
    assert output =~ "All pre-push checks passed"
    assert_core_gate_invocations(marker)
  end

  test "a failing test gate refuses publication" do
    %{repo: repo, path: path} = git_repo_with_change("lib/example.ex")
    snapshot = prepare_snapshot(repo)

    {output, status} = run_gate(snapshot, path, [{"MIX_FAIL_GATE", "core-tests lane=library"}])

    assert status != 0
    assert output =~ "core tests (library lane) failed"
  end

  test "a missing copied ref is recovered from the local source checkout" do
    %{repo: repo, path: path, mix_marker: marker} = git_repo_with_change("lib/example.ex")
    snapshot = prepare_snapshot(repo)
    git!(snapshot, ["update-ref", "-d", "refs/remotes/origin/main"])

    {output, status} = run_gate(snapshot, path)

    assert status == 0, output

    assert git!(snapshot, ["rev-parse", "refs/remotes/origin/main"]) ==
             git!(repo, ["rev-parse", "refs/heads/main"])

    assert_core_gate_invocations(marker)
  end

  test "missing job base fails closed" do
    %{repo: repo, path: path} = git_repo_with_change("lib/example.ex")
    snapshot = prepare_snapshot(repo, false)

    {output, status} = run_gate(snapshot, path)

    assert status != 0
    assert output =~ "needs main in its local source checkout"
  end

  defp prepare_snapshot(repo, main? \\ true) do
    base = git!(repo, ["rev-parse", "HEAD^"])
    head = git!(repo, ["rev-parse", "HEAD"])
    if main?, do: git!(repo, ["update-ref", "refs/heads/main", base])

    snapshot = Path.join(Path.dirname(repo), "snapshot")
    git!(repo, ["clone", "--quiet", "--no-local", "--no-checkout", repo, snapshot])
    git!(snapshot, ["checkout", "--detach", "--quiet", head])
    git!(snapshot, ["config", "core.hooksPath", "/dev/null"])
    snapshot
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
