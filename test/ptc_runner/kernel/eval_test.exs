defmodule PtcRunner.Kernel.EvalTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.Eval

  test "mini suite mock mode reports deterministic per-case counts" do
    assert {:ok, report} = Eval.run(suite: "mini", mode: :mock)

    assert report.suite == "mini"
    assert report.mode == :mock
    assert report.model == nil
    assert length(report.cases) == 5
    assert Enum.all?(report.cases, &(&1.status == :pass))
    assert Eval.passed?(report)
    assert Eval.failure_count(report) == 0

    assert Map.new(report.cases, &{&1.case, &1.value}) == %{
             "arithmetic" => 42,
             "context_filter_count" => 2,
             "context_aggregation" => 12,
             "domain_tool" => 9,
             "eval_retry" => 3
           }

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

  test "unknown case fails instead of producing an empty passing report" do
    assert {:error, {:unknown_case, "missing"}} =
             Eval.run(suite: "mini", mode: :mock, case: "missing")
  end

  test "mock cases fail when returned value does not match expected value" do
    wrong_case = %{
      id: "wrong_answer",
      task: "Return the integer result of 40 + 2.",
      context: %{},
      expected: 42,
      max_turns: 3,
      mock_programs: [~S|(return 0)|]
    }

    assert {:ok, report} = Eval.run_cases([wrong_case], mode: :mock)
    assert [case_result] = report.cases
    assert case_result.status == :fail
    assert case_result.value == 0
    assert case_result.failure_reason =~ "expected_mismatch"
    refute Eval.passed?(report)
    assert Eval.failure_count(report) == 1
  end

  test "live mode reports provider-specific missing key" do
    previous_env = System.get_env("OPENAI_API_KEY")
    previous_config = Application.get_env(:req_llm, :openai_api_key)

    System.delete_env("OPENAI_API_KEY")
    Application.delete_env(:req_llm, :openai_api_key)

    on_exit(fn ->
      restore_env("OPENAI_API_KEY", previous_env)
      restore_config(:openai_api_key, previous_config)
    end)

    assert {:error, {:missing_api_key, "OPENAI_API_KEY", "openai:gpt-4.1-mini"}} =
             Eval.run(suite: "mini", mode: :live, model: "openai:gpt")
  end

  test "bedrock live preflight requires bearer token or AWS key pair" do
    keys = [
      "AWS_BEARER_TOKEN_BEDROCK",
      "AWS_ACCESS_KEY_ID",
      "AWS_SECRET_ACCESS_KEY",
      "AWS_SESSION_TOKEN"
    ]

    previous = Map.new(keys, &{&1, System.get_env(&1)})

    Enum.each(keys, &System.delete_env/1)
    System.put_env("AWS_ACCESS_KEY_ID", "access-only")

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
    end)

    assert {:error,
            {:missing_api_key,
             "AWS_BEARER_TOKEN_BEDROCK or AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY",
             "amazon_bedrock:anthropic.claude-haiku-4-5-20251001-v1:0"}} =
             Eval.run(suite: "mini", mode: :live, model: "bedrock:haiku")
  end

  defp restore_env(_key, nil), do: :ok
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_config(_key, nil), do: :ok
  defp restore_config(key, value), do: Application.put_env(:req_llm, key, value)
end
