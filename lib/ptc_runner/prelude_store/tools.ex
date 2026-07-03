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
  @history_tool "prelude_store_history"
  @read_tool "prelude_store_read"
  @write_tool "prelude_store_write"
  @set_default_tool "prelude_store_set_default"
  @forms_tool "prelude_store_forms"
  @form_deps_tool "prelude_store_form_deps"
  @deps_tool "prelude_store_deps"
  @reserved_names [
    @list_tool,
    @history_tool,
    @read_tool,
    @write_tool,
    @set_default_tool,
    @forms_tool,
    @form_deps_tool,
    @deps_tool
  ]
  @max_public_string_bytes 1_024

  @prelude_source """
  (ns prelude
    "Read and write versioned capability preludes."
    {:visibility :prompt})

  (defn list
    "List editable preludes in the connected store."
    []
    (tool/prelude_store_list {}))

  (defn history
    "List version history for one editable prelude id."
    [id]
    (tool/prelude_store_history {:id id}))

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

  (defn forms
    "List a stored prelude's top-level forms (public and private) by id or
     id@version: name, visibility, kind, arity, and a bounded docstring."
    [id]
    (tool/prelude_store_forms {:id id}))

  (defn form-deps
    "Show one named form's direct sibling calls (with each call's own
     visibility) plus the form's requires/tool-refs split into direct (its own
     body) and transitive (through the siblings it calls)."
    [id name]
    (tool/prelude_store_form_deps {:id id :name name}))

  (defn deps
    "Show the whole intra-namespace direct-reference graph for a stored
     prelude: every form name (including unreferenced private helpers) mapped
     to the sibling names it directly calls."
    [id]
    (tool/prelude_store_deps {:id id}))

  (defn write
    "Write a full namespace source candidate with optional metadata."
    {:effect :write}
    [candidate]
    (let [metadata (get candidate "metadata" {})]
      (tool/prelude_store_write
        {:id (get candidate "id")
         :source (get candidate "source")
         :metadata (if (map? metadata) metadata {})})))

  (defn set-default
    "Move the bare-id default to an existing version, optionally checksum-pinned."
    {:effect :write}
    [selection]
    (let [metadata (get selection "metadata" {})
          base {:id (get selection "id")
                :version (get selection "version")
                :metadata (if (map? metadata) metadata {})}
          checksum (get selection "checksum")]
      (tool/prelude_store_set_default
        (if checksum
          (assoc base :checksum checksum)
          base))))
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
      @history_tool =>
        {fn args -> history_tool(store, args) end,
         signature: "(id :string) -> [:map]",
         description: "List version history for an editable prelude candidate.",
         expose: :ptc_lisp,
         visibility: :private},
      @read_tool =>
        {fn args -> read_tool(store, args) end,
         signature: "(id :string) -> :map",
         description: "Read a bounded public prelude candidate view.",
         expose: :ptc_lisp,
         visibility: :private},
      @forms_tool =>
        {fn args -> forms_tool(store, args) end,
         signature: "(id :string) -> [:map]",
         description: "List a stored prelude's top-level forms (public and private).",
         expose: :ptc_lisp,
         visibility: :private},
      @form_deps_tool =>
        {fn args -> form_deps_tool(store, args) end,
         signature: "(id :string, name :string) -> :map",
         description: "Show one form's sibling calls and direct/transitive authority.",
         expose: :ptc_lisp,
         visibility: :private},
      @deps_tool =>
        {fn args -> deps_tool(store, args) end,
         signature: "(id :string) -> :map",
         description: "Show the whole intra-namespace direct-reference graph.",
         expose: :ptc_lisp,
         visibility: :private},
      @write_tool =>
        {fn args -> write_tool(store, args) end,
         signature: "(id :string, source :string, metadata :map) -> :map",
         description: "Write a versioned prelude candidate.",
         expose: :ptc_lisp,
         visibility: :private},
      @set_default_tool =>
        {fn args -> set_default_tool(store, args) end,
         signature: "(id :string, version :int, checksum :string?, metadata :map) -> :map",
         description: "Move the editable prelude default to an existing version.",
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

  defp history_tool(store, %{"id" => id}) when is_binary(id) do
    case PreludeStore.history(store, id) do
      {:ok, rows} -> public_map(rows)
      {:error, error} -> public_error(error)
    end
  rescue
    e -> store_error(e)
  catch
    kind, reason -> store_error({kind, reason})
  end

  defp history_tool(_store, _args) do
    public_error(%{
      reason: :invalid_argument,
      message: "prelude_store_history requires a string id field"
    })
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

  defp forms_tool(store, %{"id" => id}) when is_binary(id) do
    case resolve_form_graph(store, id) do
      {:ok, ns_graph} -> public_map(forms_rows(ns_graph))
      {:error, error} -> public_error(error)
    end
  rescue
    e -> store_error(e)
  catch
    kind, reason -> store_error({kind, reason})
  end

  defp forms_tool(_store, _args) do
    public_error(%{
      reason: :invalid_argument,
      message: "prelude_store_forms requires a string id field"
    })
  end

  defp form_deps_tool(store, %{"id" => id, "name" => name})
       when is_binary(id) and is_binary(name) do
    case resolve_form_graph(store, id) do
      {:ok, ns_graph} ->
        case Map.fetch(ns_graph, name) do
          {:ok, entry} ->
            public_map(form_deps_view(name, entry, ns_graph))

          :error ->
            public_error(%{
              reason: :form_not_found,
              message: "prelude form `#{name}` not found in `#{id}`",
              id: id,
              name: name
            })
        end

      {:error, error} ->
        public_error(error)
    end
  rescue
    e -> store_error(e)
  catch
    kind, reason -> store_error({kind, reason})
  end

  defp form_deps_tool(_store, _args) do
    public_error(%{
      reason: :invalid_argument,
      message: "prelude_store_form_deps requires string id and name fields"
    })
  end

  defp deps_tool(store, %{"id" => id}) when is_binary(id) do
    case resolve_form_graph(store, id) do
      {:ok, ns_graph} -> public_map(deps_view(ns_graph))
      {:error, error} -> public_error(error)
    end
  rescue
    e -> store_error(e)
  catch
    kind, reason -> store_error({kind, reason})
  end

  defp deps_tool(_store, _args) do
    public_error(%{
      reason: :invalid_argument,
      message: "prelude_store_deps requires a string id field"
    })
  end

  # Resolves `id`/`id@version` the same way `prelude_store_read` does, then
  # projects the namespace's `form_graph` submap. A store id always compiles to
  # exactly one namespace == id (`validate_compiled_namespace`), so the
  # candidate's own id is the graph key.
  defp resolve_form_graph(store, id) do
    case PreludeStore.read(store, id) do
      {:ok, %PreludeCandidate{id: namespace, compiled: %Prelude{form_graph: form_graph}}} ->
        {:ok, Map.get(form_graph, namespace, %{})}

      {:error, _} = error ->
        error
    end
  end

  defp forms_rows(ns_graph) do
    ns_graph
    |> Enum.map(fn {name, entry} ->
      %{
        name: name,
        visibility: entry.visibility,
        kind: entry.kind,
        arity: entry.arity,
        doc: bound_public_doc(entry.doc)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp form_deps_view(name, entry, ns_graph) do
    %{
      name: name,
      visibility: entry.visibility,
      calls:
        entry.calls
        |> Enum.map(&%{name: &1, visibility: Map.fetch!(ns_graph, &1).visibility})
        |> Enum.sort_by(& &1.name),
      requires: entry.requires,
      tool_refs: entry.tool_refs
    }
  end

  defp deps_view(ns_graph) do
    Map.new(ns_graph, fn {name, entry} -> {name, Enum.sort(entry.calls)} end)
  end

  defp write_tool(store, %{"id" => id, "source" => source} = args)
       when is_binary(id) and is_binary(source) do
    metadata = store_tool_metadata(Map.get(args, "metadata", %{}))

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

  defp set_default_tool(store, %{"id" => id, "version" => version} = args)
       when is_binary(id) and is_integer(version) do
    metadata = store_tool_metadata(Map.get(args, "metadata", %{}))

    ref =
      case Map.get(args, "checksum") do
        checksum when is_binary(checksum) -> %{id: id, version: version, checksum: checksum}
        _ -> %{id: id, version: version}
      end

    case PreludeStore.set_default(store, ref, metadata) do
      {:ok, result} -> public_map(Map.put(result, :status, :ok))
      {:error, error} -> public_error(error)
    end
  rescue
    e -> store_error(e)
  catch
    kind, reason -> store_error({kind, reason})
  end

  defp set_default_tool(_store, _args) do
    public_error(%{
      reason: :invalid_argument,
      message: "prelude_store_set_default requires string id and integer version fields"
    })
  end

  defp store_tool_metadata(metadata) do
    PreludeCandidate.public_metadata(metadata, complex: :drop)
  end

  defp public_candidate(%PreludeCandidate{} = candidate) do
    candidate
    |> PreludeCandidate.public_view()
    |> Map.put(:status, :ok)
    |> public_map()
  end

  defp public_error(error) when is_map(error) do
    error
    |> Map.take([
      :reason,
      :message,
      :compile_reason,
      :namespace,
      :ref,
      :limit,
      :limit_bytes,
      :id,
      :name
    ])
    |> bound_public_error_strings()
    |> Map.put(:status, :error)
    |> public_map()
  end

  defp bound_public_error_strings(error) do
    Map.new(error, fn
      {key, value} when is_binary(value) ->
        {key, bound_public_string(value, @max_public_string_bytes)}

      entry ->
        entry
    end)
  end

  defp bound_public_doc(nil), do: nil

  defp bound_public_doc(doc) when is_binary(doc),
    do: bound_public_string(doc, @max_public_string_bytes)

  defp bound_public_string(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp bound_public_string(value, max_bytes) do
    suffix = "... [truncated; #{byte_size(value)} bytes total]"
    prefix_bytes = max(max_bytes - byte_size(suffix), 0)
    truncate_utf8(value, prefix_bytes) <> suffix
  end

  defp truncate_utf8(_value, max_bytes) when max_bytes <= 0, do: ""

  defp truncate_utf8(value, max_bytes) do
    chunk = binary_part(value, 0, min(byte_size(value), max_bytes))

    if String.valid?(chunk) do
      chunk
    else
      truncate_utf8(value, max_bytes - 1)
    end
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
