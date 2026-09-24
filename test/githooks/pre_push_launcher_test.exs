defmodule PtcRunner.GitHooks.PrePushLauncherTest do
  use ExUnit.Case, async: true
  import PtcRunner.TestSupport.PrePushFixture

  @tag :slow
  test "non-canonical executable-guide entries fail safe to every gate" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_changes(
        ["docs/maintainers/development-setup.md"],
        registry: "./docs/maintainers/development-setup.md\n"
      )

    {output, status} = run_hook(repo, path)

    assert status == 0, output
    refute output =~ "Documentation-only push"

    invocations =
      assert_core_gate_invocations(mix_marker, ["ci-gate launcher"], operator: true)

    # The launcher gate owns load-sensitive port-teardown assertions, so it
    # never shares the machine with a lane.
    assert List.last(invocations) == "ci-gate launcher"
  end

  test "launcher-only changes run the launcher gate" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("ptc_runner_launcher/c_src/launcher.c")

    {output, status} = run_hook(repo, path)

    assert status == 0
    assert output =~ "launcher validation passed"

    assert mix_marker |> File.read!() |> String.split("\n", trim: true) ==
             ["ci-gate launcher"]
  end

  @tag :slow
  test "mixed documentation and core changes validate documentation first" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_changes(["docs/guides/replay.md", "lib/example.ex"])

    {output, status} = run_hook(repo, path)

    assert status == 0
    assert output =~ "Documentation"
    assert output =~ "core tests"

    # Guides are executed by operator-lane tests, so the whole suite runs.
    assert_core_gate_invocations(mix_marker, [], operator: true)
  end
end
