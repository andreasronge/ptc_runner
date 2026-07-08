defmodule PtcRunner.Kernel.EvalTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Eval

  test "mini suite mock mode reports deterministic per-case counts" do
    assert {:ok, report} = Eval.run(suite: "mini", mode: :mock)

    assert report.suite == "mini"
    assert report.mode == :mock
    assert report.model == nil
    assert length(report.cases) == 5
    assert Enum.all?(report.cases, &(&1.status == :pass))

    retry = Enum.find(report.cases, &(&1.case == "eval_retry"))
    assert retry.action_count == 2
    assert retry.eval_count == 2

    for case_result <- report.cases -- [retry] do
      assert case_result.action_count == 1
      assert case_result.eval_count == 1
    end
  end

  test "default markdown report is sanitized" do
    assert {:ok, report} = Eval.run(suite: "mini", mode: :mock)

    markdown = Eval.render_markdown(report)

    assert markdown =~ "context_filter_count"
    assert markdown =~ "domain_tool"
    refute markdown =~ "OPENROUTER_API_KEY"
    refute markdown =~ "sk-or-"
    refute markdown =~ "You are controlling PTC-Lisp"
    refute markdown =~ "messages"
    refute markdown =~ "tool_calls"
    refute markdown =~ "(return (+ 40 2))"
  end

  test "model seam resolves aliases through the registry" do
    assert {:ok, "openrouter:deepseek/deepseek-v4-flash"} = Eval.resolve_model("deepseek")
  end
end
