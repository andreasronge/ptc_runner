defmodule PtcRunner.Lisp.TemporaryDirectoryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.DirectoryCreation
  alias PtcRunner.Lisp.TemporaryDirectory

  test "scratch directories are exclusive and owner-only, with caller-owned cleanup" do
    assert {:ok, first} = TemporaryDirectory.create("ptc-scratch-test-")
    on_exit(fn -> File.rm_rf!(first) end)
    assert {:ok, second} = TemporaryDirectory.create("ptc-scratch-test-")
    on_exit(fn -> File.rm_rf!(second) end)

    assert first != second
    assert {:ok, %File.Stat{type: :directory, mode: mode}} = File.lstat(first)
    assert Bitwise.band(mode, 0o777) == 0o700
    File.write!(Path.join(first, "artifact"), "scratch")
    assert File.read!(Path.join(first, "artifact")) == "scratch"
  end

  @tag :tmp_dir
  test "scratch creation rejects replaceable parents and never adopts an existing name", %{
    tmp_dir: root
  } do
    parent = Path.join(root, "parent")
    File.mkdir!(parent)
    File.chmod!(parent, 0o777)
    path = Path.join(parent, "scratch")
    assert {:error, :private_directory_parent_unsafe} = DirectoryCreation.create(path)
    refute File.exists?(path)

    File.chmod!(parent, 0o700)
    assert :ok = DirectoryCreation.create(path)
    File.write!(Path.join(path, "retained"), "existing")
    assert {:error, :eexist} = DirectoryCreation.create(path)
    assert File.read!(Path.join(path, "retained")) == "existing"
  end

  test "host creator controls admission and collisions never adopt existing directories" do
    existing = System.tmp_dir!()

    creator = fn _path ->
      assert File.dir?(existing)
      {:error, :eexist}
    end

    assert {:error, :private_directory_creation_failed} =
             TemporaryDirectory.create("ptc-scratch-test-", 2, creator)

    assert File.dir?(existing)

    assert {:error, :private_directory_parent_unsafe} =
             TemporaryDirectory.create("ptc-scratch-test-", 2, fn _ ->
               {:error, :private_directory_parent_unsafe}
             end)
  end
end
