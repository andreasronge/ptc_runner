defmodule PtcRunner.Folding.ChallengeDecoder do
  @moduledoc """
  Decodes arbitrary PTC-Lisp output values into valid `ChallengeSpec` structs.

  Every possible output maps to a valid challenge — no output is "garbage."
  Tester fitness is determined by whether the challenge is *effective*
  (causes solver failures), not by output format.

  Uses deterministic hashing so the same output always produces the same challenge.
  Small output differences map to different challenges to reward tester diversity.
  """

  alias PtcRunner.Folding.ChallengeSpec

  @ops ChallengeSpec.ops()
  @sources ChallengeSpec.sources()
  @fields ChallengeSpec.fields()
  @comparators ChallengeSpec.comparators()

  @doc """
  Decode any PTC-Lisp output value into a valid ChallengeSpec.

  ## Examples

      iex> PtcRunner.Folding.ChallengeDecoder.decode(742).op
      :swap_field

      iex> PtcRunner.Folding.ChallengeDecoder.decode(nil).op
      :identity
  """
  @spec decode(term()) :: ChallengeSpec.t()
  def decode(nil), do: identity()
  def decode(:error), do: identity()
  def decode(false), do: identity()

  def decode(value) when is_integer(value) do
    decode_from_hash(value)
  end

  def decode(value) when is_float(value) do
    decode_from_hash(round(value * 1000))
  end

  def decode(value) when is_boolean(value) do
    if value, do: decode_from_hash(1), else: identity()
  end

  def decode(value) when is_binary(value) do
    hash = :erlang.phash2(value)
    decode_from_hash(hash)
  end

  def decode(value) when is_list(value) do
    hash = :erlang.phash2(value)
    decode_from_hash(hash)
  end

  def decode(value) when is_map(value) do
    # Try to use map keys directly if they match spec fields
    case decode_from_map(value) do
      {:ok, spec} -> spec
      :error -> decode_from_hash(:erlang.phash2(value))
    end
  end

  def decode(value) when is_atom(value) do
    decode_from_hash(:erlang.phash2(value))
  end

  def decode(value) do
    decode_from_hash(:erlang.phash2(value))
  end

  defp identity do
    %ChallengeSpec{op: :identity, source: :products, params: %{}}
  end

  defp decode_from_hash(n) when is_integer(n) do
    n = abs(n)
    op = Enum.at(@ops, rem(n, length(@ops)))
    source = Enum.at(@sources, rem(div(n, 7), length(@sources)))
    params = decode_params(op, n)

    %ChallengeSpec{op: op, source: source, params: params}
  end

  defp decode_params(:identity, _n), do: %{}

  defp decode_params(:filter, n) do
    field = Enum.at(@fields, rem(div(n, 13), length(@fields)))
    cmp = Enum.at(@comparators, rem(div(n, 17), length(@comparators)))
    # Value in range 100-900, stepping by 100
    value = rem(div(n, 23), 9) * 100 + 100

    %{field: field, cmp: cmp, value: value}
  end

  defp decode_params(:truncate, n) do
    # Count between 1 and 20
    count = rem(div(n, 11), 20) + 1
    %{count: count}
  end

  defp decode_params(:inject_nulls, n) do
    field = Enum.at(@fields, rem(div(n, 13), length(@fields)))
    # Fraction between 0.1 and 0.5, stepping by 0.1
    fraction = (rem(div(n, 19), 5) + 1) * 0.1
    %{field: field, fraction: fraction}
  end

  defp decode_params(:swap_field, n) do
    from_idx = rem(div(n, 13), length(@fields))
    # Ensure to != from by offsetting
    to_idx = rem(from_idx + rem(div(n, 17), length(@fields) - 1) + 1, length(@fields))

    %{from: Enum.at(@fields, from_idx), to: Enum.at(@fields, to_idx)}
  end

  defp decode_params(:scale_values, n) do
    field = Enum.at(@fields, rem(div(n, 13), length(@fields)))
    # Factor between 0.1 and 5.0, stepping by 0.1
    factor = (rem(div(n, 19), 50) + 1) * 0.1
    %{field: field, factor: factor}
  end

  # Try to decode a map value as a direct ChallengeSpec
  defp decode_from_map(map) do
    with op when op in @ops <- atom_get(map, :op),
         source when source in @sources <- atom_get(map, :source) do
      params = Map.get(map, :params, Map.get(map, "params", %{}))
      spec = %ChallengeSpec{op: op, source: source, params: atomize_params(params)}

      if ChallengeSpec.valid?(spec), do: {:ok, spec}, else: :error
    else
      _ -> :error
    end
  end

  defp atom_get(map, key) do
    case Map.get(map, key) do
      nil -> Map.get(map, to_string(key)) |> maybe_to_atom()
      val -> val
    end
  end

  defp maybe_to_atom(val) when is_atom(val), do: val

  defp maybe_to_atom(val) when is_binary(val) do
    String.to_existing_atom(val)
  rescue
    ArgumentError -> nil
  end

  defp maybe_to_atom(_), do: nil

  defp atomize_params(params) when is_map(params) do
    Map.new(params, fn
      {k, v} when is_binary(k) ->
        {try_atom(k), v}

      {k, v} ->
        {k, v}
    end)
  end

  defp atomize_params(params), do: params

  defp try_atom(s) do
    String.to_existing_atom(s)
  rescue
    _ -> s
  end
end
