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
    write!(main, "priv/plts/project.plt", "plt\n")
    write!(main, "ptc_viewer/_build/test/marker", "viewer\n")

    {output, 0} = seed(main, worktree)

    assert output =~ "🌱 deps"
    assert output =~ "🌱 _build"
    assert output =~ "🌱 priv/plts"
    assert output =~ ~r/Seeded 4 artifact\(s\)/
    assert File.read!(Path.join(worktree, "deps/jason/mix.exs")) == "jason\n"
    assert File.read!(Path.join(worktree, "priv/plts/project.plt")) == "plt\n"
    assert File.read!(Path.join(worktree, "ptc_viewer/_build/test/marker")) == "viewer\n"

    assert output =~ "ptc_runner_launcher/deps — not built in the main checkout"
    assert Path.wildcard(Path.join(worktree, ".worktree-seed-tmp*")) == []
  end

  test "discards a PLT whose source diverged from the copy" do
    %{main: main, worktree: worktree} = repo_with_worktree()

    write!(main, "priv/plts/project.plt", "plt\n")
    fake_cmp = fake_cmp_reporting_divergence!(main)

    {output, 0} = seed(main, worktree, env: [{"PATH", fake_cmp}])

    assert output =~ "priv/plts — copy failed or source changed mid-copy"
    refute File.exists?(Path.join(worktree, "priv/plts"))
  end

  test "does not seed dialyxir's PLT hash file" do
    %{main: main, worktree: worktree} = repo_with_worktree()

    write!(main, "priv/plts/project.plt", "plt\n")
    write!(main, "priv/plts/project.plt.hash", "hash\n")

    {output, 0} = seed(main, worktree)

    assert output =~ "🌱 priv/plts"
    assert File.exists?(Path.join(worktree, "priv/plts/project.plt"))
    refute File.exists?(Path.join(worktree, "priv/plts/project.plt.hash"))
  end

  test "treats a dangling destination symlink as present rather than replacing it" do
    %{main: main, worktree: worktree} = repo_with_worktree()

    write!(main, "deps/jason/mix.exs", "jason\n")
    File.ln_s!("missing-target", Path.join(worktree, "deps"))

    {output, 0} = seed(main, worktree)

    assert output =~ "deps — already present"
    assert File.lstat!(Path.join(worktree, "deps")).type == :symlink
  end

  test "skips seeding entirely when a lockfile differs" do
    %{main: main, worktree: worktree} = repo_with_worktree()

    write!(main, "deps/jason/mix.exs", "jason\n")
    write!(worktree, "mix.lock", "diverged\n")

    {output, 0} = seed(main, worktree)

    assert output =~ "Seed skipped: mix.lock differs"
    refute File.exists?(Path.join(worktree, "deps"))
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

  defp seed(main, worktree, opts \\ []) do
    System.cmd("bash", [@script, "seed", worktree],
      cd: main,
      env: @git_env ++ Keyword.get(opts, :env, []),
      stderr_to_stdout: true
    )
  end

  # A PATH whose `cmp` reports divergence for .plt files only, standing in
  # for a PLT that a concurrent dialyzer run rewrote while it was cloned.
  # Every other cmp call (the seed's lockfile guard) passes through.
  defp fake_cmp_reporting_divergence!(root) do
    bin = Path.join(root, "fake-bin")
    File.mkdir_p!(bin)
    fake_cmp = Path.join(bin, "cmp")

    File.write!(fake_cmp, """
    #!/bin/sh
    case "$*" in
      *.plt*) exit 1 ;;
      *) exec /usr/bin/cmp "$@" ;;
    esac
    """)

    File.chmod!(fake_cmp, 0o755)
    bin <> ":" <> System.fetch_env!("PATH")
  end

  defp write!(repo, path, contents) do
    full_path = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, contents)
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", args, cd: repo, env: @git_env, stderr_to_stdout: true)
    String.trim(output)
  end
end
