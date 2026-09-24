defmodule PtcRunner.TestSupport.PrePushFixture do
  @moduledoc """
  Shared repository and hook fixtures for the pre-push routing tests.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias PtcRunner.TestSupport.GitEnv

  @hook Path.expand("../../.githooks/pre-push", __DIR__)
  @classifier Path.expand("../../scripts/ci/classify-changes.sh", __DIR__)
  @executable_guides Path.expand("executable_guides.txt", __DIR__)
  @git_env GitEnv.clear()

  @core_gate_invocations [
    "deps.get --check-locked",
    "docs --warnings-as-errors",
    "ci-gate core-static",
    "ci-gate core-dialyzer",
    "ci-gate gateway",
    "ci-gate viewer"
  ]

  # The deterministic gates run as concurrent lanes, so the recorded sequence
  # is asserted as a multiset plus the orderings the design actually
  # guarantees. Pinning a total order here would only re-record whichever
  # interleaving the machine happened to produce.
  # A push that touches no operator surface runs the library lane of the suite;
  # one that does runs every module.
  def assert_core_gate_invocations(mix_marker, extra_gates \\ [], opts \\ []) do
    invocations = mix_marker |> File.read!() |> String.split("\n", trim: true)

    core_tests =
      if opts[:operator], do: "ci-gate core-tests", else: "ci-gate core-tests lane=library"

    expected = @core_gate_invocations ++ [core_tests] ++ extra_gates

    assert Enum.sort(invocations) == Enum.sort(expected),
           "unexpected gate invocations: #{inspect(invocations)}"

    assert_runs_before(invocations, "deps.get --check-locked", "docs --warnings-as-errors")

    # The suite owns the machine: no lane starts until it has finished.
    for lane <- [
          "ci-gate core-static",
          "ci-gate gateway",
          "ci-gate viewer",
          "docs --warnings-as-errors"
        ] do
      assert_runs_before(invocations, core_tests, lane)
    end

    # Static analysis and Dialyzer compile into the same `_build/test`, so
    # they share one lane and keep their relative order.
    assert_runs_before(invocations, "ci-gate core-static", "ci-gate core-dialyzer")

    invocations
  end

  def assert_runs_before(invocations, earlier, later) do
    assert Enum.find_index(invocations, &(&1 == earlier)) <
             Enum.find_index(invocations, &(&1 == later)),
           "expected #{earlier} before #{later}, got: #{inspect(invocations)}"
  end

  def git_repo_with_change(changed_path) do
    git_repo_with_changes([changed_path])
  end

  def git_repo_with_guide_marker_removed(changed_path) do
    git_repo_with_mutation(changed_path, fn repo ->
      write_changed_file!(repo, changed_path, "annotation removed\n")
    end)
  end

  def git_repo_with_deleted_file(changed_path) do
    git_repo_with_mutation(changed_path, fn repo ->
      File.rm!(Path.join(repo, changed_path))
    end)
  end

  def git_repo_with_mutation(changed_path, mutate) do
    fixture = git_repo_with_changes([changed_path], commit_change?: false)
    mutate.(fixture.repo)
    git!(fixture.repo, ["add", "-A"])
    git!(fixture.repo, ["commit", "--quiet", "-m", "change"])
    fixture
  end

  def git_repo_with_changes(changed_paths, opts \\ []) do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-pre-push-#{System.unique_integer([:positive, :monotonic])}"
      )

    repo = Path.join(root, "repo")
    bin = Path.join(root, "bin")
    mix_marker = Path.join(root, "mix-called")
    File.mkdir_p!(repo)
    File.mkdir_p!(bin)

    on_exit(fn -> File.rm_rf!(root) end)

    install_hook_fixture!(repo, opts)

    fake_mix = Path.join(bin, "mix")

    File.write!(fake_mix, """
    #!/bin/sh
    printf '%s\n' "$*" >> "$MIX_MARKER"
    if [ -n "${MIX_SIDE_EFFECT:-}" ]; then
      sh -c "$MIX_SIDE_EFFECT"
    fi
    if [ "${MIX_MUTATE_LOCK:-}" = "1" ] && [ "$*" = "deps.get --check-locked" ]; then
      exit 1
    fi
    if [ -n "${MIX_FAIL_GATE:-}" ] && [ "$*" = "ci-gate ${MIX_FAIL_GATE}" ]; then
      if [ -n "${MIX_FAIL_MESSAGE:-}" ]; then
        printf '%s\n' "$MIX_FAIL_MESSAGE" >&2
      fi
      exit 1
    fi
    exit 0
    """)

    File.chmod!(fake_mix, 0o755)

    git!(repo, ["init", "--quiet"])
    git!(repo, ["config", "user.email", "pre-push@example.test"])
    git!(repo, ["config", "user.name", "Pre-push Test"])

    File.write!(Path.join(repo, "mix.exs"), "{:dialyxir, \"~> 1.4\"}\n")
    Enum.each(changed_paths, &write_changed_file!(repo, &1, fixture_contents(&1, "before")))
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--quiet", "-m", "base"])

    if Keyword.get(opts, :commit_change?, true) do
      Enum.each(changed_paths, &write_changed_file!(repo, &1, fixture_contents(&1, "after")))
      git!(repo, ["add", "."])
      git!(repo, ["commit", "--quiet", "-m", "change"])
    end

    %{repo: repo, path: bin <> ":" <> System.fetch_env!("PATH"), mix_marker: mix_marker}
  end

  def run_hook(repo, path, extra_env \\ []) do
    base = git!(repo, ["rev-parse", "HEAD^"])
    head = git!(repo, ["rev-parse", "HEAD"])
    refs = "refs/heads/test #{head} refs/heads/test #{base}\n"

    System.cmd(
      "bash",
      ["-c", "printf '%s' \"$HOOK_REFS\" | \"$HOOK_PATH\""],
      cd: repo,
      env:
        @git_env ++
          [
            {"HOOK_PATH", Path.join(repo, ".githooks/pre-push")},
            {"HOOK_REFS", refs},
            {"MIX_MARKER",
             Path.join(path |> String.split(":") |> hd() |> Path.dirname(), "mix-called")},
            {"PATH", path},
            # The gate that runs these tests may itself have been invoked with
            # PTC_PRE_PUSH_SERIAL or FORCE_FULL_PRE_PUSH set -- the release
            # procedure runs `FORCE_FULL_PRE_PUSH=1 .githooks/pre-push`, which
            # exports both down into this suite. Without clearing them, the
            # ambient values decide whether the hook under test runs lanes and
            # which gates it selects, so the classification assertions quietly
            # test a forced full run instead. Cases that want a mode set it
            # through extra_env, which wins by coming last.
            {"PTC_PRE_PUSH_SERIAL", nil},
            {"PTC_MANAGED_OPERATION_CONTEXT", nil},
            {"PTC_OPERATION_ACTIVE", nil},
            {"FORCE_FULL_PRE_PUSH", nil}
          ] ++ extra_env,
      stderr_to_stdout: true
    )
  end

  def install_operation_wrapper!(path) do
    bin = fake_bin(path)
    marker = Path.join(Path.dirname(bin), "operation-called")

    write_executable!(Path.join(bin, "ptc-operation"), """
    #!/bin/sh
    printf '%s\n' "$*" >> "$OPERATION_MARKER"
    [ "$1" = "run" ] && [ "$2" = "--label" ] && [ "$3" = "verify" ] && [ "$4" = "--" ]
    shift 4
    PTC_OPERATION_ACTIVE=1 exec "$@"
    """)

    marker
  end

  def fake_bin(path), do: path |> String.split(":") |> hd()

  def write_changed_file!(repo, path, contents) do
    full_path = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, contents)
  end

  def fixture_contents("docs/maintainers/development-setup.md", state),
    do: "<!-- ptc-guide-e2e: id=fixture -->\n#{state}\n"

  def fixture_contents(_path, state), do: "#{state}\n"

  def install_hook_fixture!(repo, opts) do
    copy_executable!(@hook, Path.join(repo, ".githooks/pre-push"))
    copy_executable!(@classifier, Path.join(repo, "scripts/ci/classify-changes.sh"))
    File.mkdir_p!(Path.join(repo, "test/support"))

    registry = Path.join(repo, "test/support/executable_guides.txt")

    case opts[:registry] do
      nil -> File.cp!(@executable_guides, registry)
      contents -> File.write!(registry, contents)
    end

    write_executable!(Path.join(repo, "scripts/ci/docs.sh"), """
    #!/bin/sh
    mix deps.get --check-locked && mix docs --warnings-as-errors
    """)

    for gate <- ~w(core-tests core-static core-dialyzer gateway core-release viewer launcher) do
      write_executable!(Path.join(repo, "scripts/ci/#{gate}.sh"), """
      #!/bin/sh
      mix ci-gate #{gate}${PTC_TEST_LANE:+ lane=$PTC_TEST_LANE}
      """)
    end
  end

  def copy_executable!(source, destination) do
    File.mkdir_p!(Path.dirname(destination))
    File.cp!(source, destination)
    File.chmod!(destination, 0o755)
  end

  def write_executable!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  def git!(repo, args) do
    {output, 0} =
      System.cmd("git", args, cd: repo, env: @git_env, stderr_to_stdout: true)

    String.trim(output)
  end
end
