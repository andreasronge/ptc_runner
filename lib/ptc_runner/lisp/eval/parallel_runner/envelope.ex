defmodule PtcRunner.Lisp.Eval.ParallelRunner.Envelope do
  @moduledoc """
  One indexed result returned by `PtcRunner.Lisp.Eval.ParallelRunner`.

  Worker callbacks construct an unindexed envelope. The runner overwrites the
  index from its own scheduling state before the envelope crosses the worker
  boundary, making that index authoritative for ordering and failure reports.
  """

  alias PtcRunner.Lisp.Eval.Effects

  defstruct index: nil,
            outcome: nil,
            child_trace_id: nil,
            child_step: nil,
            effects: %Effects{}

  @type outcome :: {:ok, term()} | {:error, term()}

  @type t :: %__MODULE__{
          index: non_neg_integer() | nil,
          outcome: outcome(),
          child_trace_id: term() | nil,
          child_step: term() | nil,
          effects: Effects.t()
        }

  @spec success(term(), keyword()) :: t()
  def success(value, opts \\ []) do
    build({:ok, value}, opts)
  end

  @spec failure(term(), keyword()) :: t()
  def failure(reason, opts \\ []) do
    build({:error, reason}, opts)
  end

  @doc false
  @spec attach_index(t(), non_neg_integer()) :: t()
  def attach_index(%__MODULE__{} = envelope, index)
      when is_integer(index) and index >= 0 do
    %{envelope | index: index}
  end

  @spec success?(t()) :: boolean()
  def success?(%__MODULE__{outcome: {:ok, _value}}), do: true
  def success?(%__MODULE__{}), do: false

  defp build(outcome, opts) do
    %__MODULE__{
      outcome: outcome,
      child_trace_id: Keyword.get(opts, :child_trace_id),
      child_step: Keyword.get(opts, :child_step),
      effects: Keyword.get(opts, :effects, Effects.empty())
    }
  end
end
