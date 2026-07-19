defmodule PtcRunner.Lisp.Eval.Outcome do
  @moduledoc false

  alias PtcRunner.Lisp.Eval.Context

  @type control :: :return | :fail | :recur
  @type t ::
          {:ok, term(), Context.t()}
          | {:error, term(), Context.t()}
          | {:control, control(), term(), Context.t()}

  @spec ok(term(), Context.t()) :: t()
  def ok(value, %Context{} = context), do: {:ok, value, context}

  @spec error(term(), Context.t()) :: t()
  def error(reason, %Context{} = context), do: {:error, reason, context}

  @spec control(control(), term(), Context.t()) :: t()
  def control(signal, value, %Context{} = context)
      when signal in [:return, :fail, :recur],
      do: {:control, signal, value, context}
end
