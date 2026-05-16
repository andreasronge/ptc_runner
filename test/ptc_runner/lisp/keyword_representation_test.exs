defmodule PtcRunner.Lisp.KeywordRepresentationTest do
  @moduledoc """
  Regression tests for [#964](https://github.com/andreasronge/ptc_runner/issues/964).

  A source keyword is externalized into `Step.return` / `Step.memory`
  *deterministically*: names in the bounded `SourceAtoms` vocabulary become
  atoms, everything else becomes a plain binary. The representation must never
  depend on whether the name happens to exist in the global VM atom table.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  # Force the atom to exist before evaluation. Pre-#964, externalization
  # consulted `String.to_existing_atom/1`, so a pre-existing atom made the
  # same source keyword collapse to an atom instead of a deterministic binary.
  _ = String.to_atom("kw964probe")

  test "a novel keyword externalizes to a deterministic binary, never an atom" do
    {:ok, %{return: result}} = Lisp.run("{:kw964probe 1}")

    assert result == %{"kw964probe" => 1}
    refute Map.has_key?(result, :kw964probe)
  end

  test "(keyword name) and a literal keyword produce the identical representation" do
    {:ok, %{return: literal}} = Lisp.run(":kw964probe")
    {:ok, %{return: coerced}} = Lisp.run(~s|(keyword "kw964probe")|)

    assert literal == "kw964probe"
    assert coerced == literal
  end

  test "a keyword is the same value bare and as a map key" do
    {:ok, %{return: [bare, map]}} = Lisp.run("[:kw964probe {:kw964probe 1}]")

    assert [key] = Map.keys(map)
    assert bare == key
  end

  test "a novel keyword survives a memory round-trip unchanged" do
    {:ok, %{memory: memory}} = Lisp.run("(def saved {:kw964probe 1})")
    {:ok, %{return: result}} = Lisp.run("saved", memory: memory)

    assert result == %{"kw964probe" => 1}
  end

  test "lookups still resolve regardless of the externalized key shape" do
    # The runtime keeps keywords as structs internally; flex access stays
    # tolerant, so `(:kw m)` resolves even though the map externalizes to
    # a binary key.
    {:ok, %{return: result}} = Lisp.run("(:kw964probe {:kw964probe 7})")

    assert result == 7
  end
end
