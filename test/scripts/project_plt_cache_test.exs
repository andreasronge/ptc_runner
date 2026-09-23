defmodule PtcRunner.Scripts.ProjectPltCacheTest do
  use ExUnit.Case, async: true
  @moduletag :operator

  @moduletag :nightly
  @script Path.expand("../../scripts/project-plt-cache.py", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "plt-cache-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "mix.exs"), "project configuration")
    File.write!(Path.join(root, "mix.lock"), "dependencies")
    %{root: root}
  end

  test "a completed job seeds an independent copy even after dependencies diverge", %{root: root} do
    plt = Path.join(root, "priv/plts/project.plt")
    File.mkdir_p!(Path.dirname(plt))
    original = plt_binary(:original)
    File.write!(plt, original)
    assert {_, 0} = cache(root, "publish")
    File.rm!(plt)
    File.write!(plt <> ".hash", "stale hash")
    assert {output, 0} = cache(root, "restore")
    assert output =~ "restored"
    assert File.read!(plt) == original
    refute File.exists?(plt <> ".hash")

    File.write!(plt, "private mutation")
    File.rm!(plt)
    File.write!(Path.join(root, "mix.lock"), "changed dependencies")
    assert {output, 0} = cache(root, "restore")
    assert output =~ "compatible"
    assert File.read!(plt) == original
  end

  test "corrupt publications cannot replace a valid entry and existing local PLTs survive", %{
    root: root
  } do
    plt = Path.join(root, "priv/plts/project.plt")
    File.mkdir_p!(Path.dirname(plt))
    original = plt_binary(:original)
    File.write!(plt, original)
    assert {_, 0} = cache(root, "publish")
    File.write!(plt, "torn")
    assert {_, 0} = cache(root, "publish")
    assert {_, 0} = cache(root, "restore")
    assert File.read!(plt) == "torn"
    File.rm!(plt)
    assert {_, 0} = cache(root, "restore")
    assert File.read!(plt) == original
  end

  test "a mix.exs change still restores; Dialyxir reconciles the module set", %{root: root} do
    plt = Path.join(root, "priv/plts/project.plt")
    File.mkdir_p!(Path.dirname(plt))
    original = plt_binary(:original)
    File.write!(plt, original)
    assert {_, 0} = cache(root, "publish")
    File.rm!(plt)

    File.write!(Path.join(root, "mix.exs"), "new docs groups and version")
    assert {output, 0} = cache(root, "restore")
    assert output =~ "restored (exact)"
    assert File.read!(plt) == original

    File.rm!(plt)
    File.write!(Path.join(root, "mix.exs"), "new plt_add_apps")
    File.write!(Path.join(root, "mix.lock"), "new dependencies")
    assert {output, 0} = cache(root, "restore")
    assert output =~ "compatible"
    assert File.read!(plt) == original
  end

  test "publication keeps only the newest snapshots", %{root: root} do
    plt = Path.join(root, "priv/plts/project.plt")
    File.mkdir_p!(Path.dirname(plt))
    File.write!(plt, plt_binary(:complete))
    now = System.os_time(:second)

    for n <- 1..4 do
      File.write!(Path.join(root, "mix.lock"), "lock #{n}")
      assert {_, 0} = cache(root, "publish")
      # Explicit ages: publication order must not depend on clock resolution.
      File.touch!(snapshot(root, "lock #{n}"), now - 100 + n)
    end

    File.write!(Path.join(root, "mix.lock"), "lock 5")
    assert {_, 0} = cache(root, "publish")

    assert Enum.sort(Path.wildcard(Path.join(root, "cache/*/*.plt"))) ==
             Enum.sort(for n <- 2..5, do: snapshot(root, "lock #{n}"))
  end

  test "busy publication locks are skipped and released by the operating system", %{root: root} do
    plt = Path.join(root, "priv/plts/project.plt")
    File.mkdir_p!(Path.dirname(plt))
    File.write!(plt, plt_binary(:complete))
    assert {_, 0} = cache(root, "publish")
    [lock] = Path.wildcard(Path.join(root, "cache/*/.lock"), match_dot: true)

    # Hold the real cache lock while a second OS process attempts publication.
    # Exiting the holder releases it; no polling or scheduler timing is needed.
    program = """
    import fcntl, subprocess, sys
    with open(sys.argv[1], "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        subprocess.run([sys.executable, sys.argv[2], "publish"], check=True)
    """

    assert {output, 0} =
             System.cmd("python3", ["-c", program, lock, @script],
               cd: root,
               env: [{"PTC_PROJECT_PLT_CACHE", Path.join(root, "cache")}, {"CI", nil}],
               stderr_to_stdout: true
             )

    assert output =~ "skipped"
    assert {output, 0} = cache(root, "publish")
    assert output =~ "published"
    assert Path.wildcard(Path.join(root, "cache/*/.snapshot-*"), match_dot: true) == []
  end

  test "a corrupted cache is ignored and CI keeps ownership of its own cache", %{root: root} do
    plt = Path.join(root, "priv/plts/project.plt")
    File.mkdir_p!(Path.dirname(plt))
    File.write!(plt, plt_binary(:complete))
    assert {_, 0} = cache(root, "publish")
    [entry] = Path.wildcard(Path.join(root, "cache/*/*.plt"))
    File.write!(entry, "truncated")
    File.rm!(plt)
    assert {output, 0} = cache(root, "restore")
    assert output =~ "invalid snapshot"
    refute File.exists?(plt)

    assert {"", 0} =
             System.cmd("python3", [@script, "restore"], cd: root, env: [{"CI", "1"}])

    refute File.exists?(plt)
  end

  test "a real PLT survives relocation and still detects a changed BEAM", %{root: root} do
    beam_dir = "_build/test/lib/cache_fixture/ebin"
    File.mkdir_p!(Path.join(root, beam_dir))
    File.mkdir_p!(Path.join(root, "priv/plts"))
    source = "-module(cache_fixture). -export([value/0]). value() -> 42."
    File.write!(Path.join(root, "cache_fixture.erl"), source)

    assert {_, 0} =
             System.cmd("erlc", ["+debug_info", "-o", beam_dir, "cache_fixture.erl"], cd: root)

    build = """
    _ = dialyzer:run([{analysis_type, plt_build},
      {files, [filename:absname("#{beam_dir}/cache_fixture.beam")]},
      {output_plt, "priv/plts/project.plt"}]), halt().
    """

    assert {_, 0} = System.cmd("erl", ["-noshell", "-eval", build], cd: root)
    assert {output, 0} = cache(root, "publish")
    assert output =~ "published"

    other = Path.join(root, "second checkout")
    File.mkdir_p!(Path.join(other, beam_dir))

    for file <- ["mix.exs", "mix.lock", "cache_fixture.erl", "#{beam_dir}/cache_fixture.beam"] do
      File.cp!(Path.join(root, file), Path.join(other, file))
    end

    File.rm_rf!(Path.join(root, "_build"))
    assert {output, 0} = cache(root, "restore", other)
    assert output =~ "restored"

    check = """
    ok = dialyzer_cplt:check_plt("priv/plts/project.plt", [], []), halt().
    """

    assert {_, 0} = System.cmd("erl", ["-noshell", "-eval", check], cd: other)
    File.write!(Path.join(other, "cache_fixture.erl"), String.replace(source, "42", "changed"))

    assert {_, 0} =
             System.cmd("erlc", ["+debug_info", "-o", beam_dir, "cache_fixture.erl"], cd: other)

    changed = """
    {differ, _, _, _} = dialyzer_cplt:check_plt("priv/plts/project.plt", [], []), halt().
    """

    assert {_, 0} = System.cmd("erl", ["-noshell", "-eval", changed], cd: other)
  end

  defp plt_binary(version, files \\ []) do
    :erlang.term_to_binary(
      {:file_plt, version, files, %{}, %{}, %{}, %{}, %{}, %{}, []},
      [:compressed]
    )
  end

  defp snapshot(root, lock) do
    [directory] = Path.wildcard(Path.join(root, "cache/*"))
    Path.join(directory, Base.encode16(:crypto.hash(:sha256, lock), case: :lower) <> ".plt")
  end

  defp cache(root, action, working_directory \\ nil) do
    System.cmd("python3", [@script, action],
      cd: working_directory || root,
      env: [{"PTC_PROJECT_PLT_CACHE", Path.join(root, "cache")}, {"CI", nil}],
      stderr_to_stdout: true
    )
  end
end
