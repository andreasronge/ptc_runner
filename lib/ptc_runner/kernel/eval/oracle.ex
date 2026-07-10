defmodule PtcRunner.Kernel.Eval.Oracle do
  @moduledoc false

  @type expectation ::
          :any | :boolean | :float | :integer | :list | :map | nil | :number | :string

  @type constraint ::
          {:eq, term()}
          | {:gt, number()}
          | {:gte, number()}
          | {:lt, number()}
          | {:between, number(), number()}
          | {:length, non_neg_integer()}
          | {:gt_length, non_neg_integer()}
          | {:starts_with, String.t()}
          | {:one_of, list()}
          | {:has_keys, list()}

  @spec verify(map(), term()) :: :ok | {:error, String.t()}
  def verify(%{expect: expect, constraint: constraint}, value) do
    with :ok <- verify_type(expect, value) do
      verify_constraint(constraint, value)
    end
  end

  def verify(%{expect: _expect}, _value), do: {:error, "missing_constraint"}
  def verify(%{constraint: _constraint}, _value), do: {:error, "missing_expect"}
  def verify(_case, _value), do: {:error, "missing_oracle"}

  @spec expected_projection(map()) :: map()
  def expected_projection(%{expect: expect, constraint: constraint}) when is_atom(expect) do
    %{expect: Atom.to_string(expect), constraint: project_constraint(constraint)}
  end

  def expected_projection(%{expect: expect, constraint: constraint}) do
    %{
      expect: %{type: "invalid", hash: hash_term(expect)},
      constraint: project_constraint(constraint)
    }
  end

  def expected_projection(_case), do: %{error: "missing_oracle"}

  defp verify_type(:any, _value), do: :ok
  defp verify_type(:boolean, value) when is_boolean(value), do: :ok
  defp verify_type(:float, value) when is_float(value), do: :ok
  defp verify_type(:integer, value) when is_integer(value), do: :ok

  defp verify_type(:list, value) when is_list(value) do
    if proper_list?(value), do: :ok, else: {:error, "expect_type_mismatch:list"}
  end

  defp verify_type(:map, value) when is_map(value) and not is_struct(value), do: :ok
  defp verify_type(nil, nil), do: :ok
  defp verify_type(:number, value) when is_number(value), do: :ok

  defp verify_type(:string, value) when is_binary(value) do
    if String.valid?(value), do: :ok, else: {:error, "expect_type_mismatch:string"}
  end

  defp verify_type(expect, _value)
       when expect in [:boolean, :float, :integer, :list, :map, nil, :number, :string],
       do: {:error, "expect_type_mismatch:#{expect}"}

  defp verify_type(_expect, _value), do: {:error, "unknown_expect"}

  defp verify_constraint({:eq, expected}, value) when value === expected, do: :ok
  defp verify_constraint({:eq, _expected}, _value), do: {:error, "constraint_failed:eq"}

  defp verify_constraint({name, limit}, _value)
       when name in [:gt, :gte, :lt] and not is_number(limit),
       do: {:error, "invalid_constraint:#{name}"}

  defp verify_constraint({:gt, limit}, value) when is_number(value) and value > limit, do: :ok
  defp verify_constraint({:gt, _limit}, _value), do: {:error, "constraint_failed:gt"}
  defp verify_constraint({:gte, limit}, value) when is_number(value) and value >= limit, do: :ok
  defp verify_constraint({:gte, _limit}, _value), do: {:error, "constraint_failed:gte"}
  defp verify_constraint({:lt, limit}, value) when is_number(value) and value < limit, do: :ok
  defp verify_constraint({:lt, _limit}, _value), do: {:error, "constraint_failed:lt"}

  defp verify_constraint({:between, min, max}, _value)
       when not is_number(min) or not is_number(max) or min > max,
       do: {:error, "invalid_constraint:between"}

  defp verify_constraint({:between, min, max}, value)
       when is_number(value) and value >= min and value <= max,
       do: :ok

  defp verify_constraint({:between, _min, _max}, _value),
    do: {:error, "constraint_failed:between"}

  defp verify_constraint({name, expected}, _value)
       when name in [:length, :gt_length] and
              (not is_integer(expected) or expected < 0),
       do: {:error, "invalid_constraint:#{name}"}

  defp verify_constraint({:length, expected}, value) do
    verify_length(value, &(&1 == expected), "length")
  end

  defp verify_constraint({:gt_length, expected}, value) do
    verify_length(value, &(&1 > expected), "gt_length")
  end

  defp verify_constraint({:starts_with, prefix}, value)
       when is_binary(prefix) and is_binary(value) do
    cond do
      not String.valid?(prefix) -> {:error, "invalid_constraint:starts_with"}
      not String.valid?(value) -> {:error, "invalid_value:starts_with"}
      String.starts_with?(value, prefix) -> :ok
      true -> {:error, "constraint_failed:starts_with"}
    end
  end

  defp verify_constraint({:starts_with, _prefix}, _value),
    do: {:error, "invalid_constraint:starts_with"}

  defp verify_constraint({:one_of, allowed}, value) when is_list(allowed) do
    if proper_list?(allowed) do
      if Enum.any?(allowed, &(&1 === value)),
        do: :ok,
        else: {:error, "constraint_failed:one_of"}
    else
      {:error, "invalid_constraint:one_of"}
    end
  end

  defp verify_constraint({:one_of, _allowed}, _value),
    do: {:error, "invalid_constraint:one_of"}

  defp verify_constraint({:has_keys, keys}, value) when is_list(keys) and is_map(value) do
    if proper_list?(keys) do
      verify_has_keys(keys, value)
    else
      {:error, "invalid_constraint:has_keys"}
    end
  end

  defp verify_constraint({:has_keys, _keys}, _value),
    do: {:error, "invalid_constraint:has_keys"}

  defp verify_constraint(_constraint, _value), do: {:error, "unknown_constraint"}

  defp verify_has_keys(keys, value) do
    with {:ok, required} <- normalized_keys(keys) do
      actual =
        value
        |> Map.keys()
        |> Enum.flat_map(fn key ->
          case normalize_key(key) do
            {:ok, normalized} -> [normalized]
            :error -> []
          end
        end)
        |> MapSet.new()

      if MapSet.subset?(required, actual), do: :ok, else: {:error, "constraint_failed:has_keys"}
    end
  end

  defp verify_length(value, predicate, name) when is_list(value) do
    if proper_list?(value) do
      if predicate.(length(value)), do: :ok, else: {:error, "constraint_failed:#{name}"}
    else
      {:error, "invalid_value:#{name}"}
    end
  end

  defp verify_length(value, predicate, name) when is_binary(value) do
    if String.valid?(value) do
      if predicate.(String.length(value)),
        do: :ok,
        else: {:error, "constraint_failed:#{name}"}
    else
      {:error, "invalid_value:#{name}"}
    end
  end

  defp verify_length(_value, _predicate, name), do: {:error, "constraint_failed:#{name}"}

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_other), do: false

  defp normalized_keys(keys) do
    Enum.reduce_while(keys, {:ok, MapSet.new()}, fn key, {:ok, acc} ->
      case normalize_key(key) do
        {:ok, normalized} -> {:cont, {:ok, MapSet.put(acc, normalized)}}
        :error -> {:halt, {:error, "invalid_constraint:has_keys"}}
      end
    end)
  end

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: :error

  defp project_constraint({name, value}) when is_atom(name),
    do: %{kind: Atom.to_string(name), value: project_value(value)}

  defp project_constraint({name, min, max}) when is_atom(name),
    do: %{kind: Atom.to_string(name), min: project_value(min), max: project_value(max)}

  defp project_constraint(other), do: %{kind: "invalid", hash: hash_term(other)}

  defp project_value(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value

  defp project_value(value) when is_binary(value),
    do: %{type: "string", bytes: byte_size(value), hash: hash_term(value)}

  defp project_value(value) when is_list(value) do
    if proper_list?(value) do
      %{type: "list", count: length(value), hash: hash_term(value)}
    else
      %{type: "improper_list", hash: hash_term(value)}
    end
  end

  defp project_value(value), do: %{type: "other", hash: hash_term(value)}

  defp hash_term(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term))
    |> Base.encode16(case: :lower)
  end
end
