defmodule PtcRunner.Scripts.WorktreeSeedTest do
  use ExUnit.Case, async: true

  alias PtcRunner.TestSupport.GitEnv

  @script Path.expand("../../scripts/worktree.sh", __DIR__)
  @git_env GitEnv.clear()

  @key_files ~w(mise.toml mix.lock ptc_viewer/mix.lock ptc_runner_launcher/mix.lock)

  test "seeds a fresh worktree with the main checkout's build artifacts" do
    %{main: main, worktree: worktree} = repo_with_worktree()

    write!(main, "deps/jason/mix.exs", "jason\n")
    write!(main, "_build/test/lib/ptc_runner/ebin/x.beam", "beam\n")
    write!(main, "priv/plts/project.plt", plt_binary())
    write!(main, "ptc_viewer/_build/test/marker", "viewer\n")

    {output, 0} = seed(main, worktree)

    assert output =~ "🌱 deps"
    assert output =~ "🌱 _build"
    assert output =~ "🌱 priv/plts"
    assert output =~ ~r/Seeded 4 artifact\(s\)/
    assert File.read!(Path.join(worktree, "deps/jason/mix.exs")) == "jason\n"
    assert File.read!(Path.join(worktree, "priv/plts/project.plt")) == plt_binary()
    assert File.read!(Path.join(worktree, "ptc_viewer/_build/test/marker")) == "viewer\n"

    assert output =~ "ptc_runner_launcher/deps — not built in the main checkout"
    assert Path.wildcard(Path.join(worktree, ".worktree-seed-tmp*")) == []
  end

  # A seeded artifact carries make's and Mix's staleness authority with it.
  # `git worktree add` writes the sources first, so a copy stamped with the
  # seed time is unconditionally newer than every source it was built from,
  # and make reports a months-old native binary as up to date.
  test "preserves artifact timestamps so staleness checks stay meaningful" do
    %{main: main, worktree: worktree} = repo_with_worktree()

    artifact = "ptc_runner_launcher/_build/prod/lib/ptc_runner_launcher/priv/launcher"
    write!(main, artifact, "stale\n")
    stale = DateTime.to_unix(~U[2026-07-29 00:00:00Z])
    File.touch!(Path.join(main, artifact), stale)

    {_output, 0} = seed(main, worktree)

    assert File.stat!(Path.join(worktree, artifact), time: :posix).mtime == stale
  end

  test "does not seed dialyxir's PLT hash file" do
    %{main: main, worktree: worktree} = repo_with_worktree()

    write!(main, "priv/plts/project.plt", plt_binary())
    write!(main, "priv/plts/project.plt.hash", "hash\n")

    {output, 0} = seed(main, worktree)

    assert output =~ "🌱 priv/plts"
    assert File.exists?(Path.join(worktree, "priv/plts/project.plt"))
    refute File.exists?(Path.join(worktree, "priv/plts/project.plt.hash"))
  end

  test "discards a torn PLT copy instead of promoting it" do
    %{main: main, worktree: worktree} = repo_with_worktree()

    truncated = binary_part(plt_binary(), 0, byte_size(plt_binary()) - 3)
    write!(main, "priv/plts/project.plt", truncated)

    {output, 0} = seed(main, worktree)

    assert output =~ "priv/plts — not promoted"
    refute File.exists?(Path.join(worktree, "priv/plts"))
  end

  test "discards a PLT that is a complete term but not a file_plt record" do
    %{main: main, worktree: worktree} = repo_with_worktree()

    write!(main, "priv/plts/project.plt", :erlang.term_to_binary(:not_a_plt))

    {output, 0} = seed(main, worktree)

    assert output =~ "priv/plts — not promoted"
    refute File.exists?(Path.join(worktree, "priv/plts"))
  end

  test "discards a PLT with trailing bytes after the term" do
    %{main: main, worktree: worktree} = repo_with_worktree()

    write!(main, "priv/plts/project.plt", plt_binary() <> "garbage")

    {output, 0} = seed(main, worktree)

    assert output =~ "priv/plts — not promoted"
    refute File.exists?(Path.join(worktree, "priv/plts"))
  end

  test "treats a dangling destination symlink as present rather than replacing it" do
    %{main: main, worktree: worktree} = repo_with_worktree()

    write!(main, "deps/jason/mix.exs", "jason\n")
    File.ln_s!("missing-target", Path.join(worktree, "deps"))

    {output, 0} = seed(main, worktree)

    assert output =~ "deps — already present"
    assert File.lstat!(Path.join(worktree, "deps")).type == :symlink
  end

  # Each project's artifacts are pinned by that project's own lockfile. A
  # branch that bumps the root lock leaves `ptc_viewer/deps` identical, and
  # skipping it too costs a cold fetch in a project the branch never touched.
  test "a diverged lockfile skips only the artifacts that lockfile pins" do
    %{main: main, worktree: worktree} = repo_with_worktree()

    write!(main, "deps/jason/mix.exs", "jason\n")
    write!(main, "ptc_viewer/deps/plug/mix.exs", "plug\n")
    write!(worktree, "mix.lock", "diverged\n")

    {output, 0} = seed(main, worktree)

    assert output =~ "deps — mix.lock differs from the main checkout's copy"
    refute File.exists?(Path.join(worktree, "deps"))
    assert File.read!(Path.join(worktree, "ptc_viewer/deps/plug/mix.exs")) == "plug\n"
  end

  test "a diverged nested lockfile leaves the root's artifacts seedable" do
    %{main: main, worktree: worktree} = repo_with_worktree()

    write!(main, "deps/jason/mix.exs", "jason\n")
    write!(main, "ptc_viewer/deps/plug/mix.exs", "plug\n")
    write!(worktree, "ptc_viewer/mix.lock", "diverged\n")

    {output, 0} = seed(main, worktree)

    assert output =~ "ptc_viewer/deps — ptc_viewer/mix.lock differs from the main checkout's copy"
    refute File.exists?(Path.join(worktree, "ptc_viewer/deps"))
    assert File.read!(Path.join(worktree, "deps/jason/mix.exs")) == "jason\n"
  end

  # The toolchain pin is the one key every artifact shares: a different Erlang
  # or Elixir invalidates every compiled tree at once.
  test "a diverged toolchain pin skips every artifact" do
    %{main: main, worktree: worktree} = repo_with_worktree()

    write!(main, "deps/jason/mix.exs", "jason\n")
    write!(main, "ptc_viewer/deps/plug/mix.exs", "plug\n")
    write!(worktree, "mise.toml", "diverged\n")

    {output, 0} = seed(main, worktree)

    assert output =~ ~r/Seeded 0 artifact\(s\)/
    assert output =~ "deps — mise.toml differs from the main checkout's copy"
    refute File.exists?(Path.join(worktree, "deps"))
    refute File.exists?(Path.join(worktree, "ptc_viewer/deps"))
  end

  test "leaves artifacts that are already present untouched" do
    %{main: main, worktree: worktree} = repo_with_worktree()

    write!(main, "deps/jason/mix.exs", "upstream\n")
    write!(worktree, "deps/jason/mix.exs", "mine\n")

    {output, 0} = seed(main, worktree)

    assert output =~ "deps — already present"
    assert File.read!(Path.join(worktree, "deps/jason/mix.exs")) == "mine\n"
  end

  test "refuses to seed the main checkout from itself" do
    %{main: main} = repo_with_worktree()

    {output, status} = seed(main, main)

    assert status != 0
    assert output =~ "refusing to seed the main checkout from itself"
  end

  test "gc reads worktree activity timestamps portably" do
    %{main: main, worktree: worktree} = repo_with_worktree()
    git!(main, ["update-ref", "refs/remotes/origin/main", "HEAD"])

    {output, status} =
      System.cmd(
        "bash",
        [@script, "gc", "--no-fetch", "--no-issues", "--idle-hours", "0"],
        cd: main,
        env: @git_env,
        stderr_to_stdout: true
      )

    assert status == 0, output
    refute output =~ "integer expression expected"
    assert output =~ "Reclaimable"
    assert output =~ worktree
  end

  test "new initializes the worktree through mise by default" do
    %{main: main, log: log, path: path, worktree: worktree} = repo_with_origin()

    {output, status} =
      System.cmd(
        "bash",
        [
          "-c",
          ~S|umask 0002; exec bash "$1" new test/linux-bootstrap|,
          "worktree-bootstrap-test",
          @script
        ],
        cd: main,
        env:
          GitEnv.clear(
            PATH: path <> ":" <> System.fetch_env!("PATH"),
            PTC_INIT_LOG: log
          ),
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "Worktree initialized: #{worktree}"

    for directory <- [worktree, Path.join(worktree, "ptc_viewer")] do
      assert Bitwise.band(File.stat!(directory).mode, 0o022) == 0
    end

    assert log |> File.read!() |> String.split("\n", trim: true) == [
             "mise|trust --yes #{worktree}/mise.toml|#{worktree}|0022",
             "hooks|#{worktree}|0022",
             "mise|install|#{worktree}|0022",
             "mise|exec -- python3 #{Path.join(Path.dirname(@script), "project-plt-cache.py")} restore|#{worktree}|0022",
             "mise|exec -- mix deps.get|#{worktree}|0022",
             "mise|exec -- mix deps.get|#{worktree}/ptc_viewer|0022",
             "mise|exec -- mix deps.get|#{worktree}/ptc_runner_launcher|0022",
             "mise|exec -- mix compile|#{worktree}|0022"
           ]
  end

  defp repo_with_worktree do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-worktree-seed-#{System.unique_integer([:positive, :monotonic])}"
      )

    # Both paths carry a space so field-splitting bugs in the script's
    # `git worktree list` parsing surface here rather than on a user's disk.
    main = Path.join(root, "main checkout")
    worktree = Path.join(root, "wt one")
    File.mkdir_p!(main)
    on_exit(fn -> File.rm_rf!(root) end)

    git!(main, ["init", "--quiet"])
    git!(main, ["config", "user.email", "seed@example.test"])
    git!(main, ["config", "user.name", "Seed Test"])

    Enum.each(@key_files, &write!(main, &1, "pinned\n"))
    git!(main, ["add", "."])
    git!(main, ["commit", "--quiet", "-m", "base"])
    git!(main, ["worktree", "add", "--quiet", "--detach", worktree])

    %{main: main, worktree: worktree}
  end

  defp repo_with_origin do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-worktree-new-#{System.unique_integer([:positive, :monotonic])}"
      )

    main = Path.join(root, "main checkout")
    remote = Path.join(root, "origin.git")
    bin = Path.join(root, "bin")
    log = Path.join(root, "init.log")
    File.mkdir_p!(main)
    File.mkdir_p!(bin)
    # `git worktree list` and bash `cd` report the physical path; on macOS
    # System.tmp_dir!/0 is often under /var while the real directory is
    # /private/var.
    main = physical_path(main)
    worktree = main <> "-test-linux-bootstrap"
    on_exit(fn -> File.rm_rf!(root) end)

    git!(main, ["init", "--quiet"])
    git!(main, ["config", "user.email", "seed@example.test"])
    git!(main, ["config", "user.name", "Seed Test"])

    Enum.each(@key_files, &write!(main, &1, "pinned\n"))

    write_executable!(
      main,
      "scripts/install-hooks.sh",
      ~S"""
      #!/usr/bin/env bash
      printf 'hooks|%s|%s\n' "$PWD" "$(umask)" >> "$PTC_INIT_LOG"
      """
    )

    write_executable!(
      root,
      "bin/mise",
      ~S"""
      #!/usr/bin/env bash
      printf 'mise|%s|%s|%s\n' "$*" "$PWD" "$(umask)" >> "$PTC_INIT_LOG"
      """
    )

    git!(main, ["add", "."])
    git!(main, ["commit", "--quiet", "-m", "base"])
    git!(root, ["init", "--quiet", "--bare", remote])
    git!(main, ["remote", "add", "origin", remote])
    git!(main, ["push", "--quiet", "origin", "HEAD:main"])

    %{main: main, log: log, path: bin, worktree: worktree}
  end

  defp seed(main, worktree) do
    System.cmd("bash", [@script, "seed", worktree],
      cd: main,
      env: @git_env,
      stderr_to_stdout: true
    )
  end

  defp physical_path(path) do
    case System.cmd("pwd", ["-P"], cd: path, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {_output, _status} -> Path.expand(path)
    end
  end

  # Real PLTs are one external term; the seed proves a staged copy decodes
  # before promoting it, so fixture PLTs must decode too.
  defp plt_binary do
    :erlang.term_to_binary(
      {:file_plt, :fixture, [], %{}, %{}, %{}, %{}, %{}, %{}, []},
      [:compressed]
    )
  end

  defp write!(repo, path, contents) do
    full_path = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, contents)
  end

  defp write_executable!(repo, path, contents) do
    write!(repo, path, contents)
    File.chmod!(Path.join(repo, path), 0o755)
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", args, cd: repo, env: @git_env, stderr_to_stdout: true)
    String.trim(output)
  end
end
