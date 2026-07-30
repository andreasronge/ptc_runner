defmodule PtcRunner.Kernel.ResultArtifactTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.ResultArtifact
  alias PtcRunner.Lisp.Format

  @tag :tmp_dir
  test "persists the same canonical bytes used by run result hashes", %{tmp_dir: dir} do
    value = %{"z" => [3, 2, 1], "a" => %{"b" => true}}
    path = Path.join(dir, "result.json")

    assert :ok = ResultArtifact.persist(path, value, :normal, :normal)
    assert {:ok, canonical} = DeterministicJSON.encode(value)
    assert File.read!(path) == canonical
  end

  @tag :tmp_dir
  test "persists quoted-symbol display wrappers with their canonical JSON spelling", %{
    tmp_dir: dir
  } do
    symbol = %Format.SymbolRef{name: "foo"}
    value = %{symbol => symbol}
    path = Path.join(dir, "quoted-symbol.json")

    assert :ok = ResultArtifact.persist(path, value, :normal, :normal)
    assert File.read!(path) == ~S|{"'foo":"'foo"}|

    assert {:error, :duplicate_key} =
             DeterministicJSON.encode(%{symbol => 1, "'foo" => 2})

    malformed_wrappers = [
      %Format.SymbolRef{name: %{}},
      %Format.SymbolRef{name: <<0xFF>>},
      %{__struct__: Format.SymbolRef, name: "foo", extra: "must-not-be-dropped"}
    ]

    for malformed <- malformed_wrappers do
      assert {:error, :invalid_json} = DeterministicJSON.encode(malformed)
      assert {:error, :invalid_json} = DeterministicJSON.encode(%{malformed => 1})
    end
  end

  @tag :tmp_dir
  test "rejects improper JSON arrays without raising", %{tmp_dir: dir} do
    malformed = [1 | 2]

    assert {:error, :invalid_json} = DeterministicJSON.encode(malformed)
    assert {:error, :invalid_json} = DeterministicJSON.encode({:object, [{"x", 1} | 2]})

    assert {:error, {:result_not_json_encodable, :array}} =
             ResultArtifact.persist(
               Path.join(dir, "improper-list.json"),
               malformed,
               :normal,
               :normal
             )
  end
end
