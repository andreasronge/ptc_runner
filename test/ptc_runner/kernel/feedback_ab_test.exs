defmodule PtcRunner.Kernel.FeedbackABTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.FeedbackAB

  test "mock shakedown validates frozen provenance and reports both cells" do
    assert {:ok, result} = FeedbackAB.run(mode: :mock, runs: 1, case: "eval_retry")

    assert result.suite == "mini"
    assert result.mode == :mock
    assert result.model == nil
    assert result.seed == "s19-feedback-ab-order-v1"
    assert length(result.cells) == 3
    assert length(result.rows) == 3
    assert Enum.sort(Enum.map(result.rows, & &1.cell)) == ["A", "B", "C"]
    assert Enum.all?(result.rows, &(&1.case == "eval_retry"))
    assert Enum.all?(result.rows, &(&1.status == :pass))
    assert FeedbackAB.passed?(result)
    assert FeedbackAB.failure_count(result) == 0

    hashes = Map.new(result.rows, &{&1.cell, {&1.prompt_hash, &1.feedback_hash}})

    assert hashes == %{
             "A" =>
               {"82bcd82d41d84580466531351c8750214a9945ef5bd5492da52742a82da0d746",
                "b220eb0b285e2d4bae6454889f8b90d893dc3dc017b6c9e28fabee9b951ae474"},
             "B" =>
               {"82bcd82d41d84580466531351c8750214a9945ef5bd5492da52742a82da0d746",
                "ef9bd2769fc404feed1db14e1de2923b4f6105f325b073cb0632c046f522eafe"},
             "C" =>
               {"82bcd82d41d84580466531351c8750214a9945ef5bd5492da52742a82da0d746",
                "f9fa94089cb08d86a2de97d17047f5f48c7228b8176328ee77757578e1b5a223"}
           }
  end

  test "markdown report is sanitized and labels the result as descriptive" do
    assert {:ok, result} = FeedbackAB.run(mode: :mock, runs: 1, case: "eval_retry")

    markdown = FeedbackAB.render_markdown(result)

    assert markdown =~ "non-M3 descriptive shakedown"
    assert markdown =~ "Canonical TurnEvents may be available for"
    assert markdown =~ "does not supply the preregistered M3 sample"
    assert markdown =~ "| A |"
    assert markdown =~ "| B |"
    assert markdown =~ "| C |"
    refute markdown =~ "(return 3)"
    refute markdown =~ "(defn eval-feedback"
    refute markdown =~ "Previous PTC-Lisp program did not return successfully"
    refute markdown =~ "PTC-Lisp is Clojure-like and runs as an interactive REPL"
    refute markdown =~ "Use value symbols directly"
  end

  test "invalid run setup returns a structured error" do
    assert {:error, {:unknown_case, "missing"}} =
             FeedbackAB.run(mode: :mock, runs: 1, case: "missing")
  end
end
