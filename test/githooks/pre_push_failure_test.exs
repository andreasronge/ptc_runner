defmodule PtcRunner.GitHooks.PrePushFailureTest do
  use ExUnit.Case, async: true
  @moduletag :operator
  import PtcRunner.TestSupport.PrePushFixture

  @tag :slow
  test "a failing static analysis skips Dialyzer in its own lane" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("lib/example.ex")

    {output, status} = run_hook(repo, path, [{"MIX_FAIL_GATE", "core-static"}])

    refute status == 0
    assert output =~ "core static analysis + Dialyzer failed"

    invocations = mix_marker |> File.read!() |> String.split("\n", trim: true)

    # Dialyzer consumes what static analysis just compiled, so the lane chains
    # them with `&&` and a failed static stage must not spend time on Dialyzer.
    assert "ci-gate core-static" in invocations
    refute "ci-gate core-dialyzer" in invocations

    # The Viewer lane is independent and still runs to completion. Release
    # verification belongs only to an explicitly forced local run.
    refute "ci-gate core-release" in invocations
    assert "ci-gate viewer" in invocations
  end

  @tag :slow
  test "a failing Dialyzer fails the push after static analysis passed" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("lib/example.ex")

    {output, status} = run_hook(repo, path, [{"MIX_FAIL_GATE", "core-dialyzer"}])

    refute status == 0
    assert output =~ "core static analysis + Dialyzer failed"

    invocations = mix_marker |> File.read!() |> String.split("\n", trim: true)

    assert "ci-gate core-static" in invocations
    assert "ci-gate core-dialyzer" in invocations
  end

  @tag :slow
  test "a failing gateway lane still reports the core static lane" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("lib/example.ex")

    {output, status} = run_hook(repo, path, [{"MIX_FAIL_GATE", "gateway"}])

    refute status == 0
    assert output =~ "Gateway validation failed"
    assert output =~ "core static analysis + Dialyzer passed"

    invocations = mix_marker |> File.read!() |> String.split("\n", trim: true)
    assert "ci-gate gateway" in invocations
    assert "ci-gate core-dialyzer" in invocations
  end

  test "documentation dependency setup rejects an uncommitted lockfile repair" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("docs/guides/replay.md")

    {output, status} = run_hook(repo, path, [{"MIX_MUTATE_LOCK", "1"}])

    assert status != 0
    assert output =~ "Documentation dependency setup or build failed"
    refute File.exists?(Path.join(repo, "mix.lock"))

    assert mix_marker |> File.read!() |> String.split("\n", trim: true) ==
             ["deps.get --check-locked"]
  end

  test "the phase summary reports cgroup memory and memory.high events per phase" do
    %{repo: repo, path: path} = git_repo_with_change("ptc_runner_launcher/c_src/launcher.c")
    cgroup = Path.join(Path.dirname(fake_bin(path)), "cgroup")
    File.mkdir_p!(cgroup)
    File.write!(Path.join(cgroup, "memory.current"), "#{300 * 1_048_576}\n")
    File.write!(Path.join(cgroup, "memory.peak"), "#{1_500 * 1_048_576}\n")
    File.write!(Path.join(cgroup, "memory.events"), "low 0\nhigh 2\nmax 0\noom 0\n")

    {output, status} =
      run_hook(repo, path, [
        {"PTC_PRE_PUSH_CGROUP_ROOT", cgroup},
        {"MIX_SIDE_EFFECT",
         "printf 'low 0\\nhigh 5\\nmax 0\\noom 0\\n' > #{Path.join(cgroup, "memory.events")}"}
      ])

    assert status == 0, output
    assert output =~ ~r/launcher validation\s+\d+s  mem 300MiB  peak 1500MiB  high \+3\n/
  end

  test "the phase summary stays silent when no cgroup memory is readable" do
    %{repo: repo, path: path} = git_repo_with_change("ptc_runner_launcher/c_src/launcher.c")
    missing = Path.join(Path.dirname(fake_bin(path)), "no-cgroup")

    {output, status} = run_hook(repo, path, [{"PTC_PRE_PUSH_CGROUP_ROOT", missing}])

    assert status == 0, output
    assert output =~ ~r/launcher validation\s+\d+s\n/
    refute output =~ "MiB"
  end
end
