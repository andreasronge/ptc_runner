defmodule PtcRunnerMcp.CatalogBuiltins do
  @moduledoc """
  Builds the catalog executor closure for PTC-Lisp `catalog/` builtins.

  The catalog executor follows the same closure-capture pattern as
  `AggregatorTools.build/1`: it captures the per-program `call_context`
  (with `catalog_op_counter`, shared `failure_cache` and `ensure_locks`)
  and the registry GenServer name, so `pmap` children see the same
  atomic counters without shared mutable state.

  ## Error model

  Follows the aggregator's programmer-fault / world-fault split:

    * Programmer faults return `{:programmer_fault, message}` — the
      eval layer raises `ExecutionError`.
    * World faults return `{:world_fault, reason}` — the eval layer
      returns `nil` to the program.
    * Success returns `{:ok, value}`.
  """

  alias PtcRunnerMcp.Upstream.Registry
  alias PtcRunnerMcp.UpstreamCalls

  @type result :: {:ok, term()} | {:world_fault, atom()} | {:programmer_fault, String.t()}

  @doc """
  Builds a catalog executor closure for the given call context.

  The closure accepts `(operation, args)` and returns a result tuple.
  """
  @spec build(UpstreamCalls.call_context(), keyword()) :: (atom(), list() -> result())
  def build(call_context, opts \\ []) when is_map(call_context) do
    registry = Keyword.get(opts, :registry, Registry)
    catalog_config = Keyword.get(opts, :catalog_config, PtcRunnerMcp.CatalogConfig.get())

    fn operation, args ->
      case UpstreamCalls.check_catalog_cap(call_context) do
        :proceed ->
          dispatch(operation, args, call_context, registry, catalog_config)

        :cap_exhausted ->
          {:world_fault, :catalog_cap_exhausted}
      end
    end
  end

  # ----------------------------------------------------------------
  # Dispatch
  # ----------------------------------------------------------------

  defp dispatch(:summary, [], _call_context, registry, catalog_config) do
    all_info = all_server_info(registry)

    result = %{
      "mode" => Atom.to_string(catalog_config.catalog_mode),
      "servers" =>
        Enum.map(all_info, fn info ->
          server_summary_map(info)
        end),
      "catalogs_loaded" => Enum.all?(all_info, & &1.catalog_loaded)
    }

    {:ok, result}
  end

  defp dispatch(:list_servers, [], _call_context, registry, _catalog_config) do
    all_info = all_server_info(registry)

    result =
      Enum.map(all_info, fn info ->
        %{
          "name" => info.name,
          "description" => info.description,
          "tool_count" => info.tool_count,
          "catalog_loaded" => info.catalog_loaded
        }
      end)

    {:ok, result}
  end

  defp dispatch(:list_tools, [server | rest], call_context, registry, catalog_config) do
    opts = parse_list_tools_opts(rest)

    with :ok <- validate_list_tools_opts(opts),
         :ok <- check_configured(registry, server, "catalog/list-tools") do
      do_list_tools(server, opts, call_context, registry, catalog_config)
    end
  end

  defp dispatch(:describe_tool, [server, tool], call_context, registry, catalog_config) do
    with :ok <- validate_string_arg(server, "catalog/describe-tool", "server"),
         :ok <- validate_string_arg(tool, "catalog/describe-tool", "tool"),
         :ok <- check_configured(registry, server, "catalog/describe-tool") do
      do_describe_tool(server, tool, call_context, registry, catalog_config)
    end
  end

  defp dispatch(:search_tools, [query | rest], call_context, registry, catalog_config) do
    opts = parse_search_tools_opts(rest)

    with :ok <- validate_query_string(query),
         :ok <- validate_search_tools_opts(opts) do
      do_search_tools(query, opts, call_context, registry, catalog_config)
    end
  end

  defp dispatch(operation, _args, _call_context, _registry, _catalog_config) do
    {:programmer_fault, "unknown catalog operation: #{operation}"}
  end

  # ----------------------------------------------------------------
  # list-tools implementation
  # ----------------------------------------------------------------

  defp do_list_tools(server, opts, call_context, registry, catalog_config) do
    case get_tools_for_server(server, call_context, registry) do
      {:ok, tools} ->
        limit = Map.get(opts, :limit, 50)
        offset = Map.get(opts, :offset, 0)

        sorted =
          tools
          |> Enum.sort_by(&tool_name_of/1)
          |> Enum.drop(offset)
          |> Enum.take(limit)
          |> Enum.map(fn tool -> compact_tool_entry(server, tool) |> catalog_line() end)

        maybe_cap_list_result(sorted, catalog_config.max_catalog_result_bytes)

      {:world_fault, _} = wf ->
        wf
    end
  end

  # ----------------------------------------------------------------
  # describe-tool implementation
  # ----------------------------------------------------------------

  defp do_describe_tool(server, tool_name, call_context, registry, catalog_config) do
    case get_tools_for_server(server, call_context, registry) do
      {:ok, tools} ->
        case Enum.find(tools, fn t -> tool_name_of(t) == tool_name end) do
          nil ->
            {:programmer_fault, "no tool '#{tool_name}' in upstream '#{server}'"}

          tool ->
            result = detailed_tool_entry(server, tool)
            maybe_cap_single_result(result, catalog_config.max_catalog_result_bytes)
        end

      {:world_fault, _} = wf ->
        wf
    end
  end

  # ----------------------------------------------------------------
  # search-tools implementation
  # ----------------------------------------------------------------

  defp do_search_tools(query, opts, call_context, registry, catalog_config) do
    limit = Map.get(opts, :limit, 8)
    load? = Map.get(opts, :load, false)
    query_tokens = tokenize(query)

    all_info = all_server_info(registry)

    {loaded_servers, unloaded_servers} =
      Enum.split_with(all_info, & &1.catalog_loaded)

    loaded_results =
      Enum.flat_map(loaded_servers, fn info ->
        case Registry.cached_tools(info.name, registry) do
          tools when is_list(tools) ->
            score_tools(info, tools, query_tokens)

          nil ->
            []
        end
      end)

    {extra_loaded_results, unloaded_results} =
      if load? do
        newly_loaded =
          Enum.flat_map(unloaded_servers, fn info ->
            case get_tools_for_server(info.name, call_context, registry) do
              {:ok, tools} -> score_tools(info, tools, query_tokens)
              {:world_fault, _} -> []
            end
          end)

        {newly_loaded, []}
      else
        server_level =
          unloaded_servers
          |> Enum.map(fn info -> score_server_level(info, query_tokens) end)
          |> Enum.filter(fn {score, _entry} -> score > 0 end)

        {[], server_level}
      end

    all_results =
      (loaded_results ++ extra_loaded_results ++ unloaded_results)
      |> Enum.sort_by(fn {score, entry} ->
        {-score, entry["server"] || "", entry["tool"] || ""}
      end)
      |> Enum.take(limit)
      |> Enum.map(fn {_score, entry} -> catalog_line(entry) end)

    maybe_cap_list_result(all_results, catalog_config.max_catalog_result_bytes)
  end

  defp score_tools(server_info, tools, query_tokens) do
    server_tokens = tokenize(server_info.name)

    server_desc_tokens =
      tokenize(server_info.description || "") ++
        tokenize_capabilities(server_info.capabilities)

    server_name_score = score_tokens(query_tokens, server_tokens, 2)
    server_desc_score = score_tokens(query_tokens, server_desc_tokens, 0)
    server_score = server_name_score + server_desc_score

    scored =
      Enum.map(tools, fn tool ->
        tool_name = tool_name_of(tool)
        tool_desc = tool_description(tool)
        arg_keys = tool_arg_keys(tool)
        annotations = tool_annotations(tool)

        tool_name_tokens = tokenize(tool_name)
        tool_desc_tokens = tokenize(tool_desc)
        arg_tokens = Enum.flat_map(arg_keys, &tokenize/1)
        annotation_tokens = tokenize_annotations(annotations)

        tool_score =
          score_tokens(query_tokens, tool_name_tokens, 2) +
            score_tokens(query_tokens, tool_desc_tokens, 0) +
            score_tokens(query_tokens, arg_tokens, 0) +
            score_tokens(query_tokens, annotation_tokens, 0)

        entry = compact_tool_entry(server_info.name, tool) |> Map.put("catalog_loaded", true)
        {tool_score, server_score + tool_score, entry}
      end)

    # Issue #944 finding #4: keep a tool only when one of these is true:
    #   * the tool itself matched (name/desc/args/annotations), or
    #   * no tool matched specifically AND the server NAME matched (a
    #     query like "warehouse" against a loaded `warehouse` server
    #     should still surface its tools)
    # A pure server-description/capability overlap (e.g. desc contains
    # "search capability" but no tool mentions search) is NOT enough —
    # that was the reporter's noise.
    any_tool_match? = Enum.any?(scored, fn {tool_score, _, _} -> tool_score > 0 end)
    server_name_match? = server_name_score > 0

    scored
    |> Enum.filter(fn {tool_score, total, _} ->
      cond do
        tool_score > 0 -> true
        any_tool_match? -> false
        server_name_match? -> total > 0
        true -> false
      end
    end)
    |> Enum.map(fn {_, total, entry} -> {total, entry} end)
  end

  defp score_server_level(server_info, query_tokens) do
    server_tokens = tokenize(server_info.name)

    desc_tokens =
      tokenize(server_info.description || "") ++
        tokenize_capabilities(server_info.capabilities)

    name_score = score_tokens(query_tokens, server_tokens, 2)
    desc_score = score_tokens(query_tokens, desc_tokens, 0)
    total = name_score + desc_score

    entry = %{
      "server" => server_info.name,
      "tool" => nil,
      "summary" => "#{server_info.description || server_info.name}. Catalog not loaded.",
      "catalog_loaded" => false,
      "next" => "(catalog/list-tools \"#{server_info.name}\" {:limit 20})"
    }

    {total, entry}
  end

  defp score_tokens(query_tokens, target_tokens, name_boost) do
    Enum.reduce(query_tokens, 0, fn qt, acc ->
      best =
        Enum.reduce(target_tokens, 0, fn tt, best ->
          cond do
            qt == tt -> max(best, 10 + name_boost)
            String.starts_with?(tt, qt) -> max(best, 5 + name_boost)
            String.contains?(tt, qt) -> max(best, 2 + name_boost)
            true -> best
          end
        end)

      acc + best
    end)
  end

  defp tokenize(text) when is_binary(text) do
    text
    |> split_camel_case()
    |> String.replace(~r/[_\-\s]+/, " ")
    |> String.downcase()
    |> String.split()
    |> Enum.reject(&(&1 == ""))
  end

  defp tokenize(_), do: []

  defp split_camel_case(text) do
    Regex.replace(~r/([a-z])([A-Z])/, text, "\\1 \\2")
  end

  defp tokenize_capabilities(caps) when is_list(caps) do
    Enum.flat_map(caps, &tokenize(to_string(&1)))
  end

  defp tokenize_capabilities(_), do: []

  defp tokenize_annotations(annotations) do
    annotations
    |> Enum.flat_map(fn {k, v} ->
      tokenize(to_string(k)) ++ tokenize(to_string(v))
    end)
  end

  # ----------------------------------------------------------------
  # Shared: get tools for a server (with ensure_started)
  # ----------------------------------------------------------------

  defp get_tools_for_server(server, call_context, registry) do
    case Registry.cached_tools(server, registry) do
      tools when is_list(tools) ->
        {:ok, tools}

      nil ->
        ensure_and_get_tools(server, call_context, registry)
    end
  end

  defp ensure_and_get_tools(server, call_context, registry) do
    case UpstreamCalls.cached_failure(call_context, server) do
      {:cached, _reason, _detail} ->
        {:world_fault, :upstream_unavailable}

      :miss ->
        do_ensure_and_get_tools(server, call_context, registry)
    end
  end

  defp do_ensure_and_get_tools(server, call_context, registry) do
    case UpstreamCalls.acquire_ensure_lock(call_context, server) do
      :leader ->
        case Registry.ensure_started(server, registry) do
          {:ok, _info} ->
            :ok = UpstreamCalls.publish_ensure_result(call_context, server, :ok)

            case Registry.cached_tools(server, registry) do
              tools when is_list(tools) -> {:ok, tools}
              nil -> {:world_fault, :upstream_unavailable}
            end

          {:error, reason, detail, _info} ->
            :ok = UpstreamCalls.mark_failure(call_context, server, reason, detail)

            :ok =
              UpstreamCalls.publish_ensure_result(call_context, server, {:error, reason, detail})

            {:world_fault, :upstream_unavailable}
        end

      :follower ->
        timeout_ms = call_context.call_timeout_ms

        case UpstreamCalls.await_ensure_result(call_context, server, timeout_ms) do
          :ok ->
            case Registry.cached_tools(server, registry) do
              tools when is_list(tools) -> {:ok, tools}
              nil -> {:world_fault, :upstream_unavailable}
            end

          {:error, _reason, _detail} ->
            {:world_fault, :upstream_unavailable}
        end
    end
  end

  # ----------------------------------------------------------------
  # Option parsing and validation
  # ----------------------------------------------------------------

  defp parse_list_tools_opts(rest), do: parse_catalog_opts(rest)

  defp validate_list_tools_opts(opts) do
    limit = Map.get(opts, :limit, 50)
    offset = Map.get(opts, :offset, 0)

    cond do
      not is_integer(limit) or limit < 1 or limit > 200 ->
        {:programmer_fault,
         "catalog/list-tools :limit must be an integer 1..200, got #{inspect(limit)}"}

      not is_integer(offset) or offset < 0 ->
        {:programmer_fault,
         "catalog/list-tools :offset must be a non-negative integer, got #{inspect(offset)}"}

      true ->
        :ok
    end
  end

  defp parse_search_tools_opts(rest), do: parse_catalog_opts(rest)

  defp parse_catalog_opts([]), do: %{}

  defp parse_catalog_opts([opts]) when is_map(opts) do
    Map.new(opts, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {safe_to_atom(k), v}
      kv -> kv
    end)
  end

  defp parse_catalog_opts(_), do: %{}

  defp validate_search_tools_opts(opts) do
    limit = Map.get(opts, :limit, 8)
    load = Map.get(opts, :load, false)

    cond do
      not is_integer(limit) or limit < 1 or limit > 50 ->
        {:programmer_fault,
         "catalog/search-tools :limit must be an integer 1..50, got #{inspect(limit)}"}

      not is_boolean(load) ->
        {:programmer_fault, "catalog/search-tools :load must be a boolean, got #{inspect(load)}"}

      true ->
        :ok
    end
  end

  defp validate_query_string(value) do
    if is_binary(value) and String.trim(value) != "" do
      :ok
    else
      {:programmer_fault,
       "catalog/search-tools requires query (non-empty string), got #{inspect(value)}"}
    end
  end

  defp validate_string_arg(value, form, arg_name) do
    if is_binary(value) and value != "" do
      :ok
    else
      {:programmer_fault,
       "#{form} requires #{arg_name} (non-empty string), got #{inspect(value)}"}
    end
  end

  defp check_configured(registry, server, form) do
    with :ok <- validate_string_arg(server, form, "server") do
      if Registry.configured?(server, registry) do
        :ok
      else
        {:programmer_fault, "no upstream '#{server}' configured"}
      end
    end
  end

  # ----------------------------------------------------------------
  # Result size capping (§8.1)
  # ----------------------------------------------------------------

  defp maybe_cap_list_result(items, max_bytes) do
    case Jason.encode(items) do
      {:ok, json} when byte_size(json) <= max_bytes ->
        {:ok, items}

      {:ok, _json} ->
        truncated = truncate_list_to_fit(items, max_bytes)

        if truncated == [] do
          {:world_fault, :catalog_result_too_large}
        else
          {:ok, truncated}
        end

      {:error, _} ->
        {:world_fault, :catalog_result_too_large}
    end
  end

  defp truncate_list_to_fit(items, max_bytes) do
    do_truncate(items, [], 0, max_bytes)
  end

  defp do_truncate([], acc, _size, _max), do: Enum.reverse(acc)

  defp do_truncate([item | rest], acc, current_size, max_bytes) do
    case Jason.encode(item) do
      {:ok, json} ->
        item_size = byte_size(json) + 1
        new_size = current_size + item_size

        if new_size + 2 <= max_bytes do
          do_truncate(rest, [item | acc], new_size, max_bytes)
        else
          Enum.reverse(acc)
        end

      {:error, _} ->
        Enum.reverse(acc)
    end
  end

  defp maybe_cap_single_result(result, max_bytes) do
    case Jason.encode(result) do
      {:ok, json} when byte_size(json) <= max_bytes ->
        {:ok, result}

      _ ->
        {:world_fault, :catalog_result_too_large}
    end
  end

  # ----------------------------------------------------------------
  # Server info helpers
  # ----------------------------------------------------------------

  defp all_server_info(registry) do
    routings =
      try do
        GenServer.call(registry, :all_routings)
      catch
        :exit, _ -> %{}
      end

    routings
    |> Enum.map(fn {name, routing} ->
      cached_tools = Registry.cached_tools(name, registry)
      metadata = Map.get(routing, :metadata, %{})

      %{
        name: name,
        description: Map.get(metadata, :description, Map.get(metadata, "description", name)),
        capabilities: Map.get(metadata, :capabilities, Map.get(metadata, "capabilities")),
        tool_count: if(is_list(cached_tools), do: length(cached_tools), else: nil),
        catalog_loaded: is_list(cached_tools)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp server_summary_map(info) do
    base = %{
      "name" => info.name,
      "description" => info.description,
      "tool_count" => info.tool_count
    }

    case info.capabilities do
      caps when is_list(caps) and caps != [] -> Map.put(base, "capabilities", caps)
      _ -> base
    end
  end

  # ----------------------------------------------------------------
  # Tool entry formatting
  # ----------------------------------------------------------------

  defp compact_tool_entry(server, tool) do
    annotations = tool_annotations(tool)

    %{
      "server" => server,
      "tool" => tool_name_of(tool),
      "summary" => tool_description(tool),
      "input_schema" => tool_input_schema(tool),
      "output_schema" => tool_output_schema(tool),
      "arg_keys" => tool_arg_keys(tool),
      "read_only" =>
        Map.get(annotations, "readOnlyHint", Map.get(annotations, :readOnlyHint, true))
    }
  end

  defp detailed_tool_entry(server, tool) do
    name = tool_name_of(tool)
    annotations = tool_annotations(tool)
    input_schema = tool_input_schema(tool)
    arg_keys = tool_arg_keys(tool)
    required = tool_required_keys(tool)

    %{
      "server" => server,
      "tool" => name,
      "summary" => tool_description(tool),
      "description" => tool_full_description(tool),
      "input_schema" => input_schema,
      "output_schema" => tool_output_schema(tool),
      "arg_keys" => arg_keys,
      "required" => required,
      "annotations" => annotations,
      "call_example" => build_call_example(server, name, arg_keys, required),
      "response_notes" =>
        "`tool/mcp-call` returns `Result<T>`; success has `:value T`, failure has `:reason`/`:message`."
    }
    |> detailed_tool_text()
  end

  defp catalog_line(%{"tool" => nil} = entry) do
    summary = compact_text(Map.get(entry, "summary") || "")
    next = Map.get(entry, "next")
    "#{entry["server"]}: #{summary} Use #{next}."
  end

  defp catalog_line(entry) when is_map(entry) do
    server = Map.fetch!(entry, "server")
    tool = Map.fetch!(entry, "tool")
    args = render_args(Map.get(entry, "input_schema", %{}))
    output = render_output(Map.get(entry, "output_schema"))
    summary = compact_text(Map.get(entry, "summary") || "")
    description = if summary == "", do: "", else: " - #{summary}"
    "#{server}.#{tool}(#{args})#{output}#{description}"
  end

  defp detailed_tool_text(entry) when is_map(entry) do
    line = catalog_line(entry)
    call_example = Map.fetch!(entry, "call_example")
    required = Map.get(entry, "required", [])

    [
      line,
      "",
      "Required args: #{required_args_text(required)}",
      "",
      "Use:",
      call_example,
      "",
      "Returns: `Result<T>`; if `(:ok r)`, use `(:value r)` as T."
    ]
    |> Enum.join("\n")
  end

  defp required_args_text([]), do: "none"

  defp required_args_text(required) when is_list(required) do
    Enum.map_join(required, ", ", &":#{&1}")
  end

  defp build_call_example(server, name, arg_keys, required) do
    placeholders =
      cond do
        required != [] -> required
        arg_keys != [] -> Enum.take(arg_keys, 1)
        true -> []
      end

    args_clause =
      case placeholders do
        [] ->
          " :args {}"

        keys ->
          inner = Enum.map_join(keys, " ", fn k -> ":#{k} ..." end)
          " :args {#{inner}}"
      end

    "(tool/mcp-call {:server \"#{server}\" :tool \"#{name}\"#{args_clause}})"
  end

  # ----------------------------------------------------------------
  # Tool schema accessors (handle both atom and string keys)
  # ----------------------------------------------------------------

  defp tool_name_of(%{name: n}) when is_binary(n), do: n
  defp tool_name_of(%{"name" => n}) when is_binary(n), do: n
  defp tool_name_of(_), do: ""

  defp tool_description(%{description: d}) when is_binary(d), do: d
  defp tool_description(%{"description" => d}) when is_binary(d), do: d
  defp tool_description(tool), do: tool_name_of(tool)

  defp tool_full_description(%{description: d}) when is_binary(d), do: d
  defp tool_full_description(%{"description" => d}) when is_binary(d), do: d
  defp tool_full_description(_), do: ""

  defp tool_input_schema(%{input_schema: s}) when is_map(s), do: s
  defp tool_input_schema(%{"input_schema" => s}) when is_map(s), do: s
  defp tool_input_schema(%{inputSchema: s}) when is_map(s), do: s
  defp tool_input_schema(%{"inputSchema" => s}) when is_map(s), do: s
  defp tool_input_schema(_), do: %{}

  defp tool_annotations(%{annotations: a}) when is_map(a), do: a
  defp tool_annotations(%{"annotations" => a}) when is_map(a), do: a
  defp tool_annotations(_), do: %{}

  defp tool_output_schema(%{output_schema: s}) when is_map(s), do: s
  defp tool_output_schema(%{"output_schema" => s}) when is_map(s), do: s
  defp tool_output_schema(%{outputSchema: s}) when is_map(s), do: s
  defp tool_output_schema(%{"outputSchema" => s}) when is_map(s), do: s
  defp tool_output_schema(_), do: nil

  defp tool_arg_keys(tool) do
    schema = tool_input_schema(tool)

    properties =
      Map.get(schema, "properties", Map.get(schema, :properties, %{}))

    properties
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp tool_required_keys(tool) do
    schema = tool_input_schema(tool)

    required =
      Map.get(schema, "required", Map.get(schema, :required, []))

    case required do
      list when is_list(list) ->
        list
        |> Enum.map(&to_string/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp render_args(schema) when is_map(schema) do
    properties = Map.get(schema, "properties", Map.get(schema, :properties, %{}))
    required = Map.get(schema, "required", Map.get(schema, :required, []))

    properties_by_string =
      Map.new(properties, fn {key, value} -> {to_string(key), value} end)

    required_names =
      required
      |> Enum.map(&to_string/1)
      |> Enum.filter(&Map.has_key?(properties_by_string, &1))

    required_set = MapSet.new(required_names)

    optional_names =
      properties_by_string
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(required_set, &1))
      |> Enum.sort()

    (required_names ++ optional_names)
    |> Enum.map_join(", ", fn name ->
      optional = if MapSet.member?(required_set, name), do: "", else: "?"
      "#{name}: #{render_arg_type(Map.fetch!(properties_by_string, name))}#{optional}"
    end)
  end

  defp render_args(_), do: ""

  defp render_output(schema) when is_map(schema) do
    case render_output_type(schema) do
      "" -> ""
      type -> " -> Result<#{type}>"
    end
  end

  defp render_output(_), do: ""

  defp render_arg_type(schema) when is_map(schema) do
    cond do
      Map.has_key?(schema, "const") or Map.has_key?(schema, :const) ->
        "const"

      is_list(Map.get(schema, "enum", Map.get(schema, :enum))) ->
        "enum"

      true ->
        case Map.get(schema, "type", Map.get(schema, :type)) do
          "string" -> "string"
          "integer" -> "integer"
          "number" -> "number"
          "boolean" -> "boolean"
          "object" -> "object"
          "array" -> "array"
          list when is_list(list) -> Enum.map_join(list, "|", &to_string/1)
          nil -> infer_arg_type(schema)
          other -> to_string(other)
        end
    end
  end

  defp render_arg_type(_), do: "any"

  defp infer_arg_type(schema) do
    cond do
      Map.has_key?(schema, "properties") or Map.has_key?(schema, :properties) -> "object"
      Map.has_key?(schema, "items") or Map.has_key?(schema, :items) -> "array"
      true -> "any"
    end
  end

  defp render_output_type(schema) when is_map(schema) do
    case Map.get(schema, "type", Map.get(schema, :type)) do
      "string" -> ":string"
      "integer" -> ":int"
      "number" -> ":float"
      "boolean" -> ":bool"
      "array" -> "[:any]"
      "object" -> render_output_object(schema)
      _ -> ""
    end
  end

  defp render_output_type(_), do: ""

  defp render_output_object(schema) do
    properties = Map.get(schema, "properties", Map.get(schema, :properties, %{}))

    if is_map(properties) and map_size(properties) > 0 do
      required =
        case Map.get(schema, "required", Map.get(schema, :required, [])) do
          list when is_list(list) -> Enum.map(list, &to_string/1)
          _ -> []
        end

      fields =
        properties
        |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
        |> Enum.take(5)
        |> Enum.map_join(", ", fn {key, value} ->
          key = to_string(key)
          optional = if key in required, do: "", else: "?"
          "#{key} #{render_output_type(value)}#{optional}"
        end)

      "{#{fields}}"
    else
      ":map"
    end
  end

  defp compact_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp safe_to_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> str
  end
end
