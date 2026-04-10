defmodule PtcRunner.Folding.ChallengeSpec do
  @moduledoc """
  Structured challenge specification for interactive coevolution.

  Testers produce challenge specs that modify data contexts. A constrained
  set of transformation operators prevents degenerate challenges while still
  allowing targeted testing of solver weaknesses.
  """

  @type op :: :filter | :truncate | :inject_nulls | :swap_field | :scale_values | :identity

  @type t :: %__MODULE__{
          op: op(),
          source: atom(),
          params: map()
        }

  defstruct [:op, :source, params: %{}]

  @ops [:filter, :truncate, :inject_nulls, :swap_field, :scale_values, :identity]
  @sources [:products, :employees, :orders, :expenses]

  @fields [
    :price,
    :status,
    :department,
    :id,
    :name,
    :amount,
    :category,
    :employee_id,
    :stock,
    :salary,
    :total,
    :quantity
  ]
  @comparators [:>, :<, :=]

  @doc "All valid challenge operations."
  @spec ops() :: [op()]
  def ops, do: @ops

  @doc "All valid data sources."
  @spec sources() :: [atom()]
  def sources, do: @sources

  @doc "All valid field names."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc "All valid comparison operators."
  @spec comparators() :: [atom()]
  def comparators, do: @comparators

  @doc """
  Check if a challenge spec is valid.

  Validates that op, source, and params are within the allowed ranges.
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{op: op, source: source, params: params}) do
    op in @ops and source in @sources and valid_params?(op, params)
  end

  def valid?(_), do: false

  defp valid_params?(:filter, %{field: f, cmp: c, value: v}),
    do: f in @fields and c in @comparators and is_number(v)

  defp valid_params?(:truncate, %{count: c}),
    do: is_integer(c) and c >= 1

  defp valid_params?(:inject_nulls, %{field: f, fraction: frac}),
    do: f in @fields and is_float(frac) and frac >= 0.1 and frac <= 0.5

  defp valid_params?(:swap_field, %{from: f, to: t}),
    do: f in @fields and t in @fields and f != t

  defp valid_params?(:scale_values, %{field: f, factor: fac}),
    do: f in @fields and is_number(fac) and fac >= 0.1 and fac <= 10.0

  defp valid_params?(:identity, params), do: params == %{}
  defp valid_params?(_, _), do: false
end
