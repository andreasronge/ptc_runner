defmodule PtcRunner.GitHooks.PrePushLauncherTest do
  use ExUnit.Case, async: true
  @moduletag :operator
  import PtcRunner.TestSupport.PrePushFixture

  @tag :slow
  test "launcher gate runs last when core and launcher both change" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_changes(["lib/example.ex", "ptc_runner_launcher/c_src/launcher.c"])

    {output, status} = run_hook(repo, path)

    assert status == 0, output

    assert List.last(assert_core_gate_invocations(mix_marker, ["ci-gate launcher"])) ==
             "ci-gate launcher"
  end
end
