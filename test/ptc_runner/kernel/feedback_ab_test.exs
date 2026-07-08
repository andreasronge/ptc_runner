defmodule PtcRunner.Kernel.FeedbackABTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.FeedbackAB

  test "mock shakedown validates frozen provenance and reports both cells" do
    assert {:ok, result} = FeedbackAB.run(mode: :mock, runs: 1, case: "eval_retry")

    assert result.suite == "mini"
    assert result.mode == :mock
    assert result.model == nil
    assert result.seed == "s19-feedback-ab-order-v1"
    assert length(result.cells) == 2
    assert length(result.rows) == 2
    assert Enum.sort(Enum.map(result.rows, & &1.cell)) == ["A", "B"]
    assert Enum.all?(result.rows, &(&1.case == "eval_retry"))
    assert Enum.all?(result.rows, &(&1.status == :pass))
    assert FeedbackAB.passed?(result)
    assert FeedbackAB.failure_count(result) == 0

    hashes = Map.new(result.rows, &{&1.cell, &1.feedback_hash})

    assert hashes == %{
             "A" => "b220eb0b285e2d4bae6454889f8b90d893dc3dc017b6c9e28fabee9b951ae474",
             "B" => "ef9bd2769fc404feed1db14e1de2923b4f6105f325b073cb0632c046f522eafe"
           }
  end

  test "markdown report is sanitized and labels the result as descriptive" do
    assert {:ok, result} = FeedbackAB.run(mode: :mock, runs: 1, case: "eval_retry")

    markdown = FeedbackAB.render_markdown(result)

    assert markdown =~ "non-M3 descriptive shakedown"
    assert markdown =~ "D4 canonical TurnEvents are not present"
    assert markdown =~ "| A |"
    assert markdown =~ "| B |"
    refute markdown =~ "(return 3)"
    refute markdown =~ "(defn eval-feedback"
    refute markdown =~ "Previous PTC-Lisp program did not return successfully"
  end

  test "invalid run setup returns a structured error" do
    assert {:error, {:unknown_case, "missing"}} =
             FeedbackAB.run(mode: :mock, runs: 1, case: "missing")
  end
end
