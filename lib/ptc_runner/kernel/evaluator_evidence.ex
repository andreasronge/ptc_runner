defmodule PtcRunner.Kernel.EvaluatorEvidence do
  @moduledoc false

  alias PtcRunner.Kernel.Error
  alias PtcRunner.Lisp.EvaluatorError
  alias PtcRunner.Lisp.EvaluatorErrorCatalog

  @spec envelope_value(:normal | :private, Error.t()) :: map() | nil
  def envelope_value(:private, %Error{}), do: nil

  def envelope_value(:normal, %Error{kind: :evaluation_failed, reason: reason, details: details}) do
    render(reason, details)
  end

  def envelope_value(
        :normal,
        %Error{
          kind: :workflow_failed,
          reason: :runtime_limit_exceeded,
          details: details
        }
      ) do
    authenticated_turn_limit_evidence(details)
  end

  def envelope_value(_result_class, _error), do: nil

  defp authenticated_turn_limit_evidence(%{
         limit: :agent_turns,
         limit_reason: :evaluation_error,
         last_evaluator_failure: %{kind: kind, details: details}
       })
       when is_map(details) do
    render(kind, details)
  end

  defp authenticated_turn_limit_evidence(_details), do: nil

  defp render(reason, details) when is_map(details) do
    if EvaluatorErrorCatalog.kind?(reason) do
      case EvaluatorError.envelope_value(reason, details) do
        {:ok, value} -> value
        :error -> nil
      end
    else
      nil
    end
  end

  defp render(_reason, _details), do: nil
end
