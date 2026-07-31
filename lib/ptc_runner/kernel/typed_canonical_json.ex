defmodule PtcRunner.Kernel.TypedCanonicalJSON do
  @moduledoc """
  Type-preserving canonical JSON bytes for stable application identity.

  PTC-Lisp distinguishes integer and float runtime values, while ordinary JSON
  canonicalization does not. TJCS first projects every node to a tagged tree
  and then emits deterministic UTF-8 JSON:

  - scalars become `["null"]`, `["boolean", value]`,
    `["string", value]`, `["integer", decimal]`, or
    `["float64", ieee754_hex]`;
  - arrays become `["array", [...]]`; and
  - objects become `["object", [[key, tagged_value], ...]]`, sorted by key
    UTF-8 bytes.

  Every input passes through `PtcRunner.Kernel.StrictJSON`, so duplicate keys
  from decoded bytes, invalid Unicode, non-finite floats, excessive depth, and
  excessive node counts are rejected before identity traversal.
  """

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.StrictJSON

  @type error :: PtcRunner.Kernel.StrictJSON.error() | :invalid_json

  @spec encode(term(), keyword()) :: {:ok, binary()} | {:error, error()}
  @doc "Admits and encodes one JSON-shaped value as TJCS bytes."
  def encode(value, opts \\ []) do
    with {:ok, admitted} <- StrictJSON.admit(value, opts),
         {:ok, projected} <- project(admitted) do
      DeterministicJSON.encode(projected)
    end
  end

  @spec project(term()) :: {:ok, term()} | {:error, :invalid_json}
  @doc false
  def project(nil), do: {:ok, ["null"]}
  def project(value) when is_boolean(value), do: {:ok, ["boolean", value]}
  def project(value) when is_binary(value), do: {:ok, ["string", value]}
  def project(value) when is_integer(value), do: {:ok, ["integer", Integer.to_string(value)]}

  def project(value) when is_float(value) do
    <<bits::unsigned-big-64>> = <<value::float-big-64>>
    {:ok, ["float64", Base.encode16(<<bits::unsigned-big-64>>, case: :lower)]}
  end

  def project(values) when is_list(values) do
    with {:ok, projected} <- project_many(values) do
      {:ok, ["array", projected]}
    end
  end

  def project(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> project_pairs()
    |> case do
      {:ok, pairs} -> {:ok, ["object", pairs]}
      {:error, :invalid_json} = error -> error
    end
  end

  def project(_value), do: {:error, :invalid_json}

  @spec sha256(binary(), binary()) :: binary()
  @doc false
  def sha256(domain, payload) when is_binary(domain) and is_binary(payload) do
    :crypto.hash(:sha256, [domain, <<byte_size(payload)::unsigned-big-64>>, payload])
    |> Base.encode16(case: :lower)
  end

  defp project_many(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, projected} ->
      case project(value) do
        {:ok, item} -> {:cont, {:ok, [item | projected]}}
        {:error, :invalid_json} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      {:error, :invalid_json} = error -> error
    end
  end

  defp project_pairs(pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn
      {key, value}, {:ok, projected} when is_binary(key) ->
        case project(value) do
          {:ok, item} -> {:cont, {:ok, [[key, item] | projected]}}
          {:error, :invalid_json} = error -> {:halt, error}
        end

      _pair, _acc ->
        {:halt, {:error, :invalid_json}}
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      {:error, :invalid_json} = error -> error
    end
  end
end
