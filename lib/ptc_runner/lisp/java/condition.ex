defmodule PtcRunner.Lisp.Java.Condition do
  @moduledoc """
  Bounded recoverable failure produced by closed Java dispatch.

  Conditions carry manifest identities and inert diagnostic metadata only. Raw
  handler values, exceptions, and stacktraces never become Lisp data.
  """

  @enforce_keys [:category, :reference_id, :message, :details]
  defstruct [:category, :reference_id, :overload_id, :message, :details]

  @type category ::
          :unsupported_java_class
          | :unsupported_java_member
          | :java_arity_error
          | :java_type_error
          | :java_domain_error
          | :invalid_java_string
          | :java_handler_contract_error

  @type t :: %__MODULE__{
          category: category(),
          reference_id: atom() | nil,
          overload_id: atom() | nil,
          message: String.t(),
          details: map()
        }

  @spec new(category(), atom() | nil, atom() | nil, String.t(), map()) :: t()
  def new(category, reference_id, overload_id, message, details \\ %{})
      when is_atom(category) and (is_atom(reference_id) or is_nil(reference_id)) and
             (is_atom(overload_id) or is_nil(overload_id)) and is_binary(message) and
             is_map(details) do
    %__MODULE__{
      category: category,
      reference_id: reference_id,
      overload_id: overload_id,
      message: message,
      details: details
    }
  end

  @doc false
  @spec evaluator_error(t()) :: {atom(), String.t(), map()}
  def evaluator_error(%__MODULE__{} = condition) do
    details =
      condition.details
      |> Map.put(:reference_id, condition.reference_id)
      |> maybe_put_overload(condition.overload_id)

    {condition.category, condition.message, details}
  end

  defp maybe_put_overload(details, nil), do: details
  defp maybe_put_overload(details, overload_id), do: Map.put(details, :overload_id, overload_id)
end
