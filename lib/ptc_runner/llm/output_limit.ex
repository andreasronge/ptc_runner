defmodule PtcRunner.LLM.OutputLimit do
  @moduledoc false

  @bindings [:configured, :adapter_default, :model_output_limit, :remaining_context]
  @maximum 1_000_000
  @alias_pattern ~r/\A[a-z][a-z0-9._-]{0,127}\z/

  @type binding :: PtcRunner.LLM.output_limit_binding()
  @type t :: PtcRunner.LLM.output_limit()

  @spec bindings() :: [binding()]
  def bindings, do: @bindings

  @spec select([{binding(), term()}]) :: {pos_integer(), [binding()]}
  def select(candidates) when is_list(candidates) do
    candidates = Enum.filter(candidates, fn {_binding, value} -> positive_integer?(value) end)
    value = candidates |> Enum.map(&elem(&1, 1)) |> Enum.min()

    selected =
      for binding <- @bindings,
          {^binding, ^value} <- candidates,
          do: binding

    {value, selected}
  end

  @spec normalize(term()) :: {:ok, t()} | :error
  def normalize(limit) when is_map(limit) and not is_struct(limit) do
    with :max_tokens <- token(fetch(limit, :name)),
         value when is_integer(value) and value in 1..@maximum <- fetch(limit, :value),
         bindings when is_list(bindings) <- fetch(limit, :bindings),
         normalized when normalized != [] <- Enum.map(bindings, &token/1),
         true <- normalized == Enum.uniq(normalized),
         true <- normalized == Enum.filter(@bindings, &(&1 in normalized)) do
      {:ok, %{name: :max_tokens, value: value, bindings: normalized}}
    else
      _invalid -> :error
    end
  end

  def normalize(_limit), do: :error

  @spec valid_alias?(term()) :: boolean()
  def valid_alias?(alias_name), do: is_binary(alias_name) and alias_name =~ @alias_pattern

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp token(value) when value in @bindings or value == :max_tokens, do: value

  defp token(value) when is_binary(value) do
    case value do
      "configured" -> :configured
      "adapter_default" -> :adapter_default
      "model_output_limit" -> :model_output_limit
      "remaining_context" -> :remaining_context
      "max_tokens" -> :max_tokens
      _unknown -> nil
    end
  end

  defp token(_value), do: nil
  defp positive_integer?(value), do: is_integer(value) and value in 1..@maximum
end
