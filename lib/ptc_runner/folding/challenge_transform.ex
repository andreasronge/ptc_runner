defmodule PtcRunner.Folding.ChallengeTransform do
  @moduledoc """
  Applies a `ChallengeSpec` to a data context, producing a modified context.

  Each transformation operator modifies only the targeted data source,
  leaving other sources intact. Transformations are deterministic (no randomness)
  so the external oracle can compute the correct answer reproducibly.
  """

  alias PtcRunner.Folding.ChallengeSpec

  @doc """
  Apply a challenge transformation to a base context.

  Returns the modified context map.
  """
  @spec apply_challenge(ChallengeSpec.t(), map()) :: map()
  def apply_challenge(%ChallengeSpec{op: :identity}, context), do: context

  def apply_challenge(%ChallengeSpec{op: :filter, source: source, params: params}, context) do
    key = to_string(source)
    items = Map.get(context, key, [])

    filtered =
      Enum.reject(items, fn item ->
        value = flex_get(item, params.field)
        compare(value, params.cmp, params.value)
      end)

    Map.put(context, key, filtered)
  end

  def apply_challenge(%ChallengeSpec{op: :truncate, source: source, params: params}, context) do
    key = to_string(source)
    items = Map.get(context, key, [])
    Map.put(context, key, Enum.take(items, params.count))
  end

  def apply_challenge(%ChallengeSpec{op: :inject_nulls, source: source, params: params}, context) do
    key = to_string(source)
    items = Map.get(context, key, [])
    field_str = to_string(params.field)

    modified =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, idx} ->
        if rem(idx, max(1, round(1.0 / params.fraction))) == 0 do
          Map.put(item, field_str, nil)
        else
          item
        end
      end)

    Map.put(context, key, modified)
  end

  def apply_challenge(%ChallengeSpec{op: :swap_field, source: source, params: params}, context) do
    key = to_string(source)
    items = Map.get(context, key, [])
    from_str = to_string(params.from)
    to_str = to_string(params.to)

    swapped =
      Enum.map(items, fn item ->
        from_val = Map.get(item, from_str)
        to_val = Map.get(item, to_str)

        item
        |> Map.put(from_str, to_val)
        |> Map.put(to_str, from_val)
      end)

    Map.put(context, key, swapped)
  end

  def apply_challenge(%ChallengeSpec{op: :scale_values, source: source, params: params}, context) do
    key = to_string(source)
    items = Map.get(context, key, [])
    field_str = to_string(params.field)

    scaled =
      Enum.map(items, fn item ->
        case Map.get(item, field_str) do
          val when is_number(val) -> Map.put(item, field_str, val * params.factor)
          _ -> item
        end
      end)

    Map.put(context, key, scaled)
  end

  defp compare(value, :>, threshold) when is_number(value), do: value > threshold
  defp compare(value, :<, threshold) when is_number(value), do: value < threshold
  defp compare(value, :=, threshold), do: value == threshold
  defp compare(_, _, _), do: false

  defp flex_get(map, key) when is_atom(key), do: Map.get(map, to_string(key), Map.get(map, key))
  defp flex_get(map, key), do: Map.get(map, key)
end
