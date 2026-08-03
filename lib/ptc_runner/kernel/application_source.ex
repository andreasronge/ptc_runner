defmodule PtcRunner.Kernel.ApplicationSource do
  @moduledoc """
  Bounded, caching document source shared by application acquisition adapters.

  Directory reads are confined to one canonical root. Memory reads use
  portable logical names and reject unused supplied records. Each unique
  document is charged once and cached, so later compilation cannot reopen a
  path and observe different bytes.
  """

  alias PtcRunner.Kernel.ConfinedFile

  @logical_name_body "[a-z0-9][a-z0-9._-]{0,127}(?:/[a-z0-9][a-z0-9._-]{0,127}){0,15}"
  @logical_name Regex.compile!("\\A" <> @logical_name_body <> "\\z")
  @max_records 512
  @max_bytes 8_388_608
  @max_transport_name_bytes 2_049

  @enforce_keys [:pid, :manifest_name]
  defstruct @enforce_keys

  @type t :: %__MODULE__{pid: pid(), manifest_name: binary()}

  @spec open_directory(binary()) :: {:ok, t()} | {:error, atom()}
  @doc "Opens one confined directory-backed application source."
  def open_directory(path) when is_binary(path) do
    with {:ok, canonical} <- ConfinedFile.resolve_absolute(Path.expand(path)),
         manifest_name = Path.basename(canonical),
         true <- valid_name?(manifest_name),
         root = Path.dirname(canonical),
         {:ok, source} <- start({:directory, root}, manifest_name) do
      ensure_manifest(source)
    else
      false -> {:error, :invalid_logical_name}
      {:error, _reason} = error -> error
    end
  end

  def open_directory(_path), do: {:error, :invalid_application_source}

  @spec open_memory(binary(), %{binary() => binary()}) :: {:ok, t()} | {:error, atom()}
  @doc "Opens one in-memory logical-name/bytes application source."
  def open_memory(manifest_name, documents)
      when is_binary(manifest_name) and is_map(documents) and not is_struct(documents) do
    with true <- valid_name?(manifest_name),
         true <- map_size(documents) <= @max_records,
         true <- Enum.all?(documents, &valid_document_shape?/1),
         true <- aggregate_bytes(documents) <= @max_bytes,
         {:ok, manifest_name, documents} <- rebase_memory_documents(manifest_name, documents),
         true <- Enum.all?(documents, &valid_document_encoding?/1),
         true <- Map.has_key?(documents, manifest_name),
         {:ok, source} <- start({:memory, documents}, manifest_name) do
      ensure_manifest(source)
    else
      false -> {:error, :invalid_application_source}
      {:error, _reason} = error -> error
    end
  end

  def open_memory(_manifest_name, _documents), do: {:error, :invalid_application_source}

  @spec manifest(t()) :: {:ok, binary()} | {:error, atom()}
  @doc false
  def manifest(%__MODULE__{} = source), do: read(source, source.manifest_name, 1_000_000)

  @spec logical_name(t(), binary()) ::
          {:ok, binary()} | {:error, :outside_application_source | :invalid_logical_name}
  @doc false
  def logical_name(%__MODULE__{pid: pid}, path) when is_binary(path) do
    Agent.get(pid, fn
      %{mode: {:directory, root}} ->
        with {:ok, canonical} <- ConfinedFile.resolve_absolute(Path.expand(path)),
             true <- within_root?(root, canonical),
             relative = Path.relative_to(canonical, root),
             true <- valid_name?(relative) do
          {:ok, relative}
        else
          false ->
            if within_root?(root, Path.expand(path)),
              do: {:error, :invalid_logical_name},
              else: {:error, :outside_application_source}

          {:error, _reason} ->
            {:error, :outside_application_source}
        end

      %{mode: {:memory, _documents}} ->
        {:error, :outside_application_source}
    end)
  catch
    :exit, _reason -> {:error, :outside_application_source}
  end

  def logical_name(_source, _path), do: {:error, :invalid_logical_name}

  @spec resolve_reference(t(), binary(), binary()) ::
          {:ok, binary()} | {:error, :invalid_logical_name}
  @doc false
  def resolve_reference(%__MODULE__{pid: pid}, document_name, relative_name)
      when is_binary(document_name) and is_binary(relative_name) do
    if valid_name?(document_name) and valid_name?(relative_name) do
      Agent.get(pid, fn
        %{mode: {:directory, root}} ->
          directory = Path.expand(Path.dirname(document_name), root)
          candidate = Path.join(directory, relative_name)

          with {:ok, canonical} <- ConfinedFile.resolve_absolute(candidate),
               true <- within_root?(directory, canonical),
               logical_name = Path.relative_to(candidate, root),
               true <- valid_name?(logical_name) do
            {:ok, logical_name}
          else
            _invalid -> {:error, :invalid_logical_name}
          end

        %{mode: {:memory, _documents}} ->
          logical_name =
            case Path.dirname(document_name) do
              "." -> relative_name
              directory -> Path.join(directory, relative_name)
            end

          if valid_name?(logical_name),
            do: {:ok, logical_name},
            else: {:error, :invalid_logical_name}
      end)
    else
      {:error, :invalid_logical_name}
    end
  catch
    :exit, _reason -> {:error, :invalid_logical_name}
  end

  def resolve_reference(_source, _document_name, _relative_name),
    do: {:error, :invalid_logical_name}

  @spec read_reference(t(), binary(), pos_integer()) ::
          {:ok, binary()} | {:error, atom()}
  @doc "Reads a logical name relative to the source manifest."
  def read_reference(%__MODULE__{} = source, relative_name, max_bytes) do
    with {:ok, name} <- resolve_reference(source, source.manifest_name, relative_name),
         do: read(source, name, max_bytes)
  end

  def read_reference(_source, _relative_name, _max_bytes),
    do: {:error, :invalid_application_source}

  @spec read(t(), binary(), pos_integer()) :: {:ok, binary()} | {:error, atom()}
  @doc "Reads and caches one portable logical document under a per-role ceiling."
  def read(%__MODULE__{pid: pid}, name, max_bytes)
      when is_binary(name) and is_integer(max_bytes) and max_bytes > 0 do
    if valid_name?(name) do
      Agent.get_and_update(pid, fn state ->
        case read_state(state, name, max_bytes) do
          {:ok, bytes, next} -> {{:ok, bytes}, next}
          {:error, _reason} = error -> {error, state}
        end
      end)
    else
      {:error, :invalid_logical_name}
    end
  catch
    :exit, _reason -> {:error, :application_source_closed}
  end

  def read(_source, _name, _max_bytes), do: {:error, :invalid_application_source}

  @spec finish(t()) ::
          {:ok, %{document_count: non_neg_integer(), document_bytes: non_neg_integer()}}
          | {:error, atom()}
  @doc "Verifies memory closure use, returns accounting, and closes the source."
  def finish(%__MODULE__{pid: pid}) do
    result =
      Agent.get_and_update(pid, fn state ->
        result =
          case all_memory_documents_used(state) do
            :ok ->
              {:ok, %{document_count: map_size(state.captured), document_bytes: state.bytes}}

            {:error, _reason} = error ->
              error
          end

        {result, %{state | closed?: true}}
      end)

    Agent.stop(pid)
    result
  catch
    :exit, _reason -> {:error, :application_source_closed}
  end

  @spec close(t()) :: :ok
  @doc "Closes a source when acquisition aborts."
  def close(%__MODULE__{pid: pid}) do
    if Process.alive?(pid), do: Agent.stop(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @spec valid_name?(term()) :: boolean()
  @doc "Checks the portable lowercase ASCII logical-name grammar."
  def valid_name?(name) when is_binary(name) and byte_size(name) <= 1_024,
    do: String.valid?(name) and name =~ @logical_name

  def valid_name?(_name), do: false

  @spec logical_name_pattern() :: binary()
  @doc "Returns the JSON Schema pattern for portable application logical names."
  def logical_name_pattern, do: "^" <> @logical_name_body <> "$(?![\\s\\S])"

  defp start(mode, manifest_name) do
    case Agent.start_link(fn ->
           %{mode: mode, captured: %{}, bytes: 0, closed?: false, manifest_name: manifest_name}
         end) do
      {:ok, pid} -> {:ok, %__MODULE__{pid: pid, manifest_name: manifest_name}}
      {:error, _reason} -> {:error, :application_source_unavailable}
    end
  end

  defp ensure_manifest(source) do
    case read(source, source.manifest_name, 1_000_000) do
      {:ok, _manifest} ->
        {:ok, source}

      {:error, _reason} = error ->
        close(source)
        error
    end
  end

  defp read_state(%{closed?: true}, _name, _max_bytes),
    do: {:error, :application_source_closed}

  defp read_state(state, name, max_bytes) do
    case Map.fetch(state.captured, name) do
      {:ok, bytes} ->
        if byte_size(bytes) <= max_bytes,
          do: {:ok, bytes, state},
          else: {:error, :document_limit_exceeded}

      :error ->
        read_uncached(state, name, max_bytes)
    end
  end

  defp read_uncached(state, name, max_bytes) do
    remaining = @max_bytes - state.bytes

    cond do
      map_size(state.captured) >= @max_records ->
        {:error, :document_limit_exceeded}

      remaining <= 0 ->
        {:error, :document_limit_exceeded}

      true ->
        limit = min(max_bytes, remaining)

        with {:ok, bytes} <- source_bytes(state.mode, name, limit),
             true <- byte_size(bytes) <= max_bytes and byte_size(bytes) <= remaining do
          next = %{
            state
            | captured: Map.put(state.captured, name, bytes),
              bytes: state.bytes + byte_size(bytes)
          }

          {:ok, bytes, next}
        else
          false ->
            {:error, :document_limit_exceeded}

          {:error, reason} when reason in [:document_limit_exceeded, :too_large] ->
            {:error, :document_limit_exceeded}

          {:error, _reason} ->
            {:error, :reference_missing}
        end
    end
  end

  defp source_bytes({:directory, root}, name, limit), do: ConfinedFile.read(root, name, limit)

  defp source_bytes({:memory, documents}, name, limit) do
    case Map.fetch(documents, name) do
      {:ok, bytes} when byte_size(bytes) <= limit -> {:ok, bytes}
      {:ok, _bytes} -> {:error, :document_limit_exceeded}
      :error -> {:error, :reference_missing}
    end
  end

  defp all_memory_documents_used(%{mode: {:directory, _root}}), do: :ok

  defp all_memory_documents_used(%{mode: {:memory, documents}, captured: captured}) do
    if MapSet.new(Map.keys(documents)) == MapSet.new(Map.keys(captured)),
      do: :ok,
      else: {:error, :unused_memory_document}
  end

  defp valid_document_shape?({name, bytes}),
    do: is_binary(name) and byte_size(name) <= @max_transport_name_bytes and is_binary(bytes)

  defp valid_document_encoding?({name, bytes}),
    do: valid_name?(name) and String.valid?(bytes)

  defp aggregate_bytes(documents),
    do: Enum.reduce(documents, 0, fn {_name, bytes}, total -> total + byte_size(bytes) end)

  defp rebase_memory_documents(manifest_name, documents) do
    case Path.dirname(manifest_name) do
      "." ->
        {:ok, manifest_name, documents}

      directory ->
        prefix = directory <> "/"

        documents
        |> Enum.reduce_while({:ok, %{}}, fn {name, bytes}, {:ok, rebased} ->
          if String.starts_with?(name, prefix) do
            relative = binary_part(name, byte_size(prefix), byte_size(name) - byte_size(prefix))
            {:cont, {:ok, Map.put(rebased, relative, bytes)}}
          else
            {:halt, {:error, :invalid_application_source}}
          end
        end)
        |> case do
          {:ok, rebased} -> {:ok, Path.basename(manifest_name), rebased}
          {:error, _reason} = error -> error
        end
    end
  end

  defp within_root?("/", target), do: Path.type(target) == :absolute
  defp within_root?(root, target), do: target == root or String.starts_with?(target, root <> "/")
end
