defmodule PtcRunner.GitHooks.PrePushTest do
  use ExUnit.Case, async: true

  alias PtcRunner.TestSupport.GitEnv

  @hook Path.expand("../../.githooks/pre-push", __DIR__)
  @classifier Path.expand("../../scripts/ci/classify-changes.sh", __DIR__)
  @executable_guides Path.expand("../support/executable_guides.txt", __DIR__)
  @git_env GitEnv.clear()

  test "planning-only changes skip the full gate" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("docs/plans/kernel-notes.md")

    {output, status} = run_hook(repo, path)

    assert status == 0
    assert output =~ "Plan-only push, skipping full pre-push gate"
    refute File.exists?(mix_marker)
  end

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

    assert_core_gate_invocations(mix_marker)
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

  @tag :slow
  test "non-canonical executable-guide entries fail safe to every gate" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_changes(
        ["docs/maintainers/development-setup.md"],
        registry: "./docs/maintainers/development-setup.md\n"
      )

    {output, status} = run_hook(repo, path)

    assert status == 0, output
    refute output =~ "Documentation-only push"

    invocations = assert_core_gate_invocations(mix_marker, ["ci-gate launcher"])

    # The launcher gate owns load-sensitive port-teardown assertions, so it
    # never shares the machine with a lane.
    assert List.last(invocations) == "ci-gate launcher"
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

  test "scheduled workflow changes skip product gates" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change(".github/workflows/nightly.yml")

    {output, status} = run_hook(repo, path)

    assert status == 0
    assert output =~ "No product gates selected for these paths"
    refute output =~ "core tests"
    refute File.exists?(mix_marker)
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

  test "launcher-only changes run the launcher gate" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("ptc_runner_launcher/c_src/launcher.c")

    {output, status} = run_hook(repo, path)

    assert status == 0
    assert output =~ "launcher validation passed"

    assert mix_marker |> File.read!() |> String.split("\n", trim: true) ==
             ["ci-gate launcher"]
  end

  # The Viewer ships inside the standalone release, and the core release gate
  # starts it and serves a trace through it, so its own validation is no longer
  # the only gate a Viewer change can break.
  test "Viewer changes run the Viewer gate and the root gate" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("ptc_viewer/lib/ptc_viewer.ex")

    {output, status} = run_hook(repo, path)

    assert status == 0, output
    assert output =~ "Viewer validation"
    assert output =~ "core tests"

    markers = mix_marker |> File.read!() |> String.split("\n", trim: true)
    assert "ci-gate viewer" in markers
    assert "ci-gate core-release" in markers
  end

  @tag :slow
  test "full gate invokes every deterministic root entry point once" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("lib/example.ex")

    {output, status} = run_hook(repo, path)

    assert status == 0, output
    assert output =~ ~r/core tests passed in \d+s/
    assert output =~ ~r/core static analysis \+ Dialyzer passed in \d+s/
    assert output =~ ~r/core release verification passed in \d+s/

    assert output =~ "Phase timings:"
    assert output =~ ~r/core tests\s+\d+s/
    assert output =~ ~r/core static analysis \+ Dialyzer\s+\d+s/

    assert_core_gate_invocations(mix_marker)
  end

  @tag :slow
  test "serial mode runs every gate in the documented order" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("lib/example.ex")

    {output, status} = run_hook(repo, path, [{"PTC_PRE_PUSH_SERIAL", "1"}])

    assert status == 0, output

    assert mix_marker |> File.read!() |> String.split("\n", trim: true) ==
             [
               "deps.get --check-locked",
               "docs --warnings-as-errors",
               "ci-gate core-tests",
               "ci-gate core-static",
               "ci-gate core-dialyzer",
               "ci-gate core-release",
               "ci-gate viewer"
             ]
  end

  @tag :slow
  test "a failing lane fails the push and still reports its siblings" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("lib/example.ex")

    {output, status} =
      run_hook(repo, path, [{"MIX_FAIL_GATE", "core-release"}])

    refute status == 0

    assert output =~ "core release verification failed"
    assert output =~ "PTC_PRE_PUSH_SERIAL=1"

    # Every lane is awaited and reported even once one of them has failed,
    # so a push surfaces all of its broken gates in a single cycle.
    assert output =~ ~r/core static analysis \+ Dialyzer passed in \d+s/
    assert output =~ ~r/Viewer validation passed in \d+s/

    assert "ci-gate viewer" in (mix_marker |> File.read!() |> String.split("\n", trim: true))
  end

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

    # The sibling lanes are independent and still run to completion.
    assert "ci-gate core-release" in invocations
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
  test "the removed concurrency environment variable cannot throttle the full gate" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_change("lib/example.ex")

    {output, status} = run_hook(repo, path, [{"PTC_PRE_PUSH_MAX_CASES", "2"}])

    assert status == 0
    refute output =~ "Test concurrency"

    assert_core_gate_invocations(mix_marker)
  end

  @tag :slow
  test "mixed documentation and core changes validate documentation first" do
    %{repo: repo, mix_marker: mix_marker, path: path} =
      git_repo_with_changes(["docs/guides/replay.md", "lib/example.ex"])

    {output, status} = run_hook(repo, path)

    assert status == 0
    assert output =~ "Documentation"
    assert output =~ "core tests"

    assert_core_gate_invocations(mix_marker)
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

  @core_gate_invocations [
    "deps.get --check-locked",
    "docs --warnings-as-errors",
    "ci-gate core-tests",
    "ci-gate core-static",
    "ci-gate core-dialyzer",
    "ci-gate core-release",
    "ci-gate viewer"
  ]

  # The deterministic gates run as concurrent lanes, so the recorded sequence
  # is asserted as a multiset plus the orderings the design actually
  # guarantees. Pinning a total order here would only re-record whichever
  # interleaving the machine happened to produce.
  defp assert_core_gate_invocations(mix_marker, extra_gates \\ []) do
    invocations = mix_marker |> File.read!() |> String.split("\n", trim: true)

    assert Enum.sort(invocations) == Enum.sort(@core_gate_invocations ++ extra_gates),
           "unexpected gate invocations: #{inspect(invocations)}"

    assert_runs_before(invocations, "deps.get --check-locked", "docs --warnings-as-errors")
    assert_runs_before(invocations, "docs --warnings-as-errors", "ci-gate core-tests")

    # The suite owns the machine: no lane starts until it has finished.
    for lane <- ["ci-gate core-static", "ci-gate core-release", "ci-gate viewer"] do
      assert_runs_before(invocations, "ci-gate core-tests", lane)
    end

    # Static analysis and Dialyzer compile into the same `_build/test`, so
    # they share one lane and keep their relative order.
    assert_runs_before(invocations, "ci-gate core-static", "ci-gate core-dialyzer")

    invocations
  end

  defp assert_runs_before(invocations, earlier, later) do
    assert Enum.find_index(invocations, &(&1 == earlier)) <
             Enum.find_index(invocations, &(&1 == later)),
           "expected #{earlier} before #{later}, got: #{inspect(invocations)}"
  end

  defp git_repo_with_change(changed_path) do
    git_repo_with_changes([changed_path])
  end

  defp git_repo_with_guide_marker_removed(changed_path) do
    git_repo_with_mutation(changed_path, fn repo ->
      write_changed_file!(repo, changed_path, "annotation removed\n")
    end)
  end

  defp git_repo_with_deleted_file(changed_path) do
    git_repo_with_mutation(changed_path, fn repo ->
      File.rm!(Path.join(repo, changed_path))
    end)
  end

  defp git_repo_with_mutation(changed_path, mutate) do
    fixture = git_repo_with_changes([changed_path], commit_change?: false)
    mutate.(fixture.repo)
    git!(fixture.repo, ["add", "-A"])
    git!(fixture.repo, ["commit", "--quiet", "-m", "change"])
    fixture
  end

  defp git_repo_with_changes(changed_paths, opts \\ []) do
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
    if [ "${MIX_MUTATE_LOCK:-}" = "1" ] && [ "$*" = "deps.get --check-locked" ]; then
      exit 1
    fi
    if [ -n "${MIX_FAIL_GATE:-}" ] && [ "$*" = "ci-gate ${MIX_FAIL_GATE}" ]; then
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

  defp run_hook(repo, path, extra_env \\ []) do
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
            {"FORCE_FULL_PRE_PUSH", nil}
          ] ++ extra_env,
      stderr_to_stdout: true
    )
  end

  defp write_changed_file!(repo, path, contents) do
    full_path = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, contents)
  end

  defp fixture_contents("docs/maintainers/development-setup.md", state),
    do: "<!-- ptc-guide-e2e: id=fixture -->\n#{state}\n"

  defp fixture_contents(_path, state), do: "#{state}\n"

  defp install_hook_fixture!(repo, opts) do
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

    for gate <- ~w(core-tests core-static core-dialyzer core-release viewer launcher) do
      write_executable!(Path.join(repo, "scripts/ci/#{gate}.sh"), """
      #!/bin/sh
      mix ci-gate #{gate}
      """)
    end
  end

  defp copy_executable!(source, destination) do
    File.mkdir_p!(Path.dirname(destination))
    File.cp!(source, destination)
    File.chmod!(destination, 0o755)
  end

  defp write_executable!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp git!(repo, args) do
    {output, 0} =
      System.cmd("git", args, cd: repo, env: @git_env, stderr_to_stdout: true)

    String.trim(output)
  end
end
