defmodule PtcRunner.PreludeStore do
  @moduledoc """
  In-memory versioned store for source-bearing capability preludes.

  V1 is deliberately prelude-specific and volatile: it provides `list/1`,
  `history/2`, `read/2`, compile-on-write `write/4`, and explicit
  `set_default/4` over a small handle backed by a single owner process and ETS
  rows. Filesystem persistence remains a later plan chunk.
  """

  alias PtcRunner.Lisp.Discovery
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Lisp.Prelude.ValidationError
  alias PtcRunner.Lisp.ProtectedNamespaces
  alias PtcRunner.PreludeCandidate
  alias PtcRunner.PreludeStore.Server
  alias PtcRunner.Sandbox

  @default_max_source_bytes 1_000_000
  @default_compile_timeout 5_000
  @default_compile_max_heap 1_250_000

  @type t :: %__MODULE__{
          pid: GenServer.server(),
          opts: keyword()
        }

  defstruct [:pid, opts: []]

  @doc "Starts a volatile in-memory prelude store and returns its handle."
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) do
    with :ok <- validate_opts(opts) do
      Server.start_link(opts)
    end
  end

  @doc false
  @spec validate_opts(keyword()) :: :ok | {:error, map()}
  def validate_opts(opts) when is_list(opts) do
    [
      {:max_source_bytes, @default_max_source_bytes},
      {:max_versions, 1_000},
      {:compile_timeout, @default_compile_timeout},
      {:compile_max_heap, @default_compile_max_heap}
    ]
    |> Enum.reduce_while(:ok, fn {key, default}, :ok ->
      case validate_positive_integer(opts, key, default) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def validate_opts(_opts),
    do: {:error, error(:invalid_config, "PreludeStore options must be a keyword list")}

  @doc "Returns one bounded current row per prelude id, sorted by id."
  @spec list(t()) :: [map()]
  def list(%__MODULE__{} = store), do: Server.list(store)

  @doc "Returns bounded summary rows for all versions of one prelude id."
  @spec history(t(), String.t()) :: {:ok, [map()]} | {:error, map()}
  def history(%__MODULE__{} = store, id) do
    with :ok <- validate_id(id) do
      Server.history(store, id)
    end
  end

  @doc """
  Reads a candidate by bare id, `id@version`, or `%{id, version, checksum}` ref.
  """
  @spec read(t(), String.t() | map()) :: {:ok, PreludeCandidate.t()} | {:error, map()}
  def read(%__MODULE__{} = store, ref) do
    with {:ok, parsed} <- parse_ref(ref) do
      Server.read(store, parsed)
    end
  end

  @doc """
  Compiles and appends a new prelude version.

  The compiled namespace list must be exactly `[id]`. Stored source and metadata
  are untrusted; public projections bound and filter them.
  """
  @spec write(t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, map()}
  def write(store, id, source, metadata \\ %{})

  def write(%__MODULE__{} = store, id, source, metadata)
      when is_binary(id) and is_binary(source) and is_map(metadata) do
    opts = store.opts

    with :ok <- validate_id(id),
         :ok <-
           check_source_bound(
             source,
             Keyword.get(opts, :max_source_bytes, @default_max_source_bytes)
           ),
         {:ok, parent_checksum} <- parent_checksum(metadata),
         :ok <- check_parent(store, id, parent_checksum),
         {:ok, compiled} <- compile_bounded(source, opts),
         :ok <- validate_compiled_namespace(id, compiled) do
      candidate = %PreludeCandidate{
        id: id,
        version: 0,
        source: source,
        compiled: compiled,
        origin: Keyword.get(opts, :origin, {:memory, store.pid}),
        metadata: metadata,
        created_at: DateTime.utc_now()
      }

      Server.append(store, candidate, parent_checksum)
    end
  end

  def write(%__MODULE__{}, _id, _source, _metadata) do
    {:error,
     error(:invalid_argument, "write/4 requires string id, string source, and map metadata")}
  end

  @doc """
  Moves the bare-id default/current pointer to an existing version.

  `id` + `version` is the preferred explicit form. `id@version` or a
  `%{id, version, checksum}` ref are also accepted for checksum-pinned default
  changes.
  """
  @spec set_default(t(), String.t() | map()) :: {:ok, map()} | {:error, map()}
  def set_default(store, ref), do: set_default(store, ref, %{})

  @spec set_default(t(), String.t(), pos_integer()) :: {:ok, map()} | {:error, map()}
  def set_default(%__MODULE__{} = store, id, version)
      when is_binary(id) and is_integer(version) and version > 0,
      do: set_default(store, id, version, %{})

  @spec set_default(t(), String.t() | map(), map()) :: {:ok, map()} | {:error, map()}
  def set_default(%__MODULE__{} = store, ref, metadata) when is_map(metadata) do
    case parse_ref(ref) do
      {:ok, %{version: version} = parsed} when is_integer(version) ->
        Server.set_default(store, parsed, metadata)

      {:ok, %{id: id}} ->
        {:error, error(:invalid_ref, "set_default requires an explicit version for `#{id}`")}

      {:error, _} = error ->
        error

      _ ->
        {:error, error(:invalid_ref, "invalid prelude ref #{inspect(ref, limit: 5)}")}
    end
  end

  def set_default(%__MODULE__{}, _ref, _metadata) do
    {:error, error(:invalid_argument, "set_default/3 requires map metadata")}
  end

  @spec set_default(t(), String.t(), pos_integer(), map()) :: {:ok, map()} | {:error, map()}
  def set_default(%__MODULE__{} = store, id, version, metadata)
      when is_binary(id) and is_integer(version) and version > 0 and is_map(metadata) do
    with :ok <- validate_id(id) do
      Server.set_default(store, %{id: id, version: version}, metadata)
    end
  end

  def set_default(%__MODULE__{}, _id, _version, _metadata) do
    {:error,
     error(
       :invalid_argument,
       "set_default/4 requires string id, positive integer version, and map metadata"
     )}
  end

  @doc false
  @spec validate_id(String.t()) :: :ok | {:error, map()}
  def validate_id(id) when is_binary(id) do
    cond do
      id == "" or String.contains?(id, "@") or String.contains?(id, "/") ->
        invalid_id(id)

      not Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_.-]*\z/, id) ->
        invalid_id(id)

      protected_or_curated?(id) ->
        namespace_violation(
          "prelude id `#{id}` collides with a reserved or curated namespace",
          id
        )

      true ->
        :ok
    end
  end

  def validate_id(_), do: invalid_id("non-string")

  defp validate_positive_integer(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 do
      :ok
    else
      {:error, error(:invalid_config, "#{key} must be a positive integer, got #{inspect(value)}")}
    end
  end

  defp invalid_id(id) do
    namespace_violation(
      "invalid prelude id `#{id}`; ids must be namespace ids and may not contain @ or /"
    )
  end

  defp check_source_bound(source, max_bytes) when byte_size(source) <= max_bytes, do: :ok

  defp check_source_bound(source, max_bytes) do
    {:error,
     %{
       reason: :source_too_large,
       message: "prelude source is #{byte_size(source)} bytes; limit is #{max_bytes}",
       limit_bytes: max_bytes
     }}
  end

  defp parent_checksum(metadata) do
    case Map.get(metadata, "parent_checksum") || Map.get(metadata, :parent_checksum) do
      nil ->
        {:ok, nil}

      checksum when is_binary(checksum) ->
        {:ok, checksum}

      other ->
        {:error,
         error(:invalid_metadata, "parent_checksum must be a string, got #{inspect(other)}")}
    end
  end

  defp check_parent(_store, _id, nil), do: :ok

  defp check_parent(store, id, checksum) do
    case read(store, id) do
      {:ok, candidate} ->
        actual = PreludeCandidate.checksum(candidate)

        if actual == checksum do
          :ok
        else
          stale_base(checksum, actual)
        end

      {:error, %{reason: :not_found}} ->
        stale_base(checksum, nil)

      {:error, _} = error ->
        error
    end
  end

  defp compile_bounded(source, opts) do
    case Sandbox.run_bounded(fn -> Compiler.compile(source) end,
           timeout: Keyword.get(opts, :compile_timeout, @default_compile_timeout),
           max_heap: Keyword.get(opts, :compile_max_heap, @default_compile_max_heap)
         ) do
      {:ok, {:ok, %Prelude{} = compiled}} ->
        {:ok, compiled}

      {:ok, {:error, %ValidationError{} = error}} ->
        {:error,
         %{
           reason: :prelude_compile_error,
           message: error.message,
           compile_reason: error.reason,
           namespace: error.namespace,
           ref: error.ref
         }}

      {:error, {:timeout, timeout}} ->
        {:error, %{reason: :compile_timeout, message: "prelude compile exceeded #{timeout}ms"}}

      {:error, {:memory_exceeded, bytes}} ->
        {:error,
         %{reason: :compile_memory_exceeded, message: "prelude compile exceeded #{bytes} bytes"}}

      {:error, {:execution_error, message}} ->
        {:error,
         %{reason: :prelude_compile_error, message: message, compile_reason: :compile_error}}
    end
  end

  defp validate_compiled_namespace(id, %Prelude{namespaces: [id]}) do
    if protected_or_curated?(id) do
      namespace_violation(
        "prelude namespace `#{id}` collides with a reserved or curated namespace",
        id
      )
    else
      :ok
    end
  end

  defp validate_compiled_namespace(id, %Prelude{namespaces: namespaces}) do
    namespace_violation(
      "compiled namespaces must be exactly #{inspect([id])}, got #{inspect(namespaces)}",
      List.first(namespaces)
    )
  end

  defp protected_or_curated?(id) do
    ProtectedNamespaces.reserved?(id) or id in Discovery.reserved_namespace_names()
  end

  defp parse_ref(id) when is_binary(id) do
    case String.split(id, "@", parts: 2) do
      [bare] ->
        with :ok <- validate_id(bare), do: {:ok, %{id: bare}}

      [bare, version] ->
        with :ok <- validate_id(bare),
             {int, ""} when int > 0 <- Integer.parse(version) do
          {:ok, %{id: bare, version: int}}
        else
          _ -> {:error, error(:invalid_ref, "invalid prelude ref `#{id}`")}
        end
    end
  end

  defp parse_ref(ref) when is_map(ref) do
    id = Map.get(ref, :id) || Map.get(ref, "id")
    version = Map.get(ref, :version) || Map.get(ref, "version")
    checksum = Map.get(ref, :checksum) || Map.get(ref, "checksum")

    with true <- is_binary(id),
         :ok <- validate_id(id),
         true <- is_integer(version) and version > 0,
         true <- is_nil(checksum) or is_binary(checksum) do
      {:ok, %{id: id, version: version, checksum: checksum}}
    else
      _ -> {:error, error(:invalid_ref, "invalid prelude ref #{inspect(ref, limit: 5)}")}
    end
  end

  defp parse_ref(ref), do: {:error, error(:invalid_ref, "invalid prelude ref #{inspect(ref)}")}

  defp namespace_violation(message, namespace \\ nil) do
    {:error, %{reason: :prelude_namespace_violation, message: message, namespace: namespace}}
  end

  defp stale_base(expected, actual) do
    {:error,
     %{
       reason: :stale_base,
       message: "parent_checksum does not match current prelude checksum",
       expected_parent_checksum: expected,
       actual_parent_checksum: actual
     }}
  end

  defp error(reason, message), do: %{reason: reason, message: message}
end
