defmodule PtcRunner.Upstream.Discovery do
  @moduledoc false

  alias PtcRunner.Lisp.Discovery, as: LocalDiscovery
  alias PtcRunner.Upstream.{RunContext, Runtime}

  @spec build(RunContext.t()) :: (atom(), list() -> term())
  def build(%RunContext{} = context) do
    fn operation, args ->
      case RunContext.check_catalog_cap(context) do
        :proceed -> dispatch(context, operation, args) |> enforce_result_limit(context)
        :cap_exhausted -> {:world_fault, :catalog_cap_exhausted}
      end
    end
  end

  defp dispatch(context, :servers, []) do
    result =
      Runtime.catalog_snapshot(context.runtime)
      |> Enum.map(fn server ->
        %{
          "name" => server["name"],
          "description" => server["description"],
          "tool_count" => server["tool_count"],
          "catalog_loaded" => server["catalog_loaded"]
        }
      end)

    {:ok, result}
  end

  defp dispatch(context, :dir, [server | rest]) do
    opts = List.first(rest, %{})

    with {:ok, name} <- normalize_ref(server, "dir"),
         {:ok, opts} <- parse_dir_opts(opts) do
      case server_entry(context, name) do
        nil ->
          {:programmer_fault, "no upstream '#{name}' configured"}

        server ->
          limit = Map.get(opts, :limit, 50)
          offset = Map.get(opts, :offset, 0)

          lines =
            server["tools"]
            |> Enum.sort_by(& &1["name"])
            |> Enum.drop(offset)
            |> Enum.take(limit)
            |> Enum.map(&"#{server["name"]}/#{&1["name"]} - #{&1["description"] || ""}")

          {:ok, lines}
      end
    end
  end

  defp dispatch(context, :doc, [ref]) do
    with {:ok, server, tool} <- parse_tool_ref(ref, "doc"),
         {:ok, tool_entry} <- find_tool(context, server, tool) do
      {:ok, doc_text(server, tool_entry)}
    end
  end

  defp dispatch(context, :meta, [ref]) do
    with {:ok, server, tool} <- parse_tool_ref(ref, "meta"),
         {:ok, tool_entry} <- find_tool(context, server, tool) do
      {:ok,
       %{
         "server" => server,
         "name" => tool_entry["name"],
         "description" => tool_entry["description"],
         "input_schema" => tool_entry["inputSchema"],
         "output_schema" => tool_entry["outputSchema"],
         "annotations" => tool_entry["annotations"]
       }}
    end
  end

  defp dispatch(context, :apropos_matches, [query | rest]) do
    opts = List.first(rest, %{})

    with :ok <- validate_query(query),
         {:ok, opts} <- parse_apropos_opts(opts) do
      {:ok, apropos_matches(context, query, opts)}
    end
  end

  defp dispatch(context, :apropos, [query | rest]) do
    opts = List.first(rest, %{})

    with :ok <- validate_query(query),
         {:ok, opts} <- parse_apropos_opts(opts) do
      lines =
        context
        |> apropos_matches(query, opts)
        |> Enum.map(& &1.line)
        |> Enum.take(Map.get(opts, :limit, 8))

      {:ok, lines}
    end
  end

  defp dispatch(_context, operation, _args),
    do: {:programmer_fault, "unknown discovery operation: #{operation}"}

  defp enforce_result_limit({:ok, result}, context) do
    max_bytes = context.limits.max_catalog_result_bytes

    case Jason.encode(result) do
      {:ok, encoded} when byte_size(encoded) <= max_bytes ->
        {:ok, result}

      {:ok, _encoded} ->
        {:world_fault, :catalog_result_too_large}

      {:error, _reason} ->
        {:world_fault, :catalog_result_too_large}
    end
  end

  defp enforce_result_limit(other, _context), do: other

  defp server_entry(context, name) do
    Enum.find(Runtime.catalog_snapshot(context.runtime), &(Map.get(&1, "name") == name))
  end

  defp find_tool(context, server, tool) do
    case server_entry(context, server) do
      nil ->
        {:programmer_fault, "no upstream '#{server}' configured"}

      entry ->
        case Enum.find(entry["tools"], &(Map.get(&1, "name") == tool)) do
          nil -> {:programmer_fault, "no tool '#{tool}' in upstream '#{server}'"}
          tool_entry -> {:ok, tool_entry}
        end
    end
  end

  defp doc_text(server, tool) do
    [
      "#{server}/#{tool["name"]}",
      tool["description"] || "",
      "input: #{inspect(tool["inputSchema"], limit: 50)}",
      "output: #{inspect(tool["outputSchema"], limit: 50)}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp apropos_matches(context, query, opts) do
    query_tokens = LocalDiscovery.tokenize(query)
    limit = Map.get(opts, :limit, 8)

    Runtime.catalog_snapshot(context.runtime)
    |> Enum.flat_map(fn server ->
      Enum.map(server["tools"], fn tool ->
        name = tool["name"]
        desc = tool["description"] || ""

        score =
          LocalDiscovery.score_tokens(
            query_tokens,
            LocalDiscovery.tokenize(server["name"]) ++ LocalDiscovery.tokenize(name),
            2
          ) + LocalDiscovery.score_tokens(query_tokens, LocalDiscovery.tokenize(desc), 0)

        %{
          source_rank: 0,
          score: score,
          source_kind: "upstream",
          server: server["name"],
          name: name,
          ref: "#{server["name"]}/#{name}",
          line: "#{server["name"]}/#{name} - #{desc}"
        }
      end)
    end)
    |> Enum.reject(&(&1.score <= 0))
    |> LocalDiscovery.sort_matches()
    |> Enum.take(limit)
  end

  defp parse_dir_opts(opts) when is_map(opts) do
    {:ok,
     %{
       limit: pos_int(Map.get(opts, "limit", Map.get(opts, :limit, 50)), 50),
       offset: non_neg_int(Map.get(opts, "offset", Map.get(opts, :offset, 0)), 0)
     }}
  end

  defp parse_dir_opts(_opts), do: {:programmer_fault, "dir opts must be a map"}

  defp parse_apropos_opts(opts) when is_map(opts) do
    {:ok, %{limit: pos_int(Map.get(opts, "limit", Map.get(opts, :limit, 8)), 8)}}
  end

  defp parse_apropos_opts(_opts), do: {:programmer_fault, "apropos opts must be a map"}

  defp normalize_ref(ref, _operation) when is_binary(ref) and ref != "", do: {:ok, ref}
  defp normalize_ref(ref, _operation) when is_atom(ref), do: {:ok, Atom.to_string(ref)}

  defp normalize_ref(ref, operation),
    do: {:programmer_fault, "#{operation} requires non-empty ref, got #{inspect(ref)}"}

  defp parse_tool_ref(ref, operation) do
    with {:ok, text} <- normalize_ref(ref, operation) do
      case String.split(text, "/", parts: 2) do
        [server, tool] when server != "" and tool != "" -> {:ok, server, tool}
        _ -> {:programmer_fault, "#{operation} requires upstream/tool ref, got #{inspect(ref)}"}
      end
    end
  end

  defp validate_query(query) when is_binary(query) and query != "", do: :ok

  defp validate_query(query),
    do: {:programmer_fault, "apropos requires non-empty query, got #{inspect(query)}"}

  defp pos_int(value, _default) when is_integer(value) and value > 0, do: value
  defp pos_int(_value, default), do: default
  defp non_neg_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_neg_int(_value, default), do: default
end
