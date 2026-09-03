defmodule PtcRunner.Kernel.EvaluatorEvidenceTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Error
  alias PtcRunner.Kernel.EvaluatorEvidence

  test "direct evaluator failures publish admitted kind and message on normal envelopes" do
    error = %Error{
      kind: :evaluation_failed,
      reason: :arithmetic_error,
      details: %{token: :division_by_zero},
      usage: %{}
    }

    assert EvaluatorEvidence.envelope_value(:normal, error) == %{
             "kind" => "arithmetic_error",
             "message" => "division by zero"
           }

    assert EvaluatorEvidence.envelope_value(:private, error) == nil

    assert EvaluatorEvidence.envelope_value(:normal, %{
             error
             | details: %{message: "division by zero"}
           }) == nil
  end

  test "turn-limit evidence requires Kernel-owned last evaluator failure" do
    java = %Error{
      kind: :workflow_failed,
      reason: :runtime_limit_exceeded,
      details: %{
        limit: :agent_turns,
        limit_value: 4,
        limit_reason: :evaluation_error,
        last_evaluator_failure: %{kind: :java_type_error, details: %{}}
      },
      usage: %{}
    }

    assert %{"kind" => "java_type_error", "message" => message} =
             EvaluatorEvidence.envelope_value(:normal, java)

    refute message =~ "overload_3"
    refute message =~ "PtcRunner"
    assert EvaluatorEvidence.envelope_value(:private, java) == nil

    protocol = %{java | details: Map.delete(java.details, :last_evaluator_failure)}
    assert EvaluatorEvidence.envelope_value(:normal, protocol) == nil

    explicit = %Error{
      kind: :workflow_failed,
      reason: :explicit_failure,
      details: %{value: %{"secret" => "must-not-escape"}},
      usage: %{}
    }

    assert EvaluatorEvidence.envelope_value(:normal, explicit) == nil
  end

  test "authenticated turn-limit type evidence is fixed while protocol exhaustion stays null" do
    type_error = %Error{
      kind: :workflow_failed,
      reason: :runtime_limit_exceeded,
      details: %{
        limit: :agent_turns,
        limit_value: 1,
        limit_reason: :evaluation_error,
        last_evaluator_failure: %{
          kind: :type_error,
          details: %{message: "count SECRET", origin: "main/run", rejected: 5}
        }
      },
      usage: %{}
    }

    assert EvaluatorEvidence.envelope_value(:normal, type_error) == %{
             "kind" => "type_error",
             "message" => "a PTC-Lisp operation received a value of the wrong type"
           }

    protocol = put_in(type_error.details.limit_reason, :protocol_error)
    assert EvaluatorEvidence.envelope_value(:normal, protocol) == nil
  end
end
