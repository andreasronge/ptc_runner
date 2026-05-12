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
         :ok <- check_configured(registry, server) do
      do_list_tools(server, opts, call_context, registry, catalog_config)
    end
  end

  defp dispatch(:describe_tool, [server, tool], call_context, registry, catalog_config) do
    with :ok <- validate_string_arg(server, "catalog/describe-tool", "server"),
         :ok <- validate_string_arg(tool, "catalog/describe-tool", "tool"),
         :ok <- check_configured(registry, server) do
      do_describe_tool(server, tool, call_context, registry, catalog_config)
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
          |> Enum.map(fn tool -> compact_tool_entry(server, tool) end)

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

  defp parse_list_tools_opts([]), do: %{}

  defp parse_list_tools_opts([opts]) when is_map(opts) do
    Map.new(opts, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {safe_to_atom(k), v}
      kv -> kv
    end)
  end

  defp parse_list_tools_opts(_), do: %{}

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

  defp validate_string_arg(value, form, arg_name) do
    if is_binary(value) and value != "" do
      :ok
    else
      {:programmer_fault, "#{form} requires #{arg_name} (non-empty string), got #{inspect(value)}"}
    end
  end

  defp check_configured(registry, server) do
    with :ok <- validate_string_arg(server, "catalog/list-tools", "server") do
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
    routings = GenServer.call(registry, :all_routings)

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
      "arg_keys" => tool_arg_keys(tool),
      "read_only" => Map.get(annotations, "readOnlyHint", Map.get(annotations, :readOnlyHint, true))
    }
  end

  defp detailed_tool_entry(server, tool) do
    name = tool_name_of(tool)
    annotations = tool_annotations(tool)
    input_schema = tool_input_schema(tool)
    arg_keys = tool_arg_keys(tool)

    call_args =
      case arg_keys do
        [] -> ""
        [first | _] -> " :args {:#{first} ...}"
      end

    %{
      "server" => server,
      "tool" => name,
      "summary" => tool_description(tool),
      "description" => tool_full_description(tool),
      "input_schema" => input_schema,
      "arg_keys" => arg_keys,
      "annotations" => annotations,
      "call_example" =>
        "(tool/mcp-call {:server \"#{server}\" :tool \"#{name}\"#{call_args}})",
      "response_notes" =>
        "Returns an MCP content envelope. Use mcp/text or mcp/json helpers according to the upstream result shape."
    }
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

  defp tool_input_schema(%{inputSchema: s}) when is_map(s), do: s
  defp tool_input_schema(%{"inputSchema" => s}) when is_map(s), do: s
  defp tool_input_schema(_), do: %{}

  defp tool_annotations(%{annotations: a}) when is_map(a), do: a
  defp tool_annotations(%{"annotations" => a}) when is_map(a), do: a
  defp tool_annotations(_), do: %{}

  defp tool_arg_keys(tool) do
    schema = tool_input_schema(tool)

    properties =
      Map.get(schema, "properties", Map.get(schema, :properties, %{}))

    properties
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp safe_to_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> str
  end
end
