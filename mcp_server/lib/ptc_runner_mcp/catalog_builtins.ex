defmodule PtcRunnerMcp.CatalogBuiltins do
  @moduledoc """
  Builds the discovery executor closure for PTC-Lisp REPL discovery forms.

  The discovery executor follows the same closure-capture pattern as
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

  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunnerMcp.Upstream.Registry
  alias PtcRunnerMcp.UpstreamCalls

  @type result :: {:ok, term()} | {:world_fault, atom()} | {:programmer_fault, String.t()}

  @doc """
  Builds a discovery executor closure for the given call context.

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

  defp dispatch(:servers, [], _call_context, registry, _catalog_config) do
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

  defp dispatch(:dir, [server | rest], call_context, registry, catalog_config) do
    with {:ok, opts} <- parse_dir_opts(rest),
         :ok <- validate_dir_opts(opts),
         :ok <- check_configured(registry, server, "dir") do
      do_dir(server, opts, call_context, registry, catalog_config)
    end
  end

  defp dispatch(:doc, [ref], call_context, registry, catalog_config) do
    with {:ok, server, tool} <- parse_tool_ref(ref, "doc", registry),
         :ok <- check_configured(registry, server, "doc") do
      do_doc(server, tool, call_context, registry, catalog_config)
    end
  end

  defp dispatch(:meta, [ref], call_context, registry, catalog_config) do
    with {:ok, server, tool} <- parse_tool_ref(ref, "meta", registry),
         :ok <- check_configured(registry, server, "meta") do
      do_tool_meta(server, tool, call_context, registry, catalog_config)
    end
  end

  defp dispatch(:apropos, [query | rest], call_context, registry, catalog_config) do
    with {:ok, opts} <- parse_apropos_opts(rest),
         :ok <- validate_query_string(query),
         :ok <- validate_apropos_opts(opts) do
      do_apropos(query, opts, call_context, registry, catalog_config)
    end
  end

  defp dispatch(operation, _args, _call_context, _registry, _catalog_config) do
    {:programmer_fault, "unknown discovery operation: #{operation}"}
  end

  # ----------------------------------------------------------------
  # dir implementation
  # ----------------------------------------------------------------

  defp do_dir(server, opts, call_context, registry, catalog_config) do
    case get_tools_for_server(server, call_context, registry) do
      {:ok, tools} ->
        limit = Map.get(opts, :limit, 50)
        offset = Map.get(opts, :offset, 0)

        sorted =
          tools
          |> Enum.sort_by(&tool_name_of/1)
          |> Enum.drop(offset)
          |> Enum.take(limit)
          |> Enum.map(fn tool -> compact_tool_entry(server, tool) |> dir_line() end)

        maybe_cap_list_result(sorted, catalog_config.max_catalog_result_bytes)

      {:world_fault, _} = wf ->
        wf
    end
  end

  # ----------------------------------------------------------------
  # doc implementation
  # ----------------------------------------------------------------

  defp do_doc(server, tool_name, call_context, registry, catalog_config) do
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

  defp do_tool_meta(server, tool_name, call_context, registry, catalog_config) do
    case get_tools_for_server(server, call_context, registry) do
      {:ok, tools} ->
        case Enum.find(tools, fn t -> tool_name_of(t) == tool_name end) do
          nil ->
            {:programmer_fault, "no tool '#{tool_name}' in upstream '#{server}'"}

          tool ->
            result = tool_meta_entry(server, tool)
            maybe_cap_single_result(result, catalog_config.max_catalog_result_bytes)
        end

      {:world_fault, _} = wf ->
        wf
    end
  end

  # ----------------------------------------------------------------
  # apropos implementation
  # ----------------------------------------------------------------

  defp do_apropos(query, opts, call_context, registry, catalog_config) do
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
      |> Enum.map(fn {_score, entry} -> apropos_line(entry) end)

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
      "next" => "(dir #{inspect(server_info.name)} {:limit 20})"
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

  defp parse_dir_opts(rest), do: parse_discovery_opts(rest)

  defp validate_dir_opts(opts) do
    limit = Map.get(opts, :limit, 50)
    offset = Map.get(opts, :offset, 0)

    cond do
      not is_integer(limit) or limit < 1 or limit > 200 ->
        {:programmer_fault, "dir :limit must be an integer 1..200, got #{inspect(limit)}"}

      not is_integer(offset) or offset < 0 ->
        {:programmer_fault, "dir :offset must be a non-negative integer, got #{inspect(offset)}"}

      true ->
        :ok
    end
  end

  defp parse_apropos_opts(rest), do: parse_discovery_opts(rest)

  defp parse_discovery_opts([]), do: {:ok, %{}}

  defp parse_discovery_opts([opts]) when is_map(opts) do
    opts =
      Map.new(opts, fn
        {k, v} when is_atom(k) -> {k, v}
        {k, v} when is_binary(k) -> {safe_to_atom(k), v}
        {%LispKeyword{name: k}, v} -> {safe_to_atom(k), v}
        kv -> kv
      end)

    {:ok, opts}
  end

  defp parse_discovery_opts([opts]),
    do: {:programmer_fault, "discovery options must be a map, got #{inspect(opts)}"}

  defp parse_discovery_opts(rest),
    do:
      {:programmer_fault,
       "discovery forms accept at most one options map, got #{length(rest)} option arguments"}

  defp parse_tool_ref({:symbol_ref, name}, form, registry) when is_binary(name),
    do: parse_tool_ref(name, form, registry)

  defp parse_tool_ref(name, form, registry) when is_binary(name) do
    configured_servers =
      registry
      |> configured_server_names()
      |> Enum.sort_by(&byte_size/1, :desc)

    case Enum.find_value(configured_servers, &split_ref_with_server(name, &1)) do
      {server, tool} ->
        {:ok, server, tool}

      nil ->
        fallback_parse_tool_ref(name, form)
    end
  end

  defp parse_tool_ref(other, form, _registry) do
    {:programmer_fault,
     "#{form} requires a quoted symbol or string tool reference, got #{inspect(other)}"}
  end

  defp split_ref_with_server(ref, server) when is_binary(ref) and is_binary(server) do
    prefix = server <> "/"

    if String.starts_with?(ref, prefix) do
      tool = String.replace_prefix(ref, prefix, "")
      if tool == "", do: nil, else: {server, tool}
    end
  end

  defp split_ref_with_server(_ref, _server), do: nil

  defp fallback_parse_tool_ref(name, form) do
    case String.split(name, "/", parts: 2) do
      [server, tool] when server != "" and tool != "" ->
        {:ok, server, tool}

      _ ->
        {:programmer_fault,
         "#{form} requires tool reference shaped as server/tool, got #{inspect(name)}"}
    end
  end

  defp validate_apropos_opts(opts) do
    limit = Map.get(opts, :limit, 8)
    load = Map.get(opts, :load, false)

    cond do
      not is_integer(limit) or limit < 1 or limit > 50 ->
        {:programmer_fault, "apropos :limit must be an integer 1..50, got #{inspect(limit)}"}

      not is_boolean(load) ->
        {:programmer_fault, "apropos :load must be a boolean, got #{inspect(load)}"}

      true ->
        :ok
    end
  end

  defp validate_query_string(value) do
    if is_binary(value) and String.trim(value) != "" do
      :ok
    else
      {:programmer_fault, "apropos requires query (non-empty string), got #{inspect(value)}"}
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
    {kept, omitted} = do_truncate(items, [], 0, max_bytes)
    kept = Enum.reverse(kept)

    if omitted > 0 do
      marker = "... #{length(kept)}/#{length(items)} shown"
      maybe_append_truncation_marker(kept, marker, max_bytes)
    else
      kept
    end
  end

  defp do_truncate([], acc, _size, _max), do: {acc, 0}

  defp do_truncate([item | rest], acc, current_size, max_bytes) do
    case Jason.encode(item) do
      {:ok, json} ->
        item_size = byte_size(json) + 1
        new_size = current_size + item_size

        if new_size + 2 <= max_bytes do
          do_truncate(rest, [item | acc], new_size, max_bytes)
        else
          {acc, length(rest) + 1}
        end

      {:error, _} ->
        {acc, length(rest) + 1}
    end
  end

  defp maybe_append_truncation_marker(items, marker, max_bytes) do
    candidate = items ++ [marker]

    case Jason.encode(candidate) do
      {:ok, json} when byte_size(json) <= max_bytes ->
        candidate

      _ ->
        items
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

  defp configured_server_names(registry) do
    registry
    |> all_routings()
    |> Map.keys()
    |> Enum.map(&to_string/1)
  end

  defp all_server_info(registry) do
    routings = all_routings(registry)

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

  defp all_routings(registry) do
    GenServer.call(registry, :all_routings)
  catch
    :exit, _ -> %{}
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

  defp tool_meta_entry(server, tool) do
    name = tool_name_of(tool)
    arg_keys = tool_arg_keys(tool)
    required = tool_required_keys(tool)

    %{
      kind: "mcp-tool",
      server: server,
      tool: name,
      description: tool_full_description(tool),
      input_schema: tool_input_schema(tool),
      output_schema: tool_output_schema(tool),
      annotations: tool_annotations(tool),
      call: build_call_example(server, name, arg_keys, required)
    }
  end

  defp apropos_line(%{"tool" => nil} = entry) do
    summary = compact_text(Map.get(entry, "summary") || "")
    next = Map.get(entry, "next")
    "#{entry["server"]}: #{summary} Use #{next}."
  end

  defp apropos_line(entry) when is_map(entry) do
    server = Map.fetch!(entry, "server")
    tool = Map.fetch!(entry, "tool")
    summary = compact_text(Map.get(entry, "summary") || "")
    description = if summary == "", do: "", else: " - #{summary}"
    "#{server}.#{tool}#{description}"
  end

  defp dir_line(entry) when is_map(entry) do
    tool = Map.fetch!(entry, "tool")
    summary = compact_text(Map.get(entry, "summary") || "")

    case truncate_text(summary, 120) do
      "" -> tool
      description -> "#{tool} - #{description}"
    end
  end

  defp detailed_tool_text(entry) when is_map(entry) do
    server = Map.fetch!(entry, "server")
    tool = Map.fetch!(entry, "tool")
    input_schema = Map.get(entry, "input_schema", %{})
    output_schema = Map.get(entry, "output_schema")
    call_example = Map.fetch!(entry, "call_example")
    required = Map.get(entry, "required", [])
    summary = compact_text(Map.get(entry, "description") || Map.get(entry, "summary") || "")

    [
      "#{server}/#{tool}",
      maybe_description_line(summary),
      "",
      "Args: #{render_schema_arg_map(input_schema)}",
      "Required args: #{required_args_text(required)}",
      "",
      "Call:",
      call_example,
      "",
      "Returns: Result<#{render_schema_type(output_schema)}>",
      "Use `(:value r)` after checking `(:ok r)`."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp maybe_description_line(""), do: nil
  defp maybe_description_line(description), do: "Description: #{truncate_text(description, 240)}"

  defp required_args_text([]), do: "none"

  defp required_args_text(required) when is_list(required) do
    Enum.map_join(required, ", ", &keyword_name/1)
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
          inner = Enum.map_join(keys, " ", fn k -> "#{keyword_name(k)} ..." end)
          " :args {#{inner}}"
      end

    "(tool/mcp-call {:server #{lisp_string(server)} :tool #{lisp_string(name)}#{args_clause}})"
  end

  defp lisp_string(value) when is_binary(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      {:error, _} -> inspect(value)
    end
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

  defp render_schema_arg_map(schema) when is_map(schema) do
    properties = Map.get(schema, "properties", Map.get(schema, :properties, %{}))
    ordered_names = ordered_property_names(schema, properties)

    properties_by_string =
      Map.new(properties, fn {key, value} -> {to_string(key), value} end)

    case ordered_names do
      [] ->
        "{}"

      names ->
        fields =
          Enum.map_join(names, " ", fn name ->
            value = Map.get(properties_by_string, name, %{})
            "#{keyword_name(name)} #{render_schema_type(value)}#{optional_suffix(schema, name)}"
          end)

        "{#{fields}}"
    end
  end

  defp render_schema_arg_map(_), do: "{}"

  defp render_schema_type(nil), do: "any"

  defp render_schema_type(schema) when is_map(schema) do
    cond do
      Map.has_key?(schema, "const") or Map.has_key?(schema, :const) ->
        inspect(Map.get(schema, "const", Map.get(schema, :const)))

      is_list(Map.get(schema, "enum", Map.get(schema, :enum))) ->
        render_enum_type(Map.get(schema, "enum", Map.get(schema, :enum)))

      true ->
        render_schema_type_by_type(Map.get(schema, "type", Map.get(schema, :type)), schema)
    end
  end

  defp render_schema_type(_), do: "any"

  defp render_schema_type_by_type(type, schema) when is_list(type) do
    type
    |> Enum.reject(&(&1 in ["null", :null]))
    |> case do
      [] -> "nil"
      [one] -> render_schema_type_by_type(one, schema)
      many -> Enum.map_join(many, "|", &render_schema_type_by_type(&1, schema))
    end
  end

  defp render_schema_type_by_type("string", _schema), do: "string"
  defp render_schema_type_by_type("integer", _schema), do: "int"
  defp render_schema_type_by_type("number", _schema), do: "float"
  defp render_schema_type_by_type("boolean", _schema), do: "bool"

  defp render_schema_type_by_type("array", schema) do
    items = Map.get(schema, "items", Map.get(schema, :items))
    "[#{render_schema_type(items)}]"
  end

  defp render_schema_type_by_type("object", schema), do: render_object_type(schema)
  defp render_schema_type_by_type(nil, schema), do: infer_schema_type(schema)
  defp render_schema_type_by_type(other, _schema), do: to_string(other)

  defp render_enum_type([]), do: "enum"

  defp render_enum_type(values) do
    Enum.map_join(values, "|", &render_literal_type/1)
  end

  defp render_literal_type(value) when is_binary(value), do: lisp_string(value)
  defp render_literal_type(value), do: inspect(value)

  defp infer_schema_type(schema) do
    cond do
      Map.has_key?(schema, "properties") or Map.has_key?(schema, :properties) ->
        render_object_type(schema)

      Map.has_key?(schema, "items") or Map.has_key?(schema, :items) ->
        render_schema_type_by_type("array", schema)

      true ->
        "any"
    end
  end

  defp render_object_type(schema) do
    properties = Map.get(schema, "properties", Map.get(schema, :properties, %{}))

    if is_map(properties) and map_size(properties) > 0 do
      properties_by_string =
        Map.new(properties, fn {key, value} -> {to_string(key), value} end)

      fields =
        schema
        |> ordered_property_names(properties)
        |> Enum.map_join(" ", fn name ->
          value = Map.fetch!(properties_by_string, name)
          "#{keyword_name(name)} #{render_schema_type(value)}#{optional_suffix(schema, name)}"
        end)

      "{#{fields}}"
    else
      "map"
    end
  end

  defp ordered_property_names(schema, properties) when is_map(properties) do
    properties_by_string = Map.new(properties, fn {key, value} -> {to_string(key), value} end)

    required_names =
      schema
      |> required_key_names()
      |> Enum.filter(&Map.has_key?(properties_by_string, &1))

    optional_names =
      properties_by_string
      |> Map.keys()
      |> Enum.reject(&(&1 in required_names))
      |> Enum.sort()

    required_names ++ optional_names
  end

  defp ordered_property_names(_schema, _properties), do: []

  defp optional_suffix(schema, name) do
    if name in required_key_names(schema), do: "", else: "?"
  end

  defp required_key_names(schema) when is_map(schema) do
    case Map.get(schema, "required", Map.get(schema, :required, [])) do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  defp required_key_names(_), do: []

  defp keyword_name(key) do
    ":" <> (key |> to_string() |> String.replace("_", "-"))
  end

  defp compact_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp truncate_text(text, max) when is_binary(text) and byte_size(text) > max do
    text
    |> String.slice(0, max - 3)
    |> String.trim()
    |> Kernel.<>("...")
  end

  defp truncate_text(text, _max), do: text

  defp safe_to_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> str
  end
end
