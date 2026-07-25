defmodule PtcRunner.Kernel.ConfinedFileTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ConfinedFile

  @max_bytes 1_000

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")
    File.mkdir_p!(Path.join(root, "nested"))
    File.write!(Path.join(root, "manifest.json"), ~s({"version": 1}))
    File.write!(Path.join([root, "nested", "component.clj"]), "(def x 1)")
    File.write!(Path.join(tmp_dir, "outside-secret"), "must not be readable")
    {:ok, root: root, outside: tmp_dir}
  end

  @moduletag :tmp_dir

  describe "reading inside the root" do
    test "reads a file at the root", %{root: root} do
      assert {:ok, ~s({"version": 1})} = ConfinedFile.read(root, "manifest.json", @max_bytes)
    end

    test "reads a nested file", %{root: root} do
      assert {:ok, "(def x 1)"} =
               ConfinedFile.read(root, "nested/component.clj", @max_bytes)
    end

    test "reads an empty file", %{root: root} do
      File.write!(Path.join(root, "empty.json"), "")
      assert {:ok, ""} = ConfinedFile.read(root, "empty.json", @max_bytes)
    end

    test "accepts a file of exactly max_bytes", %{root: root} do
      File.write!(Path.join(root, "exact"), String.duplicate("a", 64))
      assert {:ok, content} = ConfinedFile.read(root, "exact", 64)
      assert byte_size(content) == 64
    end
  end

  describe "path confinement" do
    # Traversal was previously contained only because the frozen-snapshot
    # lookup missed. A direct read must reject the segment itself.
    test "rejects a parent-directory escape", %{root: root, outside: outside} do
      assert File.exists?(Path.join(outside, "outside-secret"))
      assert {:error, :invalid_path} = ConfinedFile.read(root, "../outside-secret", @max_bytes)
    end

    test "rejects a parent-directory segment in the middle of a path", %{root: root} do
      assert {:error, :invalid_path} =
               ConfinedFile.read(root, "nested/../manifest.json", @max_bytes)
    end

    test "rejects a current-directory segment", %{root: root} do
      assert {:error, :invalid_path} = ConfinedFile.read(root, "./manifest.json", @max_bytes)
    end

    test "rejects an absolute path", %{root: root, outside: outside} do
      absolute = Path.join(outside, "outside-secret")
      assert {:error, :invalid_path} = ConfinedFile.read(root, absolute, @max_bytes)
    end

    test "rejects an empty path", %{root: root} do
      assert {:error, :invalid_path} = ConfinedFile.read(root, "", @max_bytes)
    end

    test "rejects a path containing a NUL byte", %{root: root} do
      assert {:error, :invalid_path} = ConfinedFile.read(root, "manifest\0.json", @max_bytes)
    end

    test "rejects an oversized path", %{root: root} do
      assert {:error, :invalid_path} =
               ConfinedFile.read(root, String.duplicate("a", 1_025), @max_bytes)
    end

    test "rejects a missing root", %{root: root} do
      assert {:error, _reason} =
               ConfinedFile.read(Path.join(root, "absent"), "manifest.json", @max_bytes)
    end
  end

  describe "symbolic links" do
    test "follows a link whose target stays inside the root", %{root: root} do
      File.ln_s!("manifest.json", Path.join(root, "alias.json"))
      assert {:ok, ~s({"version": 1})} = ConfinedFile.read(root, "alias.json", @max_bytes)
    end

    test "rejects a link escaping the root", %{root: root, outside: outside} do
      File.ln_s!(Path.join(outside, "outside-secret"), Path.join(root, "escape.json"))

      assert {:error, :symlink_escape} = ConfinedFile.read(root, "escape.json", @max_bytes)
    end

    test "rejects a link chain that escapes through an intermediate directory",
         %{root: root, outside: outside} do
      File.ln_s!(outside, Path.join(root, "up"))

      assert {:error, :symlink_escape} =
               ConfinedFile.read(root, "up/outside-secret", @max_bytes)
    end

    test "rejects a link cycle", %{root: root} do
      File.ln_s!("b.json", Path.join(root, "a.json"))
      File.ln_s!("a.json", Path.join(root, "b.json"))

      assert {:error, reason} = ConfinedFile.read(root, "a.json", @max_bytes)
      assert reason in [:symlink_depth_exceeded, :not_found]
    end
  end

  describe "content bounds" do
    test "rejects a file larger than max_bytes", %{root: root} do
      File.write!(Path.join(root, "large"), String.duplicate("a", 128))
      assert {:error, :too_large} = ConfinedFile.read(root, "large", 64)
    end

    test "rejects invalid UTF-8", %{root: root} do
      File.write!(Path.join(root, "binary"), <<0xFF, 0xFE, 0xFD>>)
      assert {:error, :invalid_utf8} = ConfinedFile.read(root, "binary", @max_bytes)
    end

    test "rejects a directory", %{root: root} do
      assert {:error, :not_regular} = ConfinedFile.read(root, "nested", @max_bytes)
    end

    test "reports a missing file distinctly from a denied path", %{root: root} do
      assert {:error, :not_found} = ConfinedFile.read(root, "absent.json", @max_bytes)
    end
  end

  describe "resolve_absolute/1" do
    test "returns a canonical path", %{root: root} do
      assert {:ok, resolved} = ConfinedFile.resolve_absolute(Path.join(root, "manifest.json"))
      assert resolved == Path.join(root, "manifest.json")
    end

    test "resolves through a symbolic link", %{root: root} do
      File.ln_s!("manifest.json", Path.join(root, "alias.json"))
      assert {:ok, resolved} = ConfinedFile.resolve_absolute(Path.join(root, "alias.json"))
      assert Path.basename(resolved) == "manifest.json"
    end

    test "reports a missing path", %{root: root} do
      assert {:error, :not_found} = ConfinedFile.resolve_absolute(Path.join(root, "absent"))
    end
  end

  describe "trusted loading no longer depends on the public provider" do
    test "the manifest loader does not reference FileCapability" do
      source = File.read!("lib/ptc_runner/kernel/manifest.ex")
      refute source =~ "FileCapability"
    end
  end
end
