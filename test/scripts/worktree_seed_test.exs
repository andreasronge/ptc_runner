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

  defp seed(main, worktree) do
    System.cmd("bash", [@script, "seed", worktree],
      cd: main,
      env: @git_env,
      stderr_to_stdout: true
    )
  end

  # Real PLTs are one external term; the seed proves a staged copy decodes
  # before promoting it, so fixture PLTs must decode too.
  defp plt_binary, do: :erlang.term_to_binary({:file_plt, :fixture})

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
