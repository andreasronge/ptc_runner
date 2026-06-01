defmodule PtcRunner.Upstream.OpenAPI do
  @moduledoc false

  @behaviour PtcRunner.Upstream.Transport

  alias PtcRunner.Upstream.Credentials
  alias PtcRunner.Upstream.OpenAPI.Compiler
  alias PtcRunner.Upstream.ResponseCap

  @impl PtcRunner.Upstream.Transport
  def list_tools(%{tools: tools}) when is_list(tools), do: {:ok, tools}

  @spec load(map()) :: {:ok, map()} | {:error, atom(), String.t()}
  def load(config) do
    with {:ok, schema} <- load_schema(config),
         {:ok, tools} <- Compiler.compile(schema, config) do
      {:ok,
       %{
         tools: tools,
         operations: Map.new(tools, &{&1["name"], &1}),
         base_uri: URI.parse(config.base_url)
       }}
    end
  end

  @spec call(map(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, atom(), String.t()}
  @impl PtcRunner.Upstream.Transport
  def call(upstream, tool_name, args, opts)
      when is_map(upstream) and is_binary(tool_name) and is_map(args) and is_list(opts) do
    case Map.fetch(upstream.operations, tool_name) do
      {:ok, tool} -> execute(upstream, tool, args, opts)
      :error -> {:error, :upstream_error, "unknown OpenAPI tool '#{tool_name}'"}
    end
  rescue
    e -> {:error, :upstream_error, "openapi call raised: #{Exception.message(e)}"}
  end

  defp load_schema(%{schema_file: path} = config) when is_binary(path) do
    max_bytes = Map.get(config, :schema_max_bytes, 2 * 1024 * 1024)

    with {:ok, info} <- File.stat(path),
         :ok <- check_size(info.size, max_bytes),
         {:ok, body} <- File.read(path) do
      decode_schema(body)
    else
      {:error, reason} when is_atom(reason) ->
        {:error, :upstream_unavailable, "schema_file: #{format_file_error(reason)}"}
    end
  end

  defp load_schema(%{schema_url: url} = config) when is_binary(url) do
    if Code.ensure_loaded?(Req) do
      max_bytes = Map.get(config, :schema_max_bytes, 2 * 1024 * 1024)

      case Req.request(
             url: url,
             method: :get,
             receive_timeout: Map.get(config, :request_timeout_ms, 30_000),
             retry: false,
             decode_body: false,
             into: ResponseCap.collector(max_bytes)
           ) do
        {:ok, %{status: status} = resp} when status in 200..299 ->
          decode_schema_response(resp, max_bytes)

        {:ok, %{status: status}} ->
          {:error, :upstream_unavailable, "schema_url returned http #{status}"}

        {:error, exception} ->
          {:error, :upstream_unavailable, Exception.message(exception)}
      end
    else
      {:error, :upstream_unavailable, "req library not loaded"}
    end
  end

  defp load_schema(_config),
    do: {:error, :upstream_unavailable, "OpenAPI config requires schema_file or schema_url"}

  defp execute(upstream, tool, args, opts) do
    if Code.ensure_loaded?(Req) do
      do_execute(upstream, tool, args, opts)
    else
      {:error, :upstream_unavailable, "req library not loaded"}
    end
  end

  defp do_execute(upstream, tool, args, opts) do
    with {:ok, merged_args} <- merge_default_args(tool, args),
         {:ok, url} <- build_url(upstream.config.base_url, tool, merged_args),
         {:ok, headers} <- request_headers(upstream.config),
         {:ok, req_opts, max_bytes} <- build_req_opts(url, headers, upstream.config, opts),
         {:ok, resp} <- Req.request(req_opts) do
      map_response(resp, max_bytes)
    else
      {:error, %RuntimeError{message: "response_too_large"}} ->
        {:error, :response_too_large, "response exceeded byte cap"}

      {:error, %Req.TransportError{} = e} ->
        {:error, :upstream_unavailable, Exception.message(e)}

      {:error, reason, detail} ->
        {:error, reason, detail}

      {:error, exception} when is_exception(exception) ->
        {:error, :upstream_unavailable, Exception.message(exception)}
    end
  end

  defp merge_default_args(tool, args),
    do: {:ok, Map.merge(get_in(tool, ["_ptc", "defaultArgs"]) || %{}, stringify_keys(args))}

  defp build_url(base_url, tool, args) do
    base_uri = URI.parse(base_url)
    path = get_in(tool, ["_ptc", "path"])
    properties = get_in(tool, ["inputSchema", "properties"]) || %{}
    route_names = route_params(path)

    with {:ok, path} <- interpolate_path(path, route_names, args),
         {:ok, query} <-
           args
           |> Enum.reject(fn {key, _} -> to_string(key) in route_names end)
           |> Enum.filter(fn {key, _} -> Map.has_key?(properties, to_string(key)) end)
           |> query_pairs() do
      uri = %{base_uri | path: join_paths(base_uri.path, path), query: encode_query(query)}
      {:ok, URI.to_string(uri)}
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp query_pairs(args) do
    Enum.reduce_while(args, {:ok, []}, fn {key, value}, {:ok, acc} ->
      if scalar_query_value?(value),
        do: {:cont, {:ok, [{to_string(key), value} | acc]}},
        else:
          {:halt,
           {:error, :upstream_error,
            "unsupported query arg '#{key}': OpenAPI v1 supports scalar query values only"}}
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      err -> err
    end
  end

  defp scalar_query_value?(value),
    do: is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value)

  defp encode_query([]), do: nil
  defp encode_query(query), do: URI.encode_query(query)

  defp route_params(path),
    do: Regex.scan(~r/\{([^}]+)\}/, path) |> Enum.map(fn [_, name] -> name end)

  defp interpolate_path(path, route_names, args) do
    missing = Enum.reject(route_names, &Map.has_key?(args, &1))

    if missing == [] do
      path =
        Enum.reduce(route_names, path, fn name, acc ->
          String.replace(
            acc,
            "{#{name}}",
            URI.encode(to_string(Map.fetch!(args, name)), &URI.char_unreserved?/1)
          )
        end)

      {:ok, path}
    else
      {:error, :upstream_error, "missing path args: #{Enum.join(missing, ", ")}"}
    end
  end

  defp join_paths(nil, path), do: path
  defp join_paths("", path), do: path
  defp join_paths("/", path), do: path

  defp join_paths(base, path),
    do: String.trim_trailing(base, "/") <> "/" <> String.trim_leading(path, "/")

  defp request_headers(config) do
    with {:ok, auth_headers} <-
           Credentials.headers(config.credentials, Map.get(config, :auth, [])) do
      {:ok,
       [{"accept", "application/json"} | Map.get(config, :static_headers, [])] ++ auth_headers}
    end
  end

  defp build_req_opts(url, headers, config, opts) do
    timeout =
      min(Keyword.get(opts, :timeout, 30_000), Map.get(config, :request_timeout_ms, 30_000))

    max_bytes =
      min(
        Keyword.get(opts, :max_response_bytes, 2 * 1024 * 1024),
        Map.get(config, :max_response_bytes, 2 * 1024 * 1024)
      )

    {:ok,
     [
       url: url,
       method: :get,
       headers: headers,
       receive_timeout: timeout,
       connect_options: [timeout: Map.get(config, :connect_timeout_ms, 5_000)],
       retry: false,
       decode_body: false,
       into: ResponseCap.collector(max_bytes)
     ], max_bytes}
  end

  defp map_response(%{status: status} = resp, max_bytes) when status in 200..299 do
    {body, overflow?} = ResponseCap.extract_body(resp)

    cond do
      overflow? ->
        {:error, :response_too_large, "response exceeded #{max_bytes} bytes"}

      status == 204 or body == "" ->
        {:ok, nil}

      true ->
        case Jason.decode(body) do
          {:ok, decoded} ->
            {:ok, decoded}

          {:error, reason} ->
            {:error, :upstream_error, "malformed JSON response: #{inspect(reason)}"}
        end
    end
  end

  defp map_response(%{status: 400} = resp, _), do: problem_error(:tool_error, resp)
  defp map_response(%{status: 401}, _), do: {:error, :auth_failed, "auth_failed"}
  defp map_response(%{status: 403} = resp, _), do: problem_error(:tool_error, resp)
  defp map_response(%{status: 404} = resp, _), do: problem_error(:tool_error, resp)
  defp map_response(%{status: 422} = resp, _), do: problem_error(:tool_error, resp)
  defp map_response(%{status: 429} = resp, _), do: problem_error(:rate_limited, resp)

  defp map_response(%{status: status}, _) when status >= 500,
    do: {:error, :upstream_unavailable, "http #{status}"}

  defp map_response(%{status: status}, _), do: {:error, :upstream_error, "http #{status}"}

  defp problem_error(reason, resp) do
    {body, _} = ResponseCap.extract_body(resp)
    {:error, reason, if(body == "", do: "http #{resp.status}", else: String.slice(body, 0, 500))}
  end

  defp check_size(size, max_bytes) when is_integer(size) and size <= max_bytes, do: :ok
  defp check_size(_, _), do: {:error, :too_large}

  defp decode_schema(body) do
    case Jason.decode(body) do
      {:ok, schema} when is_map(schema) ->
        {:ok, schema}

      {:ok, _} ->
        {:error, :upstream_unavailable, "OpenAPI schema must be a JSON object"}

      {:error, reason} ->
        {:error, :upstream_unavailable, "schema JSON decode failed: #{inspect(reason)}"}
    end
  end

  defp decode_schema_response(resp, max_bytes) do
    {body, overflow?} = ResponseCap.extract_body(resp)

    if overflow?,
      do: {:error, :response_too_large, "schema response exceeded #{max_bytes} bytes"},
      else: decode_schema(body)
  end

  defp format_file_error(:too_large), do: "schema exceeds byte cap"
  defp format_file_error(reason), do: to_string(:file.format_error(reason))
end
