defmodule PtcRunner.Lisp.Eval.Abort do
  @moduledoc false

  alias PtcRunner.Lisp.Eval.Context
  alias PtcRunner.Lisp.Eval.Outcome

  defexception [:outcome, message: "expected evaluator abort"]

  @type t :: %__MODULE__{outcome: Outcome.t(), message: String.t()}

  @spec error!(term(), Context.t()) :: no_return()
  def error!(reason, %Context{} = context),
    do: raise(__MODULE__, outcome: Outcome.error(reason, context))

  @spec control!(Outcome.control(), term(), Context.t()) :: no_return()
  def control!(signal, value, %Context{} = context),
    do: raise(__MODULE__, outcome: Outcome.control(signal, value, context))

  @impl true
  def exception(attrs) when is_list(attrs) do
    outcome = Keyword.fetch!(attrs, :outcome)
    %__MODULE__{outcome: outcome, message: "expected evaluator abort: #{outcome_label(outcome)}"}
  end

  defp outcome_label({:error, reason, _context}), do: inspect(reason)
  defp outcome_label({:control, signal, _value, _context}), do: Atom.to_string(signal)
  defp outcome_label({:ok, _value, _context}), do: "ok"
end
