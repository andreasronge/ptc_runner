defmodule PtcRunnerMcp.TraceFileTest do
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.TraceFile

  describe "request_id_hash8/1" do
    test "deterministic 8-hex-char digest" do
      h = TraceFile.request_id_hash8("req-1")
      assert byte_size(h) == 8
      assert h =~ ~r/^[0-9a-f]+$/
      assert h == TraceFile.request_id_hash8("req-1")
    end

    test "nil request_id maps to all-zero placeholder" do
      assert TraceFile.request_id_hash8(nil) == "00000000"
    end

    test "integer ids are stringified first" do
      assert TraceFile.request_id_hash8(42) == TraceFile.request_id_hash8("42")
    end
  end

  describe "build_path/3" do
    test "filename matches `<iso8601>-<hash8>-<status>.jsonl`" do
      path = TraceFile.build_path("/tmp", "req-1", :ok)
      basename = Path.basename(path)

      assert basename =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}.*Z-[0-9a-f]{8}-ok\.jsonl$/
    end

    test "error status appears in filename" do
      path = TraceFile.build_path("/tmp", "req-1", :error)
      assert Path.basename(path) =~ ~r/-error\.jsonl$/
    end
  end

  describe "rotate/2" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "ptc_mcp_trace_rotate_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "no-op when below cap", %{dir: dir} do
      for i <- 1..3 do
        File.write!(Path.join(dir, "f#{i}.jsonl"), "x")
      end

      :ok = TraceFile.rotate(dir, 5)
      assert length(File.ls!(dir)) == 3
    end

    test "evicts oldest by mtime when over cap", %{dir: dir} do
      # Create 5 files with distinct mtimes (1-second resolution on
      # most filesystems is enough for this test).
      now = System.os_time(:second)

      for i <- 1..5 do
        path = Path.join(dir, "f#{i}.jsonl")
        File.write!(path, "x")
        # Stagger mtimes so the order is deterministic.
        File.touch!(path, now - (5 - i) * 10)
      end

      # Cap of 3 → after rotate, only 2 files remain (we leave room
      # for the new one the caller is about to write).
      :ok = TraceFile.rotate(dir, 3)
      remaining = File.ls!(dir) |> Enum.sort()

      # The two newest by mtime are f4 and f5.
      assert remaining == ["f4.jsonl", "f5.jsonl"]
    end

    test "ignores non-jsonl files", %{dir: dir} do
      File.write!(Path.join(dir, "a.jsonl"), "x")
      File.write!(Path.join(dir, "b.jsonl"), "x")
      File.write!(Path.join(dir, "ignore.txt"), "x")

      :ok = TraceFile.rotate(dir, 1)

      remaining = File.ls!(dir) |> Enum.sort()
      assert "ignore.txt" in remaining
    end
  end

  describe "ensure_dir/1" do
    test "creates a missing directory" do
      dir =
        Path.join(System.tmp_dir!(), "ptc_mcp_trace_ensure_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(dir) end)
      refute File.exists?(dir)

      assert :ok = TraceFile.ensure_dir(dir)
      assert File.dir?(dir)
    end
  end
end
