defmodule PtcRunner.Scripts.CIGatesTest do
  use ExUnit.Case, async: true

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

  test "Actions and the pre-push hook delegate deterministic gates to repository scripts" do
    workflow = File.read!(Path.join(@root, ".github/workflows/test.yml"))
    setup_action = File.read!(Path.join(@root, ".github/actions/setup-elixir/action.yml"))
    launcher_release = File.read!(Path.join(@root, ".github/workflows/launcher-release.yml"))
    hook = File.read!(Path.join(@root, ".githooks/pre-push"))
    mix_project = File.read!(Path.join(@root, "mix.exs"))
    launcher = File.read!(Path.join(@root, "scripts/ci/launcher.sh"))

    for entrypoint <- ~w(core-tests core-static core-dialyzer core-release viewer docs launcher) do
      assert workflow =~ "scripts/ci/#{entrypoint}.sh"
      assert hook =~ "scripts/ci/#{entrypoint}.sh"
    end

    refute workflow =~ "run: mix test --max-failures 1 --warnings-as-errors"
    assert setup_action =~ "mix deps.get --check-locked"
    assert launcher_release =~ ~s(scripts/ci/launcher.sh "$RUNNER_TEMP/launcher-artifacts")
    refute launcher_release =~ "run: mix precommit"
    refute launcher_release =~ "run: bash scripts/verify_precompiled.sh"
    refute hook =~ "mix test --exclude clojure"
    refute hook =~ "mix prepush"
    refute mix_project =~ ~s("cmd scripts/ci/core-tests.sh")
    refute mix_project =~ ~s("cmd scripts/ci/viewer.sh")
    refute mix_project =~ ~s("cmd scripts/ci/launcher-package.sh")
    refute mix_project =~ ~s("cmd scripts/ci/core-release.sh")
    assert mix_project =~ ~s("cmd scripts/ci/core-quality.sh")
    assert mix_project =~ ~s("cmd scripts/ci/core-static.sh")
    assert mix_project =~ ~s("cmd scripts/ci/core-dialyzer.sh")

    assert mix_project =~
             ~r/precommit: \[\n\s*"cmd scripts\/ci\/preflight\.sh",\n\s*"cmd scripts\/ci\/core-quality\.sh"\n\s*\]/

    assert launcher =~ ~s(bash ptc_runner_launcher/scripts/verify_precompiled.sh)
  end

  test "container publication is downstream of the canonical release gate" do
    release = File.read!(Path.join(@root, ".github/workflows/release.yml"))
    container = File.read!(Path.join(@root, ".github/workflows/container-release.yml"))

    assert release =~
             ~r/container:\n\s+needs: verify\n\s+uses: \.\/\.github\/workflows\/container-release\.yml/

    assert release =~ "needs: [macos-artifact, container]"
    assert container =~ "workflow_call:"
    refute container =~ ~r/^  push:/m
    assert container =~ "push-by-digest=true"
    assert container =~ "--metadata-file \"$metadata\""
    assert container =~ ~s(."containerimage.descriptor".digest)
    assert container =~ ~s({"architecture":"amd64","os":"linux"})
    assert container =~ ~s({"architecture":"arm64","os":"linux"})
    assert container =~ "Publish the exact version tag"
    refute container =~ "docker/build-push-action"
  end

  test "root Hex publication requires the immutable tagged release" do
    workflow = File.read!(Path.join(@root, ".github/workflows/hex-publish.yml"))

    assert workflow =~ "environment: hex-publish"
    assert workflow =~ "needs: build"
    assert workflow =~ "attestations: read"
    assert workflow =~ ~s(ref: ${{ github.workflow_sha }})
    assert workflow =~ "gh release verify \"$RELEASE_TAG\""
    assert workflow =~ "test \"$release_state\" = $'false\\ttrue'"
    assert workflow =~ "mix local.hex 2.3.1 --force"
    assert workflow =~ "actions/upload-artifact@v6"
    assert workflow =~ "actions/download-artifact@v7"
    assert workflow =~ "scripts/publish_hex_artifact.sh"
    assert workflow =~ "MIX_ENV=dev mix compile --warnings-as-errors"
    assert workflow =~ "MIX_ENV=dev mix docs --warnings-as-errors"
    assert workflow =~ "../workflow-source/scripts/build_hex_docs.exs"
    assert workflow =~ "packages/ptc_runner/releases?replace=false"
    assert workflow =~ "packages/ptc_runner/releases/$version/docs"
    assert workflow =~ "remote_checksum"
    assert workflow =~ ~r/--location\s+\\\n\s+--retry 12/
    refute workflow =~ "mix hex.publish"
    refute workflow =~ "replace=true"
  end

  test "the packaged release smoke covers inspect-only and both materialize modes" do
    script = File.read!(Path.join(@root, "scripts/verify_standalone_release.sh"))

    assert script =~ ~r/for command in .* materialize;/
    assert script =~ "docs inspect-source"
    assert script =~ "docs source-inspection"
    assert script =~ "--inspect-only"
    assert script =~ "--source-out"
    assert script =~ "--out \"$release_tmp_dir/candidate\""
    assert script =~ "Returns the supplied input."
    assert script =~ "(input :map) -> :map"
    assert script =~ "provider-application.json"
  end

  test "the interactive REPL PTY check is a Nightly gate, not a PR core-release gate" do
    workflow = File.read!(Path.join(@root, ".github/workflows/test.yml"))
    nightly = File.read!(Path.join(@root, ".github/workflows/nightly.yml"))
    core_release = File.read!(Path.join(@root, "scripts/ci/core-release.sh"))

    refute workflow =~ "apt-get"
    refute workflow =~ "pseudo-terminal driver"
    assert core_release =~ ~r/PTC_SKIP_PTY_GATE=1\s+scripts\/verify_standalone_release\.sh/
    assert nightly =~ "apt-get install --yes --no-install-recommends expect"
    assert nightly =~ "scripts/verify_standalone_release.sh"
    refute nightly =~ ~r/PTC_SKIP_PTY_GATE=/
  end

  describe "flake hunt" do
    @passing_record ~s({"seed":1,"schedulers":4,"wall_ms":4000,"async_ms":1000,"sync_ms":3000,"failures":[]})
    @failing_record ~s({"seed":7,"schedulers":4,"wall_ms":5000,"async_ms":1500,"sync_ms":3500,) <>
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
      assert output =~ "run 1/2: FAIL"
      assert output =~ "run 2/2: FAIL"
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

    test "the nightly workflow runs the hunt on main and keeps its records" do
      nightly = File.read!(Path.join(@root, ".github/workflows/nightly.yml"))

      assert nightly =~
               ~s(scripts/ci/flake-hunt.sh 10 --schedulers 4 --out "$RUNNER_TEMP/flake-hunt")

      assert nightly =~
               ~r/if: always\(\)\n\s+uses: actions\/upload-artifact@v6\n\s+with:\n\s+name: flake-hunt/
    end

    # The formatter is the only producer of the record file, so it is proven
    # through a real `mix test` rather than by feeding it synthetic events.
    @tag :nightly
    test "a real suite run appends one record with its seed, split, and failures" do
      %{marker: marker} = fake_mix()
      log = Path.join(Path.dirname(marker), "runs.jsonl")

      {output, status} =
        System.cmd(
          "mix",
          ["test", "test/support/test_helpers_test.exs", "--seed", "4242"],
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
