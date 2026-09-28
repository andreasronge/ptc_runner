defmodule PtcRunner.Scripts.CIGatesTest do
  use ExUnit.Case, async: true
  @moduletag :operator

  alias PtcRunner.TestSupport.GitEnv

  @root Path.expand("../..", __DIR__)
  @core_tests Path.join(@root, "scripts/ci/core-tests.sh")
  @core_dialyzer Path.join(@root, "scripts/ci/core-dialyzer.sh")
  @preflight Path.join(@root, "scripts/ci/preflight.sh")
  @viewer Path.join(@root, "scripts/ci/viewer.sh")
  @launcher_package Path.join(@root, "scripts/ci/launcher-package.sh")
  @flake_hunt Path.join(@root, "scripts/ci/flake-hunt.sh")
  @flake_hunt_summary Path.join(@root, "scripts/ci/flake_hunt_summary.exs")
  @git_env GitEnv.clear()

  test "release verification gates report unhandled command failures" do
    for script <- ~w(verify_core_package.sh verify_standalone_release.sh) do
      source = File.read!(Path.join([@root, "scripts", script]))

      assert source =~ ~s(source "$script_dir/ci/_error_trap.sh")
    end

    helper = Path.join(@root, "scripts/ci/_error_trap.sh")

    fixture =
      Path.join(System.tmp_dir!(), "release-gate-error-#{System.unique_integer([:positive])}.sh")

    File.write!(fixture, """
    #!/usr/bin/env bash
    set -euo pipefail
    source "#{helper}"
    set +e
    test -f /deliberately/missing/handled-fixture
    set -e
    fail_in_function() {
      test -f /deliberately/missing/release-gate-fixture
    }
    fail_in_function
    """)

    on_exit(fn -> File.rm(fixture) end)

    {output, status} =
      System.cmd("bash", [fixture], stderr_to_stdout: true)

    assert status == 1
    refute output =~ "handled-fixture"
    assert output =~ "command failed: test -f /deliberately/missing/release-gate-fixture"
    assert output =~ "status: 1"
    assert output =~ ~r/location: .*release-gate-error-\d+\.sh:\d+/
    assert output |> String.split("command failed:") |> length() == 2
  end

  test "standalone release waits for run readiness before sending SIGINT" do
    script = File.read!(Path.join(@root, "scripts/verify_standalone_release.sh"))

    assert script =~ "--progress"
    assert script =~ "packaged ptc run did not become ready"
    refute script =~ "time.sleep(1)"
  end

  test "core tests establish the CI contract without reducing native scheduler pressure" do
    %{marker: marker} = fake = fake_mix()

    {output, status} = run_gate(@core_tests, fake, env: [{"ERL_FLAGS", "+S 7:7"}])

    assert status == 0, output

    assert File.read!(marker) |> String.split("\n", trim: true) == [
             "CI=1 MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS=+S 7:7 PWD=. :: compile --warnings-as-errors",
             "CI=1 MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS=+S 7:7 PWD=. :: test --max-failures 1 --warnings-as-errors"
           ]
  end

  test "core tests offer the GitHub four-scheduler CPU shape locally" do
    %{marker: marker} = fake = fake_mix()

    {output, status} = run_gate(@core_tests, fake, args: ["--schedulers", "4"])

    assert status == 0, output

    assert File.read!(marker) |> String.split("\n", trim: true) == [
             "CI=1 MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS=+S 4:4 PWD=. :: compile --warnings-as-errors",
             "CI=1 MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS=+S 4:4 PWD=. :: test --max-failures 1 --warnings-as-errors"
           ]
  end

  test "core tests reject malformed scheduler limits before invoking Mix" do
    %{marker: marker} = fake = fake_mix()

    {output, status} = run_gate(@core_tests, fake, args: ["--schedulers", "many"])

    assert status == 64
    assert output =~ "usage: core-tests.sh [--schedulers POSITIVE_INTEGER]"
    refute File.exists?(marker)
  end

  test "non-test gates preserve the caller's CI state for local tool caches" do
    %{marker: marker} = fake = fake_mix()

    {output, status} = run_gate(@core_dialyzer, fake, env: [{"CI", nil}, {"ERL_FLAGS", nil}])

    assert status == 0, output

    assert File.read!(marker) |> String.trim() ==
             "CI= MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS= PWD=. :: dialyzer --format github"
  end

  @tag :nightly
  test "a failed Dialyzer gate never publishes its PLT" do
    %{marker: marker} = fake = fake_mix()

    {_output, status} =
      run_gate(@core_dialyzer, fake, env: [{"CI", nil}, {"MIX_GATE_EXIT", "7"}])

    assert status == 7
    assert Path.wildcard(Path.join(Path.dirname(marker), "cache/**/*.plt")) == []
  end

  test "non-test gates preserve an explicit CI state" do
    %{marker: marker} = fake = fake_mix()

    {output, status} = run_gate(@core_dialyzer, fake, env: [{"CI", "true"}, {"ERL_FLAGS", nil}])

    assert status == 0, output

    assert File.read!(marker) |> String.trim() ==
             "CI=true MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS= PWD=. :: dialyzer --format github"
  end

  # CI supplies each nested project's dependencies from the setup action's
  # `project-directory`, so a gate that assumes them is green there and fails
  # only locally -- in a fresh worktree, after the multi-minute suites that run
  # ahead of it. Every gate fetches what it is about to compile instead.
  test "the Viewer gate fetches the Viewer's own dependencies before compiling it" do
    %{marker: marker} = fake = fake_mix()

    {output, status} = run_gate(@viewer, fake, env: [{"CI", nil}, {"ERL_FLAGS", nil}])

    assert status == 0, output

    assert File.read!(marker) |> String.split("\n", trim: true) == [
             "CI= MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS= PWD=ptc_viewer :: deps.get --check-locked",
             "CI= MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS= PWD=ptc_viewer :: compile --warnings-as-errors",
             "CI= MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS= PWD=ptc_viewer :: test --warnings-as-errors"
           ]
  end

  # The launcher project's own `precommit` alias fetches with a bare
  # `deps.get`, which repairs a diverged lockfile instead of rejecting it. The
  # gate establishes the locked fetch first, so entering it directly -- from
  # the pre-push hook, say -- answers the way CI does.
  test "the launcher gate fetches with the locked check before the project's own alias" do
    %{marker: marker} = fake = fake_mix()

    {output, status} = run_gate(@launcher_package, fake, env: [{"CI", nil}, {"ERL_FLAGS", nil}])

    assert status == 0, output

    assert File.read!(marker) |> String.split("\n", trim: true) == [
             "CI= MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS= PWD=ptc_runner_launcher :: deps.get --check-locked",
             "CI= MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS= PWD=ptc_runner_launcher :: clean",
             "CI= MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS= PWD=ptc_runner_launcher :: precommit"
           ]
  end

  # The fetch itself costs about a second warm. Paying it up front is what
  # matters: an unfetched or diverged nested project is then a seconds-long
  # failure rather than one that lands after the root suite has finished.
  test "the preflight fetches every nested project before the long gates run" do
    %{marker: marker} = fake = fake_mix()

    {output, status} = run_gate(@preflight, fake, env: [{"CI", nil}, {"ERL_FLAGS", nil}])

    assert status == 0, output

    assert File.read!(marker) |> String.split("\n", trim: true) == [
             "CI= MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS= PWD=ptc_viewer :: deps.get --check-locked",
             "CI= MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS= PWD=ptc_runner_launcher :: deps.get --check-locked"
           ]
  end

  describe "flake hunt" do
    @passing_record ~s({"seed":1,"schedulers":4,"wall_ms":4000,"async_ms":1000,"sync_ms":3000,"failures":[]})
    # `"run":null` is what a plain `mix test` writes: only flake-hunt.sh numbers runs.
    @failing_record ~s({"run":null,"seed":7,"schedulers":4,"wall_ms":5000,"async_ms":1500,"sync_ms":3500,) <>
                      ~s("failures":[{"module":"PtcRunner.ReplSessionTest","name":"test owners","file":"test/a_test.exs","line":451,"message":"no matching message after 2000ms"}]})

    test "compiles once, then runs the whole suite N times under the CI contract" do
      %{marker: marker} = fake = fake_mix()
      out = Path.join(Path.dirname(marker), "hunt")

      {output, status} =
        run_gate(@flake_hunt, fake,
          args: ["3", "--out", out],
          env: [{"ERL_FLAGS", "+S 9:9"}, {"MIX_RUN_RECORD", @passing_record}]
        )

      assert status == 0, output

      assert File.read!(marker) |> String.split("\n", trim: true) ==
               [
                 "CI=1 MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS=+S 4:4 PWD=. :: compile --warnings-as-errors"
               ] ++
                 List.duplicate(
                   "CI=1 MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS=+S 4:4 PWD=. :: test --warnings-as-errors",
                   3
                 )

      assert output =~ "flake-hunt: 3 runs, 4 schedulers, 0 with failures"
      assert output =~ ~r/wall  min 4\.0s  median 4\.0s  max 4\.0s/
      assert File.read!(Path.join(out, "summary.txt")) =~ "0 with failures"

      assert File.read!(Path.join(out, "runs.jsonl"))
             |> String.split("\n", trim: true)
             |> length() == 3
    end

    test "a reused output directory starts from an empty record" do
      %{marker: marker} = fake = fake_mix()
      out = Path.join(Path.dirname(marker), "hunt")

      for runs <- ["3", "2"] do
        {output, status} =
          run_gate(@flake_hunt, fake,
            args: [runs, "--out", out],
            env: [{"MIX_RUN_RECORD", @passing_record}]
          )

        assert status == 0, output
        assert output =~ "flake-hunt: #{runs} runs, 4 schedulers, 0 with failures"
      end

      assert out
             |> Path.join("run-*.log")
             |> Path.wildcard()
             |> Enum.map(&Path.basename/1)
             |> Enum.sort() == ["run-1.log", "run-2.log"]

      assert File.read!(Path.join(out, "runs.jsonl"))
             |> String.split("\n", trim: true)
             |> length() == 2
    end

    test "a failing run does not stop the hunt and fails the exit status" do
      %{marker: marker} = fake = fake_mix()
      out = Path.join(Path.dirname(marker), "hunt")

      {output, status} =
        run_gate(@flake_hunt, fake,
          args: ["2", "--schedulers", "6", "--out", out],
          env: [{"MIX_TEST_EXIT", "1"}, {"MIX_RUN_RECORD", @failing_record}]
        )

      assert status == 1, output
      assert output =~ "run 1/2: FAIL (exit 1)"
      assert output =~ "run 2/2: FAIL (exit 1)"
      assert File.read!(Path.join(out, "verdicts.txt")) == "1 1\n2 1\n"
      assert output =~ "flake-hunt: 2 runs, 4 schedulers, 2 with failures"
      assert output =~ "2x  test/a_test.exs:451  PtcRunner.ReplSessionTest  test owners"
      assert output =~ "seeds: 7, 7"
      assert output =~ "no matching message after 2000ms"

      assert File.read!(marker)
             |> String.split("\n", trim: true)
             |> Enum.count(
               &(&1 ==
                   "CI=1 MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS=+S 6:6 PWD=. :: test --warnings-as-errors")
             ) == 2
    end

    test "rejects malformed arguments before invoking Mix" do
      %{marker: marker} = fake = fake_mix()

      for args <- [["zero"], ["--schedulers", "many"], ["--out"]] do
        {output, status} = run_gate(@flake_hunt, fake, args: args)
        assert status == 64, output
        assert output =~ "usage: flake-hunt.sh [RUNS] [--schedulers POSITIVE_INTEGER] [--out DIR]"
      end

      refute File.exists?(marker)
    end

    test "an unnumbered failing record from a plain mix test still fails the summary" do
      %{marker: marker} = fake_mix()
      records = Path.join(Path.dirname(marker), "plain.jsonl")
      File.write!(records, @passing_record <> "\n" <> @failing_record <> "\n")

      {output, status} =
        System.cmd("elixir", [@flake_hunt_summary, records], stderr_to_stdout: true)

      assert status == 1, output
      assert output =~ "flake-hunt: 2 runs, 4 schedulers, 1 with failures"
      assert output =~ "seeds: 7"
    end

    test "the summary refuses a missing or empty record file" do
      %{marker: marker} = fake_mix()
      missing = Path.join(Path.dirname(marker), "missing.jsonl")
      empty = Path.join(Path.dirname(marker), "empty.jsonl")
      File.write!(empty, "")

      {output, status} =
        System.cmd("elixir", [@flake_hunt_summary, missing], stderr_to_stdout: true)

      assert status == 65
      assert output =~ "no run records at #{missing}"

      {output, status} =
        System.cmd("elixir", [@flake_hunt_summary, empty], stderr_to_stdout: true)

      assert status == 65
      assert output =~ "record file is empty"
    end

    test "a run that ended before the suite finished counts as a failure with no record" do
      %{marker: marker} = fake_mix()
      partial = Path.join(Path.dirname(marker), "partial.jsonl")
      File.write!(partial, @passing_record <> "\n")

      {output, status} =
        System.cmd("elixir", [@flake_hunt_summary, partial, "--expected", "3"],
          stderr_to_stdout: true
        )

      assert status == 1, output
      assert output =~ "flake-hunt: 1 runs, 4 schedulers, 2 with failures"
      assert output =~ "run 2 left no record (exit 0): it ended before the suite finished"
      assert output =~ "run 3 left no record (exit 0): it ended before the suite finished"
    end

    test "runs are paired with their verdicts by index, not by subtracting counts" do
      %{marker: marker} = fake_mix()
      records = Path.join(Path.dirname(marker), "runs.jsonl")
      verdicts = Path.join(Path.dirname(marker), "verdicts.txt")
      # Run 2's record is missing; run 3 exited 1 with a clean record; run 4
      # failed a test and exited 1. Only run 1 passed.
      File.write!(
        records,
        [
          @passing_record |> String.replace(~s({"seed":1), ~s({"run":1,"seed":1)),
          @passing_record |> String.replace(~s({"seed":1), ~s({"run":3,"seed":1)),
          @failing_record |> String.replace(~s({"run":null,"seed":7), ~s({"run":4,"seed":7))
        ]
        |> Enum.join("\n")
        |> Kernel.<>("\n")
      )

      File.write!(verdicts, "1 0\n2 0\n3 1\n4 1\n")

      {output, status} =
        System.cmd(
          "elixir",
          [@flake_hunt_summary, records, "--expected", "4", "--verdicts", verdicts],
          stderr_to_stdout: true
        )

      assert status == 1, output
      assert output =~ "flake-hunt: 3 runs, 4 schedulers, 3 with failures"
      assert output =~ "run 2 left no record (exit 0)"
      assert output =~ "run 3 exited 1 with a failure-free record"
      refute output =~ "run 4 exited"
      assert output =~ "1x  test/a_test.exs:451"
    end

    # The hunt has its own weekly workflow: its output is a rate over ten
    # samples, and it was two thirds of Nightly's cost.

    # The formatter is the only producer of the record file, so it is proven
    # through a real `mix test` rather than by feeding it synthetic events.
    @tag :nightly
    test "a real suite run appends one record with its seed, split, and failures" do
      %{marker: marker} = fake_mix()
      log = Path.join(Path.dirname(marker), "runs.jsonl")

      {output, status} =
        System.cmd(
          "mix",
          ["test", "test/ptc_runner/kernel/doctor_environment_test.exs", "--seed", "4242"],
          cd: @root,
          env: @git_env ++ [{"PTC_TEST_RUN_LOG", log}, {"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert [line] = log |> File.read!() |> String.split("\n", trim: true)
      record = Jason.decode!(line)
      assert record["seed"] == 4242
      assert record["schedulers"] == System.schedulers_online()
      assert record["failures"] == []
      assert record["tests"] > 0
      assert record["wall_ms"] >= record["async_ms"]
      assert record["sync_ms"] == record["wall_ms"] - record["async_ms"]
    end
  end

  # The quality gate stamps the tree it checked, so it is driven inside a
  # throwaway repository: a copy of the script, stub shell gates, and a fake
  # `mix` that can edit a tracked file while the gate runs.
  describe "core quality stamp" do
    test "a staged-only tree is stamped, and the commit of that tree skips the gate" do
      repo = quality_repo()
      File.write!(Path.join(repo.dir, "a.txt"), "staged\n")
      git!(repo, ~w(add a.txt))

      assert {_, 0} = run_quality(repo)
      assert quality_runs(repo) == 1

      git!(repo, ~w(commit -q -m staged))

      assert {output, 0} = run_quality(repo)
      assert output =~ "already passed"
      assert quality_runs(repo) == 1

      assert {_, 0} = run_quality(repo, [{"PTC_QUALITY_FORCE", "1"}])
      assert quality_runs(repo) == 2
    end

    test "an unstaged tracked change neither stamps nor skips" do
      repo = quality_repo()
      assert {_, 0} = run_quality(repo)

      File.write!(Path.join(repo.dir, "a.txt"), "unstaged\n")

      assert {_, 0} = run_quality(repo)
      assert {_, 0} = run_quality(repo)
      assert quality_runs(repo) == 3
    end

    # The edit is staged too, so the tree after the run is clean of unstaged
    # changes yet is not the tree the gate checked.
    test "a tracked file edited while the gate runs is not stamped" do
      repo = quality_repo()

      assert {_, 0} = run_quality(repo, [{"MIX_EDIT", Path.join(repo.dir, "a.txt")}])
      assert {_, 0} = run_quality(repo)
      assert quality_runs(repo) == 2
    end
  end

  defp quality_repo do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ptc-core-quality-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(Path.join(dir, "scripts/ci"))
    File.mkdir_p!(Path.join(dir, "bin"))

    for script <- ~w(core-quality.sh _common.sh) do
      File.cp!(Path.join([@root, "scripts/ci", script]), Path.join([dir, "scripts/ci", script]))
    end

    for {path, body} <- [
          {"scripts/duplication_gate.sh", "#!/bin/sh\nexit 0\n"},
          {"scripts/guide_budget.sh", "#!/bin/sh\nexit 0\n"},
          {"bin/mix",
           """
           #!/bin/sh
           echo "$*" >> "$MIX_MARKER"
           if [ -n "${MIX_EDIT:-}" ]; then echo edited >> "$MIX_EDIT" && git add "$MIX_EDIT"; fi
           """}
        ] do
      File.write!(Path.join(dir, path), body)
      File.chmod!(Path.join(dir, path), 0o755)
    end

    File.write!(Path.join(dir, ".gitignore"), "_build/\nbin/\nmix-called\n")
    File.write!(Path.join(dir, "a.txt"), "committed\n")
    repo = %{dir: dir, marker: Path.join(dir, "mix-called")}
    git!(repo, ~w(init -q))
    git!(repo, ~w(add .))
    git!(repo, ~w(commit -q -m init))
    repo
  end

  defp git!(%{dir: dir}, args) do
    identity = ~w(-c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false)

    {output, 0} =
      System.cmd("git", identity ++ args, cd: dir, env: @git_env, stderr_to_stdout: true)

    output
  end

  defp run_quality(%{dir: dir, marker: marker}, env \\ []) do
    System.cmd(Path.join(dir, "scripts/ci/core-quality.sh"), [],
      cd: dir,
      env:
        @git_env ++
          [
            {"PATH", Path.join(dir, "bin") <> ":" <> System.fetch_env!("PATH")},
            {"MIX_MARKER", marker},
            {"PTC_QUALITY_FORCE", nil}
          ] ++ env,
      stderr_to_stdout: true
    )
  end

  defp quality_runs(%{marker: marker}) do
    case File.read(marker) do
      {:ok, content} -> content |> String.split("\n", trim: true) |> length()
      {:error, :enoent} -> 0
    end
  end

  # Every gate is exercised the same way: the repository root as the working
  # directory, a cleared git environment, and a fake `mix` first on PATH that
  # records what it was asked to do. `:env` entries are appended, so a test can
  # override anything this sets.
  defp run_gate(script, %{marker: marker, path: path}, opts) do
    System.cmd(script, Keyword.get(opts, :args, []),
      cd: @root,
      env:
        @git_env ++
          [
            {"PATH", path},
            {"MIX_MARKER", marker},
            {"PTC_PROJECT_PLT_CACHE", Path.join(Path.dirname(marker), "cache")}
          ] ++ Keyword.get(opts, :env, []),
      stderr_to_stdout: true
    )
  end

  defp fake_mix do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-ci-gates-#{System.unique_integer([:positive, :monotonic])}"
      )

    bin = Path.join(root, "bin")
    marker = Path.join(root, "mix-called")
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(root) end)

    mix = Path.join(bin, "mix")

    # The recorded working directory is part of the contract, not decoration:
    # a nested project's dependencies are only fetched if Mix was invoked
    # inside that project.
    File.write!(mix, """
    #!/bin/sh
    repo_root='#{@root}'
    rel="${PWD#$repo_root}"
    rel="${rel#/}"
    printf 'CI=%s MIX_ENV=%s HEX_SPONSOR=%s ERL_FLAGS=%s PWD=%s :: %s\n' \\
      "$CI" "$MIX_ENV" "$HEX_SPONSOR" "${ERL_FLAGS:-}" "${rel:-.}" "$*" >> "$MIX_MARKER"
    if [ "$1" = test ] && [ -n "${PTC_TEST_RUN_LOG:-}" ] && [ -n "${MIX_RUN_RECORD:-}" ]; then
      printf '%s\n' "$MIX_RUN_RECORD" >> "$PTC_TEST_RUN_LOG"
    fi
    if [ "$1" = test ] && [ -n "${MIX_TEST_EXIT:-}" ]; then
      exit "$MIX_TEST_EXIT"
    fi
    exit "${MIX_GATE_EXIT:-0}"
    """)

    File.chmod!(mix, 0o755)

    %{marker: marker, path: bin <> ":" <> System.fetch_env!("PATH")}
  end
end
