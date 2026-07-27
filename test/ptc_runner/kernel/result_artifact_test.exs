defmodule PtcRunner.Kernel.ResultArtifactTest do
  use ExUnit.Case, async: true

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
end
