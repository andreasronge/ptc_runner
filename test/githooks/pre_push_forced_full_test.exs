defmodule PtcRunner.GitHooks.PrePushForcedFullTest do
  use ExUnit.Case, async: true
  @moduletag :operator
  import PtcRunner.TestSupport.PrePushFixture

  @tag :slow
  test "serial mode runs the ordinary local gates in the documented order" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("lib/example.ex")

    {output, status} = run_hook(repo, path, [{"PTC_PRE_PUSH_SERIAL", "1"}])

    assert status == 0, output

    assert mix_marker |> File.read!() |> String.split("\n", trim: true) ==
             [
               "ci-gate core-tests lane=library",
               "deps.get --check-locked",
               "docs --warnings-as-errors",
               "ci-gate core-static",
               "ci-gate core-dialyzer",
               "ci-gate gateway",
               "ci-gate viewer"
             ]
  end

  @tag :slow
  test "a managed push runs the deterministic gates serially unless told otherwise" do
    managed = [
      {"PTC_MANAGED_OPERATION_CONTEXT", "/managed/context.json"},
      {"PTC_OPERATION_ACTIVE", "1"}
    ]

    for {extra_env, concurrent?} <- [
          {managed, false},
          {managed ++ [{"PTC_PRE_PUSH_SERIAL", "0"}], true},
          {[], true}
        ] do
      %{repo: repo, mix_marker: mix_marker, path: path} = git_repo_with_change("lib/example.ex")

      {output, status} = run_hook(repo, path, extra_env)

      assert status == 0, output
      assert output =~ "Deterministic gates (concurrent lanes)" == concurrent?, output
      assert output =~ "Gateway validation started" == concurrent?, output
      assert output =~ ~r/Gateway validation passed in \d+s/
      assert "ci-gate gateway" in (mix_marker |> File.read!() |> String.split("\n", trim: true))
    end
  end

  @tag :slow
  test "forced full mode adds release and launcher verification" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("lib/example.ex")

    {output, status} =
      run_hook(repo, path, [{"FORCE_FULL_PRE_PUSH", "1"}, {"PTC_PRE_PUSH_SERIAL", "1"}])

    assert status == 0, output

    assert mix_marker |> File.read!() |> String.split("\n", trim: true) ==
             [
               "ci-gate core-tests",
               "deps.get --check-locked",
               "docs --warnings-as-errors",
               "ci-gate core-static",
               "ci-gate core-dialyzer",
               "ci-gate gateway",
               "ci-gate core-release",
               "ci-gate viewer",
               "ci-gate launcher"
             ]
  end

  @tag :slow
  test "a failing release lane fails a forced full push and still reports its siblings" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("lib/example.ex")

    {output, status} =
      run_hook(repo, path, [
        {"FORCE_FULL_PRE_PUSH", "1"},
        {"MIX_FAIL_GATE", "core-release"},
        {"MIX_FAIL_MESSAGE",
         "error: command failed: test -f missing\n  status: 1\n  location: scripts/verify_core_package.sh:42"}
      ])

    refute status == 0

    assert output =~ "core release verification failed"
    assert output =~ "command failed: test -f missing"
    assert output =~ "status: 1"
    assert output =~ "location: scripts/verify_core_package.sh:42"
    assert output =~ "PTC_PRE_PUSH_SERIAL=1"

    # Every lane is awaited and reported even once one of them has failed,
    # so a push surfaces all of its broken gates in a single cycle.
    assert output =~ ~r/core static analysis \+ Dialyzer passed in \d+s/
    assert output =~ ~r/Viewer validation passed in \d+s/

    assert "ci-gate viewer" in (mix_marker |> File.read!() |> String.split("\n", trim: true))
  end

  @tag :slow
  test "the removed concurrency environment variable cannot throttle the full gate" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("lib/example.ex")

    {output, status} = run_hook(repo, path, [{"PTC_PRE_PUSH_MAX_CASES", "2"}])

    assert status == 0
    refute output =~ "Test concurrency"

    assert_core_gate_invocations(mix_marker)
  end
end
