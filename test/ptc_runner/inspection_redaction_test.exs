defmodule PtcRunner.InspectionRedactionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  require Logger

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.Program
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Lisp.Analyze
  alias PtcRunner.Lisp.Eval
  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Parser
  alias PtcRunner.Lisp.Result
  alias PtcRunner.Lisp.RuntimeCallable

  @sentinels [
    "RETURN_SECRET_7f31",
    "FAIL_SECRET_a92c",
    "MEMORY_SECRET_18de",
    "PROMPT_SECRET_f650",
    "TOOL_SECRET_63b1",
    "CHILD_SECRET_b48a",
    "SOURCE_SECRET_d227",
    "CONTEXT_SECRET_914e"
  ]

  test "payload-bearing structs inspect as bounded metadata without retained values" do
    result = sensitive_result()
    program = Program.new("(return \"SOURCE_SECRET_d227\")")
    callable = sensitive_callable("search")

    rendered = Enum.map_join([result, program, callable], "\n", &inspect/1)

    assert rendered =~ "#PtcRunner.Lisp.Result<"
    assert rendered =~ "memory_entries: 1"
    assert rendered =~ "tool_calls: 1"
    assert rendered =~ "child_steps: 1"
    assert rendered =~ "#PtcRunner.Kernel.Program<"
    assert rendered =~ "byte_size:"
    assert rendered =~ program.digest
    assert rendered =~ "#PtcRunner.Lisp.RuntimeCallable<"
    assert rendered =~ "label: tool/search"
    assert rendered =~ "bound?: true"

    refute_sentinels(rendered)
  end

  test "Logger messages built from Inspect use the same redacted boundary" do
    values = [
      sensitive_result(),
      Program.new("SOURCE_SECRET_d227"),
      sensitive_callable("search")
    ]

    log =
      capture_log([level: :debug], fn ->
        Logger.critical(fn -> Enum.map_join(values, " ", &inspect/1) end)
      end)

    assert log =~ "#PtcRunner.Lisp.Result<"
    assert log =~ "#PtcRunner.Kernel.Program<"
    assert log =~ "#PtcRunner.Lisp.RuntimeCallable<"
    refute_sentinels(log)
  end

  test "runtime callable inspection accepts parsed binary tool names only when valid" do
    assert {:ok, parsed} = Parser.parse("tool/custom-search")
    assert {:ok, core} = Analyze.analyze(parsed)
    assert {:ok, callable, %{}} = Eval.eval(core, %{}, %{}, %{}, fn _, _ -> nil end)

    assert inspect(callable) =~
             "label: tool/custom-search, bound?: false"

    invalid = RuntimeCallable.new(:tool, "CONTEXT_SECRET_914e")
    assert inspect(invalid) =~ "label: invalid"
    refute_sentinels(inspect(invalid))
  end

  test "redacted inspection contains malformed struct fields without raising" do
    malformed_result = %Result{memory: nil, turns: [1 | 2], prints: "PROMPT_SECRET_f650"}

    malformed_program = %Program{
      source: "SOURCE_SECRET_d227",
      byte_size: -1,
      digest: :binary.copy(<<255>>, 64)
    }

    malformed_callable = %RuntimeCallable{namespace: :tool, name: <<255>>}

    rendered =
      Enum.map_join([malformed_result, malformed_program, malformed_callable], &inspect/1)

    assert rendered =~ "unknown"
    assert rendered =~ "digest: invalid"
    assert rendered =~ "label: invalid"
    refute_sentinels(rendered)
  end

  test "owner format_status does not enumerate continuation payloads" do
    {:ok, state} = RunState.start(Limits.defaults())
    {:ok, _memory, _history, lease} = RunState.reserve_evaluation(state)

    assert :ok =
             RunState.commit_evaluation(
               state,
               lease,
               %{"value" => "MEMORY_SECRET_18de"},
               ["CHILD_SECRET_b48a"]
             )

    status = state.pid |> :sys.get_status() |> inspect()
    refute_sentinels(status)
  end

  defp sensitive_result do
    %Result{
      return: "RETURN_SECRET_7f31",
      fail: %{
        reason: :runtime_error,
        message: "FAIL_SECRET_a92c",
        details: %{"prompt" => "PROMPT_SECRET_f650"}
      },
      memory: %{"MEMORY_SECRET_18de" => "RETURN_SECRET_7f31"},
      signature: "PROMPT_SECRET_f650",
      usage: %{tool_calls: 1},
      turns: ["RETURN_SECRET_7f31"],
      trace_id: "PROMPT_SECRET_f650",
      parent_trace_id: "FAIL_SECRET_a92c",
      name: "RETURN_SECRET_7f31",
      field_descriptions: %{"value" => "PROMPT_SECRET_f650"},
      prints: ["PROMPT_SECRET_f650"],
      tool_calls: [%{args: "TOOL_SECRET_63b1", result: "RETURN_SECRET_7f31"}],
      pmap_calls: [%{child_steps: ["CHILD_SECRET_b48a"]}],
      child_traces: ["PROMPT_SECRET_f650"],
      child_steps: [%Result{return: "CHILD_SECRET_b48a"}],
      messages: [%{"content" => "PROMPT_SECRET_f650"}],
      prompt: "PROMPT_SECRET_f650",
      original_prompt: "PROMPT_SECRET_f650",
      tools: %{"TOOL_SECRET_63b1" => fn _ -> :ok end},
      prelude_trace: %{component_ids: ["PROMPT_SECRET_f650"]},
      prelude_call_counts: %{"TOOL_SECRET_63b1" => 1}
    }
  end

  defp sensitive_callable(name) do
    eval_ctx =
      EvalContext.new(
        %{"CONTEXT_SECRET_914e" => true},
        %{},
        %{},
        fn _, _, _ -> "TOOL_SECRET_63b1" end,
        ["CHILD_SECRET_b48a"]
      )

    :tool
    |> RuntimeCallable.new(name)
    |> RuntimeCallable.bind(eval_ctx, fn _, _ -> {:ok, "RETURN_SECRET_7f31", eval_ctx} end)
  end

  defp refute_sentinels(rendered) do
    Enum.each(@sentinels, fn sentinel ->
      refute rendered =~ sentinel
    end)
  end
end
