defmodule PtcRunner.Lisp.Prelude.CompilerAtomGrowthTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Lisp.Prelude.Compiler

  @source """
  (ns atom-safe)

  (defn choose [value]
    (case value
      :first 1
      :second 2
      0))
  """

  test "repeated conditional compilation does not grow the atom table" do
    assert {:ok, _prelude} = Compiler.compile(@source)
    before = :erlang.system_info(:atom_count)

    for _iteration <- 1..25 do
      assert {:ok, _prelude} = Compiler.compile(@source)
    end

    assert :erlang.system_info(:atom_count) == before
  end
end
