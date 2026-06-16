defmodule PtcRunner.PreludeStore.Tools do
  @moduledoc """
  Private backing tools and public `prelude/` wrapper source for PreludeStore.

  The backing tools are intentionally private PTC-Lisp tools. User programs see
  only the compiled `prelude/` capability prelude; private tool authority is
  enforced by the evaluator origin stack.
  """

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.PreludeCandidate
  alias PtcRunner.PreludeStore

  @list_tool "prelude_store_list"
  @read_tool "prelude_store_read"
  @write_tool "prelude_store_write"
  @reserved_names [@list_tool, @read_tool, @write_tool]

  @prelude_source """
  (ns prelude
    "Read and write versioned capability preludes."
    {:visibility :prompt})

  (defn list
    "List editable preludes in the connected store."
    []
    (tool/prelude_store_list {}))

  (defn read
    "Read a bounded public view of a prelude candidate by id or id@version."
    [id]
    (tool/prelude_store_read {:id id}))

  (defn source
    "Read the bounded source text for a prelude candidate."
    [id]
    (let [candidate (read id)]
      (if (= (get candidate "status") "error")
        (fail candidate)
        (if (get candidate "source_truncated")
          (fail {:reason :source_truncated
                 :message "prelude source exceeds the public read bound; use prelude/read metadata instead"
                 :id id
                 :source_bytes (get candidate "source_bytes")})
          (get candidate "source")))))

  (defn write
    "Write a full namespace source candidate with optional metadata."
    {:effect :write}
    [candidate]
    (tool/prelude_store_write
      {:id (get candidate "id")
       :source (get candidate "source")
       :metadata (get candidate "metadata" {})}))
  """

  @doc "Reserved private backing tool names."
  @spec reserved_names() :: [String.t()]
  def reserved_names, do: @reserved_names

  @doc "Source for the public `prelude/` capability prelude."
  @spec prelude_source() :: String.t()
  def prelude_source, do: @prelude_source

  @doc "Compiled public `prelude/` capability prelude."
  @spec prelude() :: {:ok, Prelude.t()} | {:error, term()}
  def prelude, do: Compiler.compile(@prelude_source)

  @doc """
  Returns private backing tools for `store`.

  Pass `base_tools: existing_tools` to fail closed before merging when the host
  already uses one of the reserved `prelude_store_*` tool names.
  """
  @spec tools(PreludeStore.t(), keyword()) :: map()
  def tools(%PreludeStore{} = store, opts \\ []) when is_list(opts) do
    base_tools = Keyword.get(opts, :base_tools, %{})
    validate_no_reserved_collisions!(base_tools)

    Map.merge(base_tools, private_tools(store))
  end

  @doc "Raises if `tools` contains a reserved private store-tool name."
  @spec validate_no_reserved_collisions!(map()) :: :ok
  def validate_no_reserved_collisions!(tools) when is_map(tools) do
    case Enum.find(Map.keys(tools), &(to_string(&1) in @reserved_names)) do
      nil ->
        :ok

      name ->
        raise ArgumentError,
              "tool name #{inspect(to_string(name))} is reserved for PreludeStore private backing tools"
    end
  end

  defp private_tools(store) do
    %{
      @list_tool =>
        {fn _args -> list_tool(store) end,
         signature: "() -> [:map]",
         description: "List editable prelude candidates.",
         expose: :ptc_lisp,
         visibility: :private},
      @read_tool =>
        {fn args -> read_tool(store, args) end,
         signature: "(id :string) -> :map",
         description: "Read a bounded public prelude candidate view.",
         expose: :ptc_lisp,
         visibility: :private},
      @write_tool =>
        {fn args -> write_tool(store, args) end,
         signature: "(id :string, source :string, metadata :map) -> :map",
         description: "Write a versioned prelude candidate.",
         expose: :ptc_lisp,
         visibility: :private}
    }
  end

  defp list_tool(store) do
    store
    |> PreludeStore.list()
    |> Enum.map(&public_map/1)
  rescue
    e -> store_error(e)
  catch
    kind, reason -> store_error({kind, reason})
  end

  defp read_tool(store, %{"id" => id}) do
    case PreludeStore.read(store, id) do
      {:ok, candidate} -> public_candidate(candidate)
      {:error, error} -> public_error(error)
    end
  rescue
    e -> store_error(e)
  catch
    kind, reason -> store_error({kind, reason})
  end

  defp write_tool(store, %{"id" => id, "source" => source} = args)
       when is_binary(id) and is_binary(source) do
    metadata = Map.get(args, "metadata", %{})
    metadata = if is_map(metadata), do: metadata, else: %{}

    case PreludeStore.write(store, id, source, metadata) do
      {:ok, result} -> public_map(Map.put(result, :status, :ok))
      {:error, error} -> public_error(error)
    end
  rescue
    e -> store_error(e)
  catch
    kind, reason -> store_error({kind, reason})
  end

  defp write_tool(_store, _args) do
    public_error(%{
      reason: :invalid_argument,
      message: "prelude_store_write requires string id and source fields"
    })
  end

  defp public_candidate(%PreludeCandidate{} = candidate) do
    candidate
    |> PreludeCandidate.public_view()
    |> Map.put(:status, :ok)
    |> public_map()
  end

  defp public_error(error) when is_map(error) do
    error
    |> Map.take([:reason, :message, :compile_reason, :namespace, :ref, :limit_bytes])
    |> Map.put(:status, :error)
    |> public_map()
  end

  defp public_error(other) do
    public_error(%{reason: :prelude_store_error, message: inspect(other, limit: 5)})
  end

  defp store_error(error) do
    public_error(%{reason: :prelude_store_error, message: Exception.message(error)})
  rescue
    _ -> public_error(%{reason: :prelude_store_error, message: inspect(error, limit: 5)})
  end

  defp public_map(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, inner} -> {public_key(key), public_map(inner)} end)
  end

  defp public_map(values) when is_list(values), do: Enum.map(values, &public_map/1)
  defp public_map(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp public_map(value) when is_boolean(value) or is_nil(value), do: value
  defp public_map(value) when is_atom(value), do: Atom.to_string(value)
  defp public_map(value), do: value

  defp public_key(key) when is_binary(key), do: key
  defp public_key(key) when is_atom(key), do: Atom.to_string(key)
  defp public_key(key), do: inspect(key)
end
