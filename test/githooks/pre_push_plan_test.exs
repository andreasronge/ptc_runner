defmodule PtcRunner.GitHooks.PrePushPlanTest do
  use ExUnit.Case, async: true
  @moduletag :operator
  import PtcRunner.TestSupport.PrePushFixture

  test "managed pushes coordinate the complete hook exactly once" do
    %{repo: repo, path: path} = git_repo_with_change("docs/plans/managed-hook.md")
    operation_marker = install_operation_wrapper!(path)

    {output, status} =
      run_hook(repo, path, [
        {"PTC_MANAGED_OPERATION_CONTEXT", "/managed/context.json"},
        {"PTC_OPERATION_WRAPPER", Path.join(fake_bin(path), "ptc-operation")},
        {"OPERATION_MARKER", operation_marker}
      ])

    assert status == 0, output
    assert output =~ "Plan-only push, skipping full pre-push gate"

    assert File.read!(operation_marker) |> String.split("\n", trim: true) ==
             ["run --label verify -- #{Path.join(repo, ".githooks/pre-push")}"]
  end

  test "an active operation does not recursively coordinate the hook" do
    %{repo: repo, path: path} = git_repo_with_change("docs/plans/nested-hook.md")
    operation_marker = install_operation_wrapper!(path)

    {output, status} =
      run_hook(repo, path, [
        {"PTC_MANAGED_OPERATION_CONTEXT", "/managed/context.json"},
        {"PTC_OPERATION_WRAPPER", Path.join(fake_bin(path), "ptc-operation")},
        {"PTC_OPERATION_ACTIVE", "1"},
        {"OPERATION_MARKER", operation_marker}
      ])

    assert status == 0, output
    assert output =~ "Plan-only push, skipping full pre-push gate"
    refute File.exists?(operation_marker)
  end

  test "an unmanaged Mac push ignores an available operation wrapper" do
    %{repo: repo, path: path} = git_repo_with_change("docs/plans/local-hook.md")
    operation_marker = install_operation_wrapper!(path)

    {output, status} =
      run_hook(repo, path, [
        {"PTC_OPERATION_WRAPPER", Path.join(fake_bin(path), "ptc-operation")},
        {"OPERATION_MARKER", operation_marker}
      ])

    assert status == 0, output
    assert output =~ "Plan-only push, skipping full pre-push gate"
    refute File.exists?(operation_marker)
  end

  test "planning-only changes skip the full gate" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("docs/plans/kernel-notes.md")

    {output, status} = run_hook(repo, path)

    assert status == 0
    assert output =~ "Plan-only push, skipping full pre-push gate"
    refute File.exists?(mix_marker)
  end

  test "scheduled workflow changes skip product gates" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change(".github/workflows/nightly.yml")

    {output, status} = run_hook(repo, path)

    assert status == 0
    assert output =~ "No product gates selected for these paths"
    refute output =~ "core tests"
    refute File.exists?(mix_marker)
  end
end
