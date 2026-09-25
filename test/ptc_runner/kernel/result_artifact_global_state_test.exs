defmodule PtcRunner.Kernel.ResultArtifactGlobalStateTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ResultArtifact

  # A uid no real account on a test host holds, so the stubbed authority cannot
  # be mistaken for the process owner. `chown` itself takes a signed int, so the
  # foreign owner has to stay in normal range.
  @authority_uid 4_294_967_294
  @foreign_uid 65_534
  @tag :tmp_dir
  test "persists a dash-prefixed relative destination", %{tmp_dir: dir} do
    File.cd!(dir, fn ->
      assert :ok =
               ResultArtifact.persist("-result.json", %{"ok" => true}, :normal, :normal)

      assert File.regular?("-result.json")
    end)
  end

  @tag :tmp_dir
  test "resolves the secure directory creator from PATH", %{tmp_dir: dir} do
    mkdir = System.find_executable("mkdir")
    id = System.find_executable("id")
    bin = Path.join(dir, "bin")
    wrapper = Path.join(bin, "mkdir")
    id_wrapper = Path.join(bin, "id")
    marker = Path.join(dir, "mkdir-invoked")
    original_path = System.get_env("PATH")
    original_marker = System.get_env("PTC_TEST_MKDIR_MARKER")
    original_mkdir = System.get_env("PTC_TEST_REAL_MKDIR")

    assert is_binary(mkdir)
    assert is_binary(id)

    File.mkdir!(bin)
    File.ln_s!(id, id_wrapper)

    File.write!(
      wrapper,
      """
      #!/bin/sh
      printf '%s\\n' "$3" > "$PTC_TEST_MKDIR_MARKER"
      exec "$PTC_TEST_REAL_MKDIR" "$@"
      """
    )

    File.chmod!(wrapper, 0o700)
    System.put_env("PATH", bin)
    System.put_env("PTC_TEST_MKDIR_MARKER", marker)
    System.put_env("PTC_TEST_REAL_MKDIR", mkdir)

    on_exit(fn ->
      restore_env("PATH", original_path)
      restore_env("PTC_TEST_MKDIR_MARKER", original_marker)
      restore_env("PTC_TEST_REAL_MKDIR", original_mkdir)
    end)

    File.cd!(dir, fn ->
      assert :ok =
               ResultArtifact.persist(
                 "result.json",
                 %{"ok" => true},
                 :normal,
                 :normal
               )
    end)

    assert File.regular?(marker)
    assert marker |> File.read!() |> String.trim() |> Path.type() == :absolute
  end

  @tag :tmp_dir
  test "preflight fails when the secure directory creator is unavailable", %{tmp_dir: dir} do
    original_path = System.get_env("PATH")
    System.put_env("PATH", "")
    on_exit(fn -> restore_env("PATH", original_path) end)

    assert {:error, :result_persistence_failed} =
             ResultArtifact.preflight_destination(
               Path.join(dir, "result.json"),
               :normal,
               :normal
             )
  end

  @tag :tmp_dir
  test "private preflight rejects ancestry outside the process authority", %{tmp_dir: dir} do
    mkdir = System.find_executable("mkdir")
    bin = Path.join(dir, "authority-bin")
    id_wrapper = Path.join(bin, "id")
    nested = Path.join(dir, "nested")
    original_path = System.get_env("PATH")

    assert is_binary(mkdir)
    File.mkdir!(bin)
    File.mkdir!(nested)
    File.ln_s!(mkdir, Path.join(bin, "mkdir"))
    File.write!(id_wrapper, "#!/bin/sh\nprintf '#{@authority_uid}\\n'\n")
    File.chmod!(id_wrapper, 0o700)
    System.put_env("PATH", bin)
    on_exit(fn -> restore_env("PATH", original_path) end)

    # The hierarchy check trusts root as well as the reported authority, so a
    # root-owned checkout has no untrusted ancestor to find and would fail the
    # later writability check instead. An unprivileged run already owns the tree
    # with a third uid; a privileged one has to say so explicitly.
    if File.stat!(nested, time: :posix).uid == 0,
      do: :ok = File.chown(nested, @foreign_uid)

    refute File.stat!(nested, time: :posix).uid in [0, @authority_uid]

    assert {:error, :result_destination_unsafe} =
             ResultArtifact.preflight_destination(
               Path.join(nested, "result.json"),
               :private,
               :private
             )
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
