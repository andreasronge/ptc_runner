defmodule PtcRunner.Upstream.OpenAPI.Compiler do
  @moduledoc false

  alias PtcRunner.Upstream.OpenAPI.Names

  @http_methods ~w(get post put patch delete options head trace)

  @spec compile(map(), map()) :: {:ok, [map()]} | {:error, atom(), String.t()}
  def compile(schema, config) when is_map(schema) and is_map(config) do
    includes = Map.fetch!(config, :include_operations)
    overrides = Map.get(config, :operation_overrides, %{})

    with {:ok, operations} <- collect_operations(schema),
         {:ok, selected} <- select_operations(operations, includes),
         {:ok, tools} <- compile_operations(selected, config, overrides) do
      reject_name_collisions(tools)
    end
  end

  defp collect_operations(schema) do
    operations =
      for {path, path_item} <- Map.get(schema, "paths", %{}),
          is_map(path_item),
          {method, operation} <- path_item,
          method in @http_methods,
          is_map(operation),
          operation_id = Map.get(operation, "operationId"),
          is_binary(operation_id) and operation_id != "" do
        {operation_id,
         %{method: String.upcase(method), path: path, operation: operation, path_item: path_item}}
      end

    {:ok, Map.new(operations)}
  end

  defp select_operations(operations, includes) do
    missing = Enum.reject(includes, &Map.has_key?(operations, &1))

    if missing == [] do
      {:ok, Enum.map(includes, &{&1, Map.fetch!(operations, &1)})}
    else
      {:error, :upstream_unavailable,
       "OpenAPI include_operations not found: #{Enum.join(missing, ", ")}"}
    end
  end

  defp compile_operations(selected, config, overrides) do
    Enum.reduce_while(selected, {:ok, []}, fn {operation_id, ctx}, {:ok, acc} ->
      override = Map.get(overrides, operation_id, %{})

      case compile_operation(operation_id, ctx, config, override) do
        {:ok, tool} -> {:cont, {:ok, [tool | acc]}}
        {:error, _, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, tools} -> {:ok, Enum.reverse(tools)}
      err -> err
    end
  end

  defp compile_operation(operation_id, ctx, config, override) do
    with :ok <- require_get(operation_id, ctx),
         :ok <- reject_deprecated(operation_id, ctx.operation),
         :ok <- reject_request_body(operation_id, ctx.operation),
         :ok <- reject_cross_origin_servers(operation_id, ctx.operation, config),
         {:ok, params} <- parameters(operation_id, ctx),
         :ok <- validate_path_params(operation_id, ctx.path, params),
         {:ok, default_args} <- default_args(ctx.operation, override),
         {:ok, input_schema} <- input_schema(ctx.path, params, default_args),
         {:ok, output_schema} <- output_schema(operation_id, ctx.operation) do
      {:ok,
       %{
         "name" => exposed_name(operation_id, ctx.operation, override),
         "description" => description(ctx.operation, override),
         "inputSchema" => input_schema,
         "outputSchema" => output_schema,
         "annotations" => %{"readOnlyHint" => true},
         "_ptc" => %{
           "transport" => "openapi",
           "operationId" => operation_id,
           "method" => ctx.method,
           "path" => ctx.path,
           "defaultArgs" => default_args
         }
       }}
    end
  end

  defp require_get(_operation_id, %{method: "GET"}), do: :ok

  defp require_get(operation_id, %{method: method}),
    do:
      {:error, :upstream_unavailable,
       "OpenAPI operation #{operation_id} uses unsupported method #{method}; v1 supports GET only"}

  defp reject_deprecated(operation_id, %{"deprecated" => true}),
    do: {:error, :upstream_unavailable, "OpenAPI operation #{operation_id} is deprecated"}

  defp reject_deprecated(_operation_id, _operation), do: :ok

  defp reject_request_body(operation_id, operation) do
    if Map.has_key?(operation, "requestBody") do
      {:error, :upstream_unavailable,
       "OpenAPI operation #{operation_id} has requestBody; v1 GET bodies are unsupported"}
    else
      :ok
    end
  end

  defp reject_cross_origin_servers(operation_id, operation, config) do
    case Map.get(operation, "servers") do
      nil ->
        :ok

      [] ->
        :ok

      servers when is_list(servers) ->
        base = URI.parse(config.base_url)

        if Enum.all?(servers, &same_origin?(&1, base)) do
          :ok
        else
          {:error, :upstream_unavailable,
           "OpenAPI operation #{operation_id} has cross-origin servers; v1 requires base_url origin"}
        end
    end
  end

  defp same_origin?(%{"url" => url}, base) when is_binary(url) do
    uri = URI.parse(url)

    uri.scheme == base.scheme and uri.host == base.host and
      effective_port(uri) == effective_port(base)
  end

  defp same_origin?(_, _), do: false
  defp effective_port(%URI{port: port}) when is_integer(port), do: port
  defp effective_port(%URI{scheme: "https"}), do: 443
  defp effective_port(%URI{scheme: "http"}), do: 80
  defp effective_port(_), do: nil

  defp parameters(operation_id, ctx) do
    (Map.get(ctx.path_item, "parameters", []) ++ Map.get(ctx.operation, "parameters", []))
    |> Enum.reduce_while({:ok, []}, fn param, {:ok, acc} ->
      case parameter(operation_id, param) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, params} -> {:ok, Enum.reverse(params)}
      err -> err
    end
  end

  defp parameter(_operation_id, %{"$ref" => _}),
    do: {:error, :upstream_unavailable, "$ref parameters are unsupported in OpenAPI v1 compiler"}

  defp parameter(_operation_id, %{"name" => name, "in" => location} = param)
       when is_binary(name) and location in ["path", "query"] do
    {:ok,
     %{
       name: name,
       in: location,
       required: Map.get(param, "required") == true,
       schema: Map.get(param, "schema", %{})
     }}
  end

  defp parameter(operation_id, %{"in" => location}) when location in ["header", "cookie"] do
    {:error, :upstream_unavailable,
     "OpenAPI operation #{operation_id} has unsupported #{location} parameter"}
  end

  defp parameter(operation_id, param),
    do:
      {:error, :upstream_unavailable,
       "OpenAPI operation #{operation_id} has unsupported parameter #{inspect(param, limit: 20)}"}

  defp validate_path_params(operation_id, path, params) do
    declared = params |> Enum.filter(&(&1.in == "path")) |> MapSet.new(& &1.name)
    missing = route_params(path) |> Enum.reject(&MapSet.member?(declared, &1))

    if missing == [] do
      :ok
    else
      {:error, :upstream_unavailable,
       "OpenAPI operation #{operation_id} path template is missing declared path parameter(s): #{Enum.join(missing, ", ")}"}
    end
  end

  defp default_args(operation, override) do
    case Map.get(override, "default_args", Map.get(operation, "x-ptc-default-args", %{})) do
      defaults when is_map(defaults) -> {:ok, defaults}
      _ -> {:ok, %{}}
    end
  end

  defp input_schema(path, params, default_args) do
    path_required = route_params(path)
    properties = Map.new(params, &{&1.name, Map.put_new(&1.schema || %{}, "type", "string")})

    required =
      params
      |> Enum.filter(fn p -> p.in == "path" or p.required or p.name in path_required end)
      |> Enum.map(& &1.name)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(default_args, &1))

    {:ok, %{"type" => "object", "properties" => properties, "required" => required}}
  end

  defp route_params(path),
    do: Regex.scan(~r/\{([^}]+)\}/, path) |> Enum.map(fn [_, name] -> name end)

  defp output_schema(operation_id, operation) do
    two_xx =
      operation
      |> Map.get("responses", %{})
      |> Enum.sort_by(fn {status, _} -> status end)
      |> Enum.filter(fn {status, _} -> String.starts_with?(to_string(status), "2") end)

    cond do
      two_xx == [] ->
        {:error, :upstream_unavailable, "OpenAPI operation #{operation_id} has no 2xx response"}

      empty_success_responses?(two_xx) ->
        {:ok, %{"type" => "null"}}

      true ->
        case Enum.find_value(two_xx, fn {_status, response} -> response_schema(response) end) do
          nil ->
            {:error, :upstream_unavailable,
             "OpenAPI operation #{operation_id} has no JSON 2xx response; v1 supports JSON responses only"}

          schema ->
            {:ok, schema}
        end
    end
  end

  defp response_schema(%{"content" => content}) when is_map(content) do
    Enum.find_value(content, fn {type, body} ->
      if String.contains?(type, "json"), do: Map.get(body, "schema", %{})
    end)
  end

  defp response_schema(_), do: nil

  defp empty_success_responses?(responses) do
    Enum.all?(responses, fn {status, response} ->
      to_string(status) == "204" or not Map.has_key?(response, "content") or
        Map.get(response, "content") == %{}
    end)
  end

  defp exposed_name(operation_id, operation, override),
    do: (override["name"] || operation["x-ptc-name"] || operation_id) |> Names.normalize()

  defp description(operation, override),
    do: override["description"] || operation["description"] || operation["summary"] || ""

  defp reject_name_collisions(tools) do
    names = Enum.map(tools, & &1["name"])
    duplicates = names -- Enum.uniq(names)

    if duplicates == [] do
      {:ok, tools}
    else
      {:error, :upstream_unavailable,
       "OpenAPI tool name collision after normalization: #{Enum.join(Enum.uniq(duplicates), ", ")}"}
    end
  end
end
