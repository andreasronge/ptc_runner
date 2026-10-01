defmodule PtcRunner.Lisp.BuiltinDiagnosticTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.PrivateDiagnostic
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp.BuiltinDiagnostic
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.TestSupport.StreamingInspection

  test "private argument values are absent from execution inspection records" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new(data: %{"secret" => "sekrit-value"})
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:private, limits, run_id: "builtin-diagnostic")

    {:ok, inspection} =
      StreamingInspection.start(run_id: "builtin-diagnostic", trace_id: "builtin-diagnostic")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink,
        inspection_sink: inspection
      )

    mode = %{kind: :mission, name: "default", component_ids: [], direct_provider_aliases: []}
    {:ok, session} = ReplSession.new(config: config, mode: mode)

    assert {:error, %{fail: %{reason: :type_error, message: message}}, session} =
             ReplSession.eval(session, ~S|(get-in data/secret ["a" 0])|)

    assert message == "type_error: get-in: arg 1 expected associative, got string"
    assert {:ok, records} = StreamingInspection.records(inspection)
    assert Enum.any?(records, &(&1["record_type"] == "execution-error"))
    refute Jason.encode!(records) =~ "sekrit-value"
    assert {:ok, events} = ReplSession.close(session)
    refute inspect(events) =~ "sekrit-value"
    InspectionSink.stop(inspection)
  end

  test "type descriptions have only literal return paths" do
    source = File.read!("lib/ptc_runner/lisp/eval/helpers.ex")
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, bodies} =
      Macro.prewalk(ast, [], fn
        {definition, _, [head, [do: body]]} = node, bodies when definition in [:def, :defp] ->
          head =
            case head do
              {:when, _, [head | _]} -> head
              head -> head
            end

          case head do
            {:describe_type, _, [_]} ->
              {node, [{:type, body} | bodies]}

            {:java_object_description, _, [_, _, {:label, _, context}]} when is_atom(context) ->
              {node, [{:java_type, body} | bodies]}

            {:java_object_description, _, _} ->
              flunk("unexpected Java type helper shape")

            _ ->
              {node, bodies}
          end

        node, bodies ->
          {node, bodies}
      end)

    assert Enum.count(bodies, &(elem(&1, 0) == :type)) > 20
    assert Enum.any?(bodies, &(elem(&1, 0) == :java_type))

    Enum.each(bodies, fn
      {:type, body} -> assert_literal_type_return(body)
      {:java_type, body} -> assert_literal_type_return(body, true)
    end)
  end

  test "admitted runtime diagnostics ignore poisoned evaluator prose" do
    details = %{
      message: "sekrit-value",
      safe_diagnostic: %{
        kind: :builtin_argument,
        name: "count",
        index: 1,
        expected: "seqable",
        actual: "number"
      }
    }

    assert {"type_error: count: arg 1 expected seqable, got number", false} ==
             PrivateDiagnostic.project(:type_error, details, "(count 42)")

    arity = %{message: "sekrit-value", name: "count", expected: 1, actual: 0}

    assert {"arity error: count expects 1 argument(s), got 0", false} ==
             PrivateDiagnostic.project(:arity_error, arity, "(count)")
  end

  test "unstructured and malformed runtime faults stay withheld" do
    for details <- [
          %{message: "count: arg 1 expected seqable, got secret"},
          %{
            safe_diagnostic: %{
              kind: :builtin_argument,
              name: "secret",
              index: 1,
              expected: "seqable",
              actual: "number"
            }
          },
          %{safe_diagnostic: %{kind: :builtin_types, name: "count", types: ["secret"]}},
          %{
            safe_diagnostic: %{
              kind: :builtin_types,
              name: "count",
              types: ["number"],
              extra: "secret"
            }
          },
          %{
            safe_diagnostic: %{
              kind: :builtin_argument,
              name: "count",
              index: 1,
              expected: "secret",
              actual: "number"
            }
          }
        ] do
      assert {PrivateDiagnostic.redacted_message(), true} ==
               PrivateDiagnostic.project(:type_error, details, "(count 42)")
    end
  end

  test "fallback type errors rebuild and private prelude sanitization removes their selector" do
    reason = Helpers.type_error_for_args(&PtcRunner.Lisp.Runtime.String.subs/3, [42, 0, 1])
    assert {:type_error, _message, {:safe_diagnostic, diagnostic}} = reason

    assert {:ok, "subs: invalid argument types: number, number, number"} =
             BuiltinDiagnostic.message(diagnostic)

    assert {:type_error, _message, nil} =
             Helpers.sanitize_private_error(reason, %{ref: "private/run"})
  end

  defp assert_literal_type_return(body, allow_label? \\ false)

  defp assert_literal_type_return(literal, _allow_label?) when is_binary(literal),
    do: assert(literal in Helpers.safe_type_names())

  defp assert_literal_type_return({:label, _, context}, true) when is_atom(context), do: :ok

  defp assert_literal_type_return({:if, _, [_condition, branches]}, allow_label?) do
    assert_literal_type_return(Keyword.fetch!(branches, :do), allow_label?)
    assert_literal_type_return(Keyword.fetch!(branches, :else), allow_label?)
  end

  defp assert_literal_type_return({:java_object_description, _, [_module, _value, label]}, false) do
    assert is_binary(label)
    assert label in Helpers.safe_type_names()
  end

  defp assert_literal_type_return(other, _allow_label?),
    do: flunk("type description gained a nonliteral return path: #{Macro.to_string(other)}")
end
