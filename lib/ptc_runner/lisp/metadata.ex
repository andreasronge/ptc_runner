defmodule PtcRunner.Lisp.Metadata do
  @moduledoc false

  @default_bytes 8 * 1024
  @public_keys ~w(reason parent_version parent_checksum source_session_id created_by
                  requires_preludes prelude_deps)

  @spec public(map(), keyword()) :: map()
  def public(metadata, opts \\ [])

  def public(metadata, opts) when is_map(metadata) do
    max_bytes = byte_bound(opts)

    Enum.reduce(metadata, %{}, fn {raw_key, value}, acc ->
      key = normalize_key(raw_key)

      cond do
        key == "prelude_deps" -> maybe_put(acc, key, public_pins(value))
        key == "requires_preludes" -> maybe_put(acc, key, public_refs(value))
        key in @public_keys -> maybe_put_value(acc, key, value, max_bytes, opts)
        true -> acc
      end
    end)
  end

  def public(_metadata, _opts), do: %{}

  defp public_refs(refs) when is_list(refs), do: Enum.filter(refs, &is_binary/1)
  defp public_refs(_refs), do: []

  defp public_pins(pins) when is_list(pins) do
    Enum.flat_map(pins, fn pin ->
      if is_map(pin) do
        id = Map.get(pin, "id") || Map.get(pin, :id)
        version = Map.get(pin, "version") || Map.get(pin, :version)
        checksum = Map.get(pin, "checksum") || Map.get(pin, :checksum)

        if is_binary(id) and is_integer(version) and version > 0 and is_binary(checksum),
          do: [%{"id" => id, "version" => version, "checksum" => checksum}],
          else: []
      else
        []
      end
    end)
  end

  defp public_pins(_pins), do: []
  defp maybe_put(acc, _key, []), do: acc
  defp maybe_put(acc, key, value), do: Map.put(acc, key, value)

  defp maybe_put_value(acc, key, value, max_bytes, opts) do
    case public_value(value, max_bytes, Keyword.get(opts, :complex, :inspect)) do
      :drop -> acc
      public -> Map.put(acc, key, public)
    end
  end

  defp public_value(value, max_bytes, _complex) when is_binary(value),
    do: truncate(value, max_bytes)

  defp public_value(value, _max_bytes, _complex)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: value

  defp public_value(_value, _max_bytes, :drop), do: :drop

  defp public_value(value, max_bytes, _complex),
    do: value |> inspect(limit: 20) |> truncate(max_bytes)

  defp byte_bound(opts) do
    case Keyword.get(opts, :max_metadata_bytes, @default_bytes) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> @default_bytes
    end
  end

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: inspect(key)

  defp truncate(value, max_bytes) do
    prefix = binary_part(value, 0, min(byte_size(value), max_bytes))
    valid_prefix(prefix)
  end

  defp valid_prefix(value) do
    if String.valid?(value),
      do: value,
      else: valid_prefix(binary_part(value, 0, byte_size(value) - 1))
  end
end
