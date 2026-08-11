defmodule PtcRunner.Kernel.LLMUsage do
  @moduledoc false

  alias PtcRunner.Lisp.RetainedSize

  @integer_keys ~w(input output cache_creation cache_read)
  @keys @integer_keys ++ ["total_cost"]
  @maximum_integer 9_007_199_254_740_991
  @maximum_cost 1.0e12
  @maximum_bytes 512

  @spec normalize(term()) :: {:ok, map()} | {:error, :invalid_llm_usage}
  def normalize(tokens) when is_map(tokens) and not is_struct(tokens) do
    normalized = Map.new(tokens, fn {key, value} -> {stringify_key(key), value} end)

    if map_size(normalized) == map_size(tokens) and Map.keys(normalized) -- @keys == [] and
         Enum.all?(@integer_keys, &valid_integer?(normalized, &1)) and
         valid_cost?(Map.get(normalized, "total_cost")) and within_limit?(normalized) do
      {:ok, RetainedSize.detach_binaries(normalized)}
    else
      {:error, :invalid_llm_usage}
    end
  rescue
    _exception -> {:error, :invalid_llm_usage}
  end

  def normalize(_tokens), do: {:error, :invalid_llm_usage}

  @spec from_response(term()) :: map() | nil
  def from_response(%{status: :ok, value: %{"tokens" => tokens}}) do
    case normalize(tokens) do
      {:ok, normalized} -> normalized
      {:error, :invalid_llm_usage} -> nil
    end
  end

  def from_response(_result), do: nil

  defp stringify_key(key) when is_binary(key), do: key
  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key), do: key

  defp valid_integer?(usage, key) do
    case Map.fetch(usage, key) do
      :error -> true
      {:ok, value} -> is_integer(value) and value >= 0 and value <= @maximum_integer
    end
  end

  defp valid_cost?(nil), do: true

  defp valid_cost?(value) when is_integer(value),
    do: value >= 0 and value <= @maximum_cost

  defp valid_cost?(value) when is_float(value),
    do: value >= 0.0 and value <= @maximum_cost and value == value

  defp valid_cost?(_value), do: false

  defp within_limit?(usage) do
    case RetainedSize.bytes_with_cap(usage, @maximum_bytes) do
      bytes when is_integer(bytes) -> bytes <= @maximum_bytes
      :oversized -> false
    end
  end
end
