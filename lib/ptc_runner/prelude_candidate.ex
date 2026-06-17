defmodule PtcRunner.PreludeCandidate do
  @moduledoc """
  Versioned, source-bearing prelude candidate stored by `PtcRunner.PreludeStore`.

  The compiled field is intentionally Elixir-only. Lisp-facing and transport
  surfaces must project through `public_view/2` so the compiled prelude struct
  and private environment are never exposed.
  """

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Export

  @default_source_bytes 64 * 1024
  @default_metadata_bytes 8 * 1024
  @default_origin_bytes 128
  @public_metadata_keys ~w(reason parent_version parent_checksum source_session_id created_by)

  @type origin :: {:file, Path.t()} | {:memory, term()} | {:upstream, term()} | nil

  @type t :: %__MODULE__{
          id: String.t(),
          version: pos_integer(),
          source: String.t(),
          compiled: Prelude.t(),
          origin: origin(),
          metadata: map(),
          created_at: DateTime.t()
        }

  @enforce_keys [:id, :version, :source, :compiled, :origin, :metadata, :created_at]
  defstruct [:id, :version, :source, :compiled, :origin, :metadata, :created_at]

  @doc "The candidate checksum. This is the compiled prelude source hash."
  @spec checksum(t()) :: String.t()
  def checksum(%__MODULE__{compiled: %Prelude{source_hash: hash}}), do: hash

  @doc "Public export names without the namespace prefix, sorted."
  @spec export_names(t()) :: [String.t()]
  def export_names(%__MODULE__{compiled: %Prelude{exports: exports}}) do
    exports
    |> Enum.map(fn %Export{symbol: symbol} -> symbol end)
    |> Enum.sort()
  end

  @doc """
  Returns a bounded, public map view of a candidate.

  The view keeps source text because editor workflows need it, but bounds the
  bytes by option. It never includes the compiled prelude or private env.
  """
  @spec public_view(t(), keyword()) :: map()
  def public_view(%__MODULE__{} = candidate, opts \\ []) do
    max_source_bytes = byte_bound(opts, :max_source_bytes, @default_source_bytes)
    source = truncate_binary(candidate.source, max_source_bytes)

    %{
      id: candidate.id,
      version: candidate.version,
      checksum: checksum(candidate),
      source_bytes: byte_size(candidate.source),
      source_truncated: byte_size(source) < byte_size(candidate.source),
      namespaces: candidate.compiled.namespaces,
      exports: export_names(candidate),
      origin:
        public_origin(candidate.origin,
          max_bytes: byte_bound(opts, :max_origin_bytes, @default_origin_bytes)
        ),
      metadata:
        public_metadata(candidate.metadata,
          max_metadata_bytes: byte_bound(opts, :max_metadata_bytes, @default_metadata_bytes)
        ),
      created_at: candidate.created_at,
      source: source
    }
  end

  @doc "Filters untrusted metadata to documented public keys and byte bounds."
  @spec public_metadata(map(), keyword()) :: map()
  def public_metadata(metadata, opts \\ [])

  def public_metadata(metadata, opts) when is_map(metadata) do
    max_bytes = byte_bound(opts, :max_metadata_bytes, @default_metadata_bytes)

    metadata
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key = normalize_key(key)

      if key in @public_metadata_keys do
        case public_metadata_value(value, max_bytes, Keyword.get(opts, :complex, :inspect)) do
          :drop -> acc
          public_value -> Map.put(acc, key, public_value)
        end
      else
        acc
      end
    end)
  end

  def public_metadata(_metadata, _opts), do: %{}

  @doc "Returns a bounded, JSON-safe provenance tag for a candidate origin."
  @spec public_origin(origin(), keyword()) :: String.t() | nil
  def public_origin(origin, opts \\ []) do
    max_bytes = byte_bound(opts, :max_bytes, @default_origin_bytes)

    origin
    |> origin_string()
    |> truncate_binary(max_bytes)
  end

  defp origin_string(nil), do: nil
  defp origin_string({:memory, pid}) when is_pid(pid), do: "memory"
  defp origin_string({:memory, id}), do: "memory:" <> safe_to_string(id)
  defp origin_string({:file, path}) when is_binary(path), do: "file:" <> path
  defp origin_string({:upstream, ref}), do: "upstream:" <> safe_to_string(ref)
  defp origin_string(origin) when is_binary(origin), do: origin
  defp origin_string(origin) when is_atom(origin), do: Atom.to_string(origin)
  defp origin_string(origin), do: safe_to_string(origin)

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: inspect(key)

  defp safe_to_string(value) do
    to_string(value)
  rescue
    _ -> inspect(value, limit: 10)
  end

  defp public_metadata_value(value, max_bytes, _complex) when is_binary(value) do
    truncate_binary(value, max_bytes)
  end

  defp public_metadata_value(value, _max_bytes, _complex)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: value

  defp public_metadata_value(_value, _max_bytes, :drop), do: :drop

  defp public_metadata_value(value, max_bytes, _complex),
    do: value |> inspect(limit: 20) |> truncate_binary(max_bytes)

  defp byte_bound(opts, key, default) when is_list(opts) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end

  defp truncate_binary(value, max_bytes) when is_binary(value) and is_integer(max_bytes) do
    value
    |> binary_part(0, min(byte_size(value), max_bytes))
    |> valid_utf8_prefix()
  end

  defp truncate_binary(value, _max_bytes), do: value

  defp valid_utf8_prefix(value) do
    if String.valid?(value) do
      value
    else
      value
      |> byte_size()
      |> find_valid_prefix(value)
    end
  end

  defp find_valid_prefix(0, _value), do: ""

  defp find_valid_prefix(size, value) do
    prefix = binary_part(value, 0, size)

    if String.valid?(prefix) do
      prefix
    else
      find_valid_prefix(size - 1, value)
    end
  end
end
