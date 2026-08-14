defmodule PtcRunner.Scripts.CIGatesTest do
  use ExUnit.Case, async: true

  alias PtcRunner.TestSupport.GitEnv
  alias PtcRunner.TestSupport.MixBackstop

  @root Path.expand("../..", __DIR__)
  @core_tests Path.join(@root, "scripts/ci/core-tests.sh")
  @core_dialyzer Path.join(@root, "scripts/ci/core-dialyzer.sh")
  @git_env GitEnv.clear()

  test "core tests establish the CI contract without reducing native scheduler pressure" do
    %{marker: marker, path: path} = fake_mix()

    {output, status} =
      System.cmd(@core_tests, [],
        cd: @root,
        env:
          @git_env ++
            [
              {"PATH", path},
              {"MIX_MARKER", marker},
              {"ERL_FLAGS", "+S 7:7"}
            ],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert File.read!(marker) |> String.split("\n", trim: true) == [
             "CI=1 MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS=+S 7:7 :: compile --warnings-as-errors",
             "CI=1 MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS=+S 7:7 :: test --max-failures 1 --warnings-as-errors"
           ]
  end

  test "core tests offer the GitHub four-scheduler CPU shape locally" do
    %{marker: marker, path: path} = fake_mix()

    {output, status} =
      System.cmd(@core_tests, ["--schedulers", "4"],
        cd: @root,
        env: @git_env ++ [{"PATH", path}, {"MIX_MARKER", marker}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert File.read!(marker) |> String.split("\n", trim: true) == [
             "CI=1 MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS=+S 4:4 :: compile --warnings-as-errors",
             "CI=1 MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS=+S 4:4 :: test --max-failures 1 --warnings-as-errors"
           ]
  end

  test "core tests reject malformed scheduler limits before invoking Mix" do
    %{marker: marker, path: path} = fake_mix()

    {output, status} =
      System.cmd(@core_tests, ["--schedulers", "many"],
        cd: @root,
        env: @git_env ++ [{"PATH", path}, {"MIX_MARKER", marker}],
        stderr_to_stdout: true
      )

    assert status == 64
    assert output =~ "usage: core-tests.sh [--schedulers POSITIVE_INTEGER]"
    refute File.exists?(marker)
  end

  test "non-test gates preserve the caller's CI state for local tool caches" do
    %{marker: marker, path: path} = fake_mix()

    {output, status} =
      System.cmd(@core_dialyzer, [],
        cd: @root,
        env:
          @git_env ++
            [{"CI", nil}, {"ERL_FLAGS", nil}, {"PATH", path}, {"MIX_MARKER", marker}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert File.read!(marker) |> String.trim() ==
             "CI= MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS= :: dialyzer --format github"
  end

  test "non-test gates preserve an explicit CI state" do
    %{marker: marker, path: path} = fake_mix()

    {output, status} =
      System.cmd(@core_dialyzer, [],
        cd: @root,
        env:
          @git_env ++
            [{"CI", "true"}, {"ERL_FLAGS", nil}, {"PATH", path}, {"MIX_MARKER", marker}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert File.read!(marker) |> String.trim() ==
             "CI=true MIX_ENV=test HEX_SPONSOR=false ERL_FLAGS= :: dialyzer --format github"
  end

  test "a gate script outliving its stub cannot fall through to the real Mix" do
    %{path: path} = fake_mix()
    [stub | _] = String.split(path, ":")

    # ExUnit runs `on_exit` as soon as a test times out, so a `System.cmd/3`
    # child can still be running when its stub is deleted. Without a backstop
    # the next `mix` call resolves to the developer's real one and this script
    # starts a full `mix test` — which runs this file again, recursively.
    File.rm_rf!(stub)

    {output, status} =
      System.cmd(@core_tests, [],
        cd: @root,
        env: @git_env ++ [{"PATH", path}],
        stderr_to_stdout: true
      )

    assert status == 0
    assert output == ""
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
    assert launcher =~ ~s(bash ptc_runner_launcher/scripts/verify_precompiled.sh)
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

    File.write!(mix, """
    #!/bin/sh
    printf 'CI=%s MIX_ENV=%s HEX_SPONSOR=%s ERL_FLAGS=%s :: %s\n' \\
      "$CI" "$MIX_ENV" "$HEX_SPONSOR" "${ERL_FLAGS:-}" "$*" >> "$MIX_MARKER"
    """)

    File.chmod!(mix, 0o755)

    %{marker: marker, path: MixBackstop.stub_path(bin)}
  end
end
