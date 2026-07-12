defmodule PtcRunner.Lisp.TypeVocabularyTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.TypeVocabulary

  doctest PtcRunner.Lisp.TypeVocabulary

  test "native function combinators render as functions" do
    assert TypeVocabulary.type_of({:juxt_fn, []}) == "fn"
    assert TypeVocabulary.type_of({:comp_fn, []}) == "fn"
    assert TypeVocabulary.type_of({:complement_fn, :f}) == "fn"
    assert TypeVocabulary.type_of({:constantly_fn, 1}) == "fn"
    assert TypeVocabulary.type_of({:every_pred_fn, []}) == "fn"
    assert TypeVocabulary.type_of({:some_fn, []}) == "fn"
    assert TypeVocabulary.type_of({:partial_fn, :f, []}) == "fn"
    assert TypeVocabulary.type_of({:fnil_fn, :f, nil}) == "fn"
  end
end
