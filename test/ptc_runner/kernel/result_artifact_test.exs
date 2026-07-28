defmodule PtcRunner.Kernel.ResultArtifactTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.ResultArtifact

  @tag :tmp_dir
  test "persists the same canonical bytes used by run result hashes", %{tmp_dir: dir} do
    value = %{"z" => [3, 2, 1], "a" => %{"b" => true}}
    path = Path.join(dir, "result.json")

    assert :ok = ResultArtifact.persist(path, value, :normal, :normal)
    assert {:ok, canonical} = DeterministicJSON.encode(value)
    assert File.read!(path) == canonical
  end

  @tag :tmp_dir
  test "callback write failures return the persistence error without raising", %{tmp_dir: dir} do
    path = Path.join(dir, "write-failure.json")

    assert {:error, :result_persistence_failed} =
             ResultArtifact.persist(
               path,
               %{"ok" => true},
               :normal,
               :normal,
               fn
                 :before_write -> {:error, :simulated_write_failure}
                 _stage -> :ok
               end
             )

    refute File.exists?(path)
  end

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
  test "private preflight rejects a replaceable parent directory", %{tmp_dir: dir} do
    replaceable = Path.join(dir, "replaceable")
    File.mkdir!(replaceable)
    File.chmod!(replaceable, 0o777)

    assert {:error, :result_persistence_failed} =
             ResultArtifact.preflight_destination(
               Path.join(replaceable, "result.json"),
               :private,
               :private
             )
  end

  @tag :tmp_dir
  test "private preflight rejects ancestry outside the process authority", %{tmp_dir: dir} do
    mkdir = System.find_executable("mkdir")
    bin = Path.join(dir, "authority-bin")
    id_wrapper = Path.join(bin, "id")
    original_path = System.get_env("PATH")

    assert is_binary(mkdir)
    File.mkdir!(bin)
    File.ln_s!(mkdir, Path.join(bin, "mkdir"))
    File.write!(id_wrapper, "#!/bin/sh\nprintf '4294967294\\n'\n")
    File.chmod!(id_wrapper, 0o700)
    System.put_env("PATH", bin)
    on_exit(fn -> restore_env("PATH", original_path) end)

    assert {:error, :result_persistence_failed} =
             ResultArtifact.preflight_destination(
               Path.join(dir, "result.json"),
               :private,
               :private
             )
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
