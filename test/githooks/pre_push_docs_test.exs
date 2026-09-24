defmodule PtcRunner.GitHooks.PrePushDocsTest do
  use ExUnit.Case, async: true
  @moduletag :operator
  import PtcRunner.TestSupport.PrePushFixture

  test "guide-only changes run only the documentation gate" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("docs/guides/replay.md")

    {output, status} = run_hook(repo, path)

    assert status == 0
    assert output =~ "Documentation-only push, running the ExDoc warnings gate"

    assert mix_marker |> File.read!() |> String.split("\n", trim: true) ==
             ["deps.get --check-locked", "docs --warnings-as-errors"]
  end

  @tag :slow
  test "generated reference changes run documentation and core gates" do
    for generated_reference <- [
          "docs/kernel-limits-reference.md",
          "docs/prelude-reference.md"
        ] do
      %{repo: repo, mix_marker: mix_marker, path: path} =
        git_repo_with_change(generated_reference)

      {output, status} = run_hook(repo, path)

      assert status == 0, output
      refute output =~ "Documentation-only push"
      assert output =~ "core tests"
      assert_core_gate_invocations(mix_marker)
    end
  end

  @tag :slow
  test "annotated maintainer example changes run documentation and core gates" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("docs/maintainers/development-setup.md")

    {output, status} = run_hook(repo, path)

    assert status == 0, output
    refute output =~ "Documentation-only push"
    assert output =~ "core tests"

    # Registered executable guides are run by operator-lane tests.
    assert_core_gate_invocations(mix_marker, [], operator: true)
  end

  @tag :slow
  test "removing the final annotation still runs documentation and core gates" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_guide_marker_removed("docs/maintainers/development-setup.md")

    {output, status} = run_hook(repo, path)

    assert status == 0, output
    refute output =~ "Documentation-only push"
    assert output =~ "core tests"
    assert File.read!(mix_marker) =~ "ci-gate core-tests"
  end

  @tag :slow
  test "deleting a registered page still runs documentation and core gates" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_deleted_file("docs/maintainers/development-setup.md")

    {output, status} = run_hook(repo, path)

    assert status == 0, output
    refute output =~ "Documentation-only push"
    assert output =~ "core tests"
    assert File.read!(mix_marker) =~ "ci-gate core-tests"
  end
end
