defmodule PtcRunner.GitHooks.PrePushCoreTest do
  use ExUnit.Case, async: true
  @moduletag :operator
  import PtcRunner.TestSupport.PrePushFixture

  test "managed validation preserves manager-owned worktrees without running garbage collection" do
    %{repo: repo, path: path} = git_repo_with_change("lib/example.ex")
    marker = Path.join(repo, "gc-called")
    write_executable!(Path.join(repo, "scripts/worktree.sh"), "#!/bin/sh\ntouch \"$GC_MARKER\"\n")

    {output, status} =
      run_hook(repo, path, [
        {"PTC_MANAGED_OPERATION_CONTEXT", "/managed/context.json"},
        {"PTC_OPERATION_ACTIVE", "1"},
        {"GC_MARKER", marker}
      ])

    assert status == 0, output
    refute File.exists?(marker)
  end

  test "example changes run the core gate without the launcher companion" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("examples/kernel-tutorial/03-file-agent/agent.clj")

    {output, status} = run_hook(repo, path)

    assert status == 0, output
    assert output =~ "core tests"
    refute output =~ "launcher validation"

    invocations = mix_marker |> File.read!() |> String.split("\n", trim: true)
    assert "ci-gate core-tests" in invocations
    refute "ci-gate launcher" in invocations
  end

  test "a per-gate CI script runs only that gate" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("scripts/build_site.sh")

    {output, status} = run_hook(repo, path)

    assert status == 0
    assert output =~ "Documentation"
    refute output =~ "core tests"

    assert mix_marker |> File.read!() |> String.split("\n", trim: true) ==
             ["deps.get --check-locked", "docs --warnings-as-errors"]
  end

  test "Viewer changes run the Viewer gate and the root test gate" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("ptc_viewer/lib/ptc_viewer.ex")

    {output, status} = run_hook(repo, path)

    assert status == 0, output
    assert output =~ "Viewer validation"
    assert output =~ "core tests"

    markers = mix_marker |> File.read!() |> String.split("\n", trim: true)
    assert "ci-gate viewer" in markers
    refute "ci-gate core-release" in markers
  end

  @tag :slow
  test "an ordinary core push keeps release verification off the local critical path" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("lib/example.ex")

    {output, status} = run_hook(repo, path)

    assert status == 0, output
    assert output =~ ~r/core tests \(library lane\) passed in \d+s/
    assert output =~ ~r/core static analysis \+ Dialyzer passed in \d+s/
    refute output =~ "core release verification"

    assert output =~ "Phase timings:"
    assert output =~ ~r/core tests \(library lane\)\s+\d+s/
    assert output =~ ~r/core static analysis \+ Dialyzer\s+\d+s/

    assert_core_gate_invocations(mix_marker)
  end

  @tag :slow
  test "a change to an operator surface runs every module of the suite" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("lib/mix/tasks/ptc.example.ex")

    {output, status} = run_hook(repo, path)

    assert status == 0, output
    assert output =~ ~r/core tests passed in \d+s/
    refute output =~ "library lane"

    assert_core_gate_invocations(mix_marker, [], operator: true)
  end
end
