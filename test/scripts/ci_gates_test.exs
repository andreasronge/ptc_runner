defmodule PtcRunner.Scripts.CIGatesTest do
  use ExUnit.Case, async: true

  alias PtcRunner.TestSupport.GitEnv

  @root Path.expand("../..", __DIR__)
  @core_tests Path.join(@root, "scripts/ci/core-tests.sh")
  @core_dialyzer Path.join(@root, "scripts/ci/core-dialyzer.sh")
  @preflight Path.join(@root, "scripts/ci/preflight.sh")
  @viewer Path.join(@root, "scripts/ci/viewer.sh")
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
    assert mix_project =~ ~s("cmd scripts/ci/core-tests.sh")
    assert mix_project =~ ~s("cmd scripts/ci/core-static.sh")
    assert mix_project =~ ~s("cmd scripts/ci/core-dialyzer.sh")
    assert mix_project =~ ~r/precommit: \[\n\s*"cmd scripts\/ci\/preflight\.sh",/
    assert launcher =~ ~s(bash ptc_runner_launcher/scripts/verify_precompiled.sh)
  end

  # Every gate is exercised the same way: the repository root as the working
  # directory, a cleared git environment, and a fake `mix` first on PATH that
  # records what it was asked to do. `:env` entries are appended, so a test can
  # override anything this sets.
  defp run_gate(script, %{marker: marker, path: path}, opts) do
    System.cmd(script, Keyword.get(opts, :args, []),
      cd: @root,
      env: @git_env ++ [{"PATH", path}, {"MIX_MARKER", marker}] ++ Keyword.get(opts, :env, []),
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
    """)

    File.chmod!(mix, 0o755)

    %{marker: marker, path: bin <> ":" <> System.fetch_env!("PATH")}
  end
end
