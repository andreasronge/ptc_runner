defmodule PtcRunner.Kernel.LLMUsage do
  @moduledoc false

  alias PtcRunner.Lisp.RetainedSize

  @integer_keys ~w(input output cache_creation cache_read)
  @keys @integer_keys ++ ["total_cost"]
  @maximum_integer 9_007_199_254_740_991
  @maximum_bytes 1_024
  @decimal_bytes 64
  @decimal ~r/\A(?<whole>0|[1-9][0-9]*)(?:\.(?<fraction>[0-9]+))?(?:[eE](?<exponent>[+-]?[0-9]+))?\z/

  @type usage_guarantees :: %{tokens: boolean(), cost_currency: String.t() | nil}

  @doc false
  @spec maximum_integer() :: pos_integer()
  def maximum_integer, do: @maximum_integer

  @spec normalize(term()) :: {:ok, map()} | {:error, :invalid_llm_usage}
  def normalize(tokens) when is_map(tokens) and not is_struct(tokens) do
    normalized = Map.new(tokens, fn {key, value} -> {stringify_key(key), value} end)

    with true <- map_size(normalized) == map_size(tokens),
         true <- Map.keys(normalized) -- @keys == [],
         true <- Enum.all?(@integer_keys, &valid_integer?(normalized, &1)),
         {:ok, normalized} <- normalize_cost(normalized),
         true <- within_limit?(normalized) do
      {:ok, RetainedSize.detach_binaries(normalized)}
    else
      _invalid -> {:error, :invalid_llm_usage}
    end
  rescue
    _exception -> {:error, :invalid_llm_usage}
  end

  def normalize(_tokens), do: {:error, :invalid_llm_usage}

  @spec normalize(term(), usage_guarantees()) :: {:ok, map()} | {:error, :invalid_llm_usage}
  def normalize(tokens, %{tokens: tokens?, cost_currency: currency} = guarantees)
      when is_boolean(tokens?) and currency in ["USD", nil] and map_size(guarantees) == 2 do
    with {:ok, normalized} <- normalize(tokens),
         true <- not tokens? or complete_tokens?(normalized),
         true <- currency != "USD" or Map.has_key?(normalized, "total_cost") do
      {:ok, normalized}
    else
      _invalid -> {:error, :invalid_llm_usage}
    end
  end

  def normalize(_tokens, _guarantees), do: {:error, :invalid_llm_usage}

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

  defp complete_tokens?(usage),
    do: Map.has_key?(usage, "input") and Map.has_key?(usage, "output")

  defp normalize_cost(usage) do
    case Map.fetch(usage, "total_cost") do
      :error ->
        {:ok, usage}

      {:ok, value} ->
        case cost_microunits(value) do
          {:ok, microunits} ->
            {:ok,
             Map.put(usage, "total_cost", %{
               "currency" => "USD",
               "microunits" => microunits
             })}

          :error ->
            :error
        end
    end
  end

  defp cost_microunits(%{"currency" => "USD", "microunits" => microunits} = cost)
       when map_size(cost) == 2 and is_integer(microunits) and microunits in 0..@maximum_integer,
       do: {:ok, microunits}

  defp cost_microunits(%{currency: "USD", microunits: microunits} = cost)
       when map_size(cost) == 2 and is_integer(microunits) and microunits in 0..@maximum_integer,
       do: {:ok, microunits}

  defp cost_microunits(value) when is_integer(value) and value >= 0,
    do: decimal_microunits(Integer.to_string(value))

  defp cost_microunits(value) when is_float(value) and value >= 0.0 do
    decimal = if value == 0.0, do: "0", else: :erlang.float_to_binary(value, [:short])
    decimal_microunits(decimal)
  end

  defp cost_microunits(value) when is_binary(value), do: decimal_microunits(value)
  defp cost_microunits(_value), do: :error

  defp decimal_microunits(decimal) when byte_size(decimal) <= @decimal_bytes do
    case Regex.named_captures(@decimal, decimal) do
      %{"whole" => whole, "fraction" => fraction, "exponent" => exponent} ->
        coefficient = String.trim_leading(whole <> fraction, "0")

        if coefficient == "" do
          {:ok, 0}
        else
          exponent = if exponent == "", do: 0, else: String.to_integer(exponent)
          scaled_integer(coefficient, 6 + exponent - byte_size(fraction))
        end

      nil ->
        :error
    end
  end

  defp decimal_microunits(_decimal), do: :error

  defp scaled_integer(coefficient, power) when power >= 0 do
    if byte_size(coefficient) + power > byte_size(Integer.to_string(@maximum_integer)) do
      :error
    else
      bounded_microunits(String.to_integer(coefficient) * Integer.pow(10, power))
    end
  end

  defp scaled_integer(coefficient, power) do
    places = -power

    if places >= byte_size(coefficient) do
      {:ok, 1}
    else
      divisor = Integer.pow(10, places)
      value = String.to_integer(coefficient)
      rounded = div(value, divisor) + if(rem(value, divisor) == 0, do: 0, else: 1)
      bounded_microunits(rounded)
    end
  end

  defp bounded_microunits(value) when value in 0..@maximum_integer, do: {:ok, value}
  defp bounded_microunits(_value), do: :error

  defp within_limit?(usage) do
    case RetainedSize.bytes_with_cap(usage, @maximum_bytes) do
      bytes when is_integer(bytes) -> bytes <= @maximum_bytes
      :oversized -> false
    end
  end
end
