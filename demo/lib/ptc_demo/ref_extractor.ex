defmodule PtcDemo.RefExtractor do
  @moduledoc """
  Extracts values from results using Access paths or functions.
  Supports `Access.at(n)` and other standard Access patterns.
  """

  @doc """
  Extracts values based on the provided refs map.

  ## Examples

      iex> result = [%{id: 1, name: "Alice"}, %{id: 2, name: "Bob"}]
      iex> refs = %{first_id: [Access.at(0), :id], count: &length/1}
      iex> PtcDemo.RefExtractor.extract(result, refs)
      %{first_id: 1, count: 2}
  """
  def extract(result, refs) when is_map(refs) do
    Map.new(refs, fn {key, spec} ->
      {key, extract_value(result, spec)}
    end)
  end

  defp extract_value(result, spec) when is_list(spec) do
    get_in(result, spec)
  end

  defp extract_value(result, spec) when is_function(spec, 1) do
    spec.(result)
  end

  defp extract_value(_result, _spec), do: nil
end
