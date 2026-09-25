defmodule PtcRunner.Kernel.ArtifactPruneTransactionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ArtifactPruneTransaction

  @tag :tmp_dir
  test "a later unlink failure restores an already removed trace", %{tmp_dir: root} do
    File.chmod!(root, 0o700)
    trace = Path.join(root, "old.jsonl")
    result = Path.join(root, "old.json")
    File.write!(trace, "trace")
    File.write!(result, "result")
    artifacts = for path <- [trace, result], do: {path, File.lstat!(path, time: :posix)}

    unlink = fn path, _stat ->
      if path == trace, do: File.rm(path), else: {:error, :eacces}
    end

    assert {:error, :delete_failed} = ArtifactPruneTransaction.delete(artifacts, root, unlink)
    assert File.read!(trace) == "trace"
    assert File.read!(result) == "result"
    refute Enum.any?(File.ls!(root), &String.starts_with?(&1, ".ptc-prune-"))
  end
end
