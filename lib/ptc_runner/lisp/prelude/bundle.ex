defmodule PtcRunner.Lisp.Prelude.Bundle do
  @moduledoc """
  Deterministic source-level composition for selected capability preludes.

  This is the selection-only helper for live prelude evolution. It does not
  introduce storage or version policy: callers pass source-bearing selections,
  the helper validates each component, rejects duplicate namespaces, concatenates
  the sources in selection order, and compiles the aggregate source once into the
  normal `%PtcRunner.Lisp.Prelude{}` artifact accepted by `Lisp.run/2`.
  """

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Lisp.Prelude.ValidationError

  @type origin :: String.t() | atom() | {:file, Path.t()} | {:memory, term()} | nil

  @type selection ::
          String.t()
          | {String.t(), String.t()}
          | %{
              required(:source) => String.t(),
              optional(:id) => String.t(),
              optional(:version) => pos_integer(),
              optional(:checksum) => String.t(),
              optional(:origin) => origin()
            }
          | map()

  @type component :: %{
          id: String.t() | nil,
          version: pos_integer() | nil,
          checksum: String.t() | nil,
          source_hash: String.t(),
          namespaces: [String.t()],
          origin: String.t() | nil
        }

  @doc """
  Compiles selected prelude sources into one frozen prelude artifact.

  Source order is preserved. Duplicate namespace ids fail closed before the
  aggregate compile. Component provenance is stored in `prelude.metadata` and
  exposed by `PtcRunner.Lisp.Prelude.trace_summary/1`.
  """
  @spec compile([selection()]) :: {:ok, Prelude.t()} | {:error, ValidationError.t()}
  def compile(selections) when is_list(selections) do
    with {:ok, components} <- normalize_and_compile(selections),
         :ok <- reject_duplicate_namespaces(components) do
      compile_components(components)
    end
  end

  def compile(_other) do
    {:error, ValidationError.new(:compile_error, "prelude bundle selections must be a list")}
  end

  @doc false
  @spec compile_precompiled([map()]) :: {:ok, Prelude.t()} | {:error, ValidationError.t()}
  def compile_precompiled(selections) when is_list(selections) do
    with {:ok, components} <- normalize_precompiled(selections),
         :ok <- reject_duplicate_namespaces(components) do
      compile_components(components)
    end
  end

  def compile_precompiled(_other) do
    {:error,
     ValidationError.new(:compile_error, "precompiled prelude bundle selections must be a list")}
  end

  defp compile_components(components) do
    source = concatenate_sources(components)

    with {:ok, %Prelude{} = prelude} <- Compiler.compile(source) do
      {:ok,
       %Prelude{
         prelude
         | metadata: Map.put(prelude.metadata, :components, Enum.map(components, & &1.provenance))
       }}
    end
  end

  defp normalize_and_compile(selections) do
    selections
    |> Enum.reduce_while({:ok, []}, fn selection, {:ok, acc} ->
      with {:ok, normalized} <- normalize_selection(selection),
           {:ok, %Prelude{} = prelude} <- Compiler.compile(normalized.source),
           :ok <- validate_checksum(normalized.checksum, prelude.source_hash) do
        component = %{
          source: normalized.source,
          prelude: prelude,
          provenance: %{
            id: normalized.id,
            version: normalized.version,
            checksum: normalized.checksum || prelude.source_hash,
            source_hash: prelude.source_hash,
            namespaces: prelude.namespaces,
            origin: normalize_origin(normalized.origin)
          }
        }

        {:cont, {:ok, [component | acc]}}
      else
        {:error, %ValidationError{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, components} -> {:ok, Enum.reverse(components)}
      {:error, _} = error -> error
    end
  end

  defp normalize_precompiled(selections) do
    selections
    |> Enum.reduce_while({:ok, []}, fn selection, {:ok, acc} ->
      with {:ok, normalized} <- normalize_precompiled_selection(selection),
           :ok <- validate_precompiled_source(normalized.source, normalized.prelude),
           :ok <- validate_checksum(normalized.checksum, normalized.prelude.source_hash) do
        component = %{
          source: normalized.source,
          prelude: normalized.prelude,
          provenance: %{
            id: normalized.id,
            version: normalized.version,
            checksum: normalized.checksum || normalized.prelude.source_hash,
            source_hash: normalized.prelude.source_hash,
            namespaces: normalized.prelude.namespaces,
            origin: normalize_origin(normalized.origin)
          }
        }

        {:cont, {:ok, [component | acc]}}
      else
        {:error, %ValidationError{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, components} -> {:ok, Enum.reverse(components)}
      {:error, _} = error -> error
    end
  end

  defp normalize_selection(source) when is_binary(source) do
    {:ok, %{id: nil, source: source, version: nil, checksum: nil, origin: nil}}
  end

  defp normalize_selection({id, source}) when is_binary(id) and is_binary(source) do
    {:ok, %{id: id, source: source, version: nil, checksum: nil, origin: nil}}
  end

  defp normalize_selection(selection) when is_map(selection) do
    source = Map.get(selection, :source) || Map.get(selection, "source")
    id = Map.get(selection, :id) || Map.get(selection, "id")
    version = Map.get(selection, :version) || Map.get(selection, "version")
    checksum = Map.get(selection, :checksum) || Map.get(selection, "checksum")
    origin = Map.get(selection, :origin) || Map.get(selection, "origin")

    cond do
      not is_binary(source) ->
        {:error, ValidationError.new(:compile_error, "prelude bundle selection requires source")}

      not (is_nil(id) or is_binary(id)) ->
        {:error,
         ValidationError.new(:compile_error, "prelude bundle selection id must be a string")}

      not (is_nil(version) or (is_integer(version) and version > 0)) ->
        {:error,
         ValidationError.new(
           :compile_error,
           "prelude bundle selection version must be a positive integer"
         )}

      not (is_nil(checksum) or is_binary(checksum)) ->
        {:error,
         ValidationError.new(:compile_error, "prelude bundle selection checksum must be a string")}

      true ->
        {:ok, %{id: id, source: source, version: version, checksum: checksum, origin: origin}}
    end
  end

  defp normalize_selection(other) do
    {:error,
     ValidationError.new(
       :compile_error,
       "unsupported prelude bundle selection: #{inspect(other, limit: 5)}"
     )}
  end

  defp normalize_precompiled_selection(selection) when is_map(selection) do
    with {:ok, source} <- precompiled_source(selection),
         {:ok, prelude} <- precompiled_prelude(selection),
         {:ok, id} <- optional_string_field(selection, :id, "precompiled prelude selection id"),
         {:ok, version} <- optional_version_field(selection),
         {:ok, checksum} <-
           optional_string_field(selection, :checksum, "precompiled prelude selection checksum") do
      {:ok,
       %{
         id: id,
         source: source,
         prelude: prelude,
         version: version,
         checksum: checksum,
         origin: get_field(selection, :origin)
       }}
    end
  end

  defp normalize_precompiled_selection(other) do
    {:error,
     ValidationError.new(
       :compile_error,
       "unsupported precompiled prelude selection: #{inspect(other, limit: 5)}"
     )}
  end

  defp precompiled_source(selection) do
    case get_field(selection, :source) do
      source when is_binary(source) ->
        {:ok, source}

      _other ->
        {:error,
         ValidationError.new(:compile_error, "precompiled prelude selection requires source")}
    end
  end

  defp precompiled_prelude(selection) do
    case get_field(selection, :prelude) do
      %Prelude{} = prelude ->
        {:ok, prelude}

      _other ->
        {:error,
         ValidationError.new(
           :compile_error,
           "precompiled prelude selection requires a compiled prelude"
         )}
    end
  end

  defp optional_string_field(selection, key, label) do
    case get_field(selection, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, ValidationError.new(:compile_error, "#{label} must be a string")}
    end
  end

  defp optional_version_field(selection) do
    case get_field(selection, :version) do
      nil ->
        {:ok, nil}

      version when is_integer(version) and version > 0 ->
        {:ok, version}

      _other ->
        {:error,
         ValidationError.new(
           :compile_error,
           "precompiled prelude selection version must be a positive integer"
         )}
    end
  end

  defp get_field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp validate_precompiled_source(source, %Prelude{source_hash: source_hash}) do
    actual_hash = source_hash(source)

    if actual_hash == source_hash do
      :ok
    else
      {:error,
       ValidationError.new(
         :compile_error,
         "precompiled prelude selection source hash #{inspect(actual_hash)} does not match " <>
           "compiled source hash #{inspect(source_hash)}"
       )}
    end
  end

  defp validate_checksum(nil, _source_hash), do: :ok
  defp validate_checksum(source_hash, source_hash), do: :ok

  defp validate_checksum(checksum, source_hash) do
    {:error,
     ValidationError.new(
       :compile_error,
       "prelude bundle selection checksum #{inspect(checksum)} does not match source hash " <>
         inspect(source_hash)
     )}
  end

  defp reject_duplicate_namespaces(components) do
    components
    |> Enum.flat_map(fn component ->
      Enum.map(component.prelude.namespaces, &{&1, component.provenance.id})
    end)
    |> Enum.reduce_while(%{}, fn {namespace, id}, seen ->
      case Map.fetch(seen, namespace) do
        {:ok, first_id} ->
          {:halt,
           {:error,
            ValidationError.new(
              :invalid_namespace,
              "namespace `#{namespace}` is declared by more than one selected prelude" <>
                selected_ids(first_id, id),
              namespace: namespace
            )}}

        :error ->
          {:cont, Map.put(seen, namespace, id)}
      end
    end)
    |> case do
      %{} -> :ok
      {:error, _} = error -> error
    end
  end

  defp selected_ids(nil, nil), do: ""
  defp selected_ids(first, second), do: " (#{inspect(first)} and #{inspect(second)})"

  defp concatenate_sources(components) do
    Enum.map_join(components, "\n\n;; --- ptc_runner prelude component ---\n\n", & &1.source)
  end

  defp source_hash(source) do
    :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
  end

  defp normalize_origin(nil), do: nil
  defp normalize_origin({:file, path}) when is_binary(path), do: "file:" <> path
  defp normalize_origin({:memory, id}), do: "memory:" <> to_string(id)
  defp normalize_origin(origin) when is_atom(origin), do: Atom.to_string(origin)
  defp normalize_origin(origin) when is_binary(origin), do: origin
  defp normalize_origin(origin), do: inspect(origin)
end
