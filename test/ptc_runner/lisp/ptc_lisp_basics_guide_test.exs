defmodule PtcRunner.Lisp.PtcLispBasicsGuideTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.SpecValidator
  alias PtcRunner.Lisp.SpecValidator.Parser

  @guide_path "docs/guides/ptc-lisp-basics.md"

  # The guide promises "every example below is validated against the
  # interpreter". This test is that promise: each `; =>` example runs
  # standalone through the same validator the specification uses.
  test "every example in the PTC-Lisp basics guide returns what it claims" do
    extracted = @guide_path |> File.read!() |> Parser.extract_examples()

    # Extraction silently returning nothing would make this test pass while
    # verifying no promise at all.
    assert length(extracted.examples) >= 20,
           "expected the guide to carry at least 20 verifiable examples, " <>
             "got #{length(extracted.examples)}"

    assert extracted.todos == []
    assert extracted.bugs == []

    for {code, expected, _section} <- extracted.examples do
      assert SpecValidator.validate_example(code, expected) == :ok,
             "guide example does not return what it claims:\n#{code}"
    end
  end
end
