defmodule PtcRunnerMcp.Upstream.OpenApi do
  @moduledoc """
  Curated read-only JSON OpenAPI upstream transport.

  V1 intentionally supports explicitly included JSON GET operations only.
  """

  @behaviour PtcRunnerMcp.Upstream

  use GenServer

  alias PtcRunnerMcp.Credentials
  alias PtcRunnerMcp.Credentials.RedactedHeaders
  alias PtcRunnerMcp.Upstream
  alias PtcRunnerMcp.Upstream.OpenApi.{Compiler, SchemaLoader}

  @registry __MODULE__.Names
  @default_request_timeout_ms 30_000
  @default_connect_timeout_ms 5_000
  @default_max_response_bytes 2 * 1024 * 1024

  @impl Upstream
  def start_link(name, config) when is_binary(name) and is_map(config) do
    parent_trap = Process.flag(:trap_exit, true)

    try do
      GenServer.start_link(__MODULE__, {name, config}, name: via(name))
    after
      Process.flag(:trap_exit, parent_trap)
    end
  end

  @impl Upstream
  def list_tools(name) when is_binary(name) do
    case whereis(name) do
      nil -> {:error, :upstream_unavailable, "openapi upstream '#{name}' is not running"}
      pid -> GenServer.call(pid, :list_tools)
    end
  end

  @impl Upstream
  def call(name, tool_name, args, opts)
      when is_binary(name) and is_binary(tool_name) and is_map(args) and is_list(opts) do
    case whereis(name) do
      nil ->
        {:error, :upstream_unavailable, "openapi upstream '#{name}' is not running"}

      pid ->
        case GenServer.call(pid, {:checkout, tool_name}, 5_000) do
          {:ok, snap} -> execute(snap, args, opts)
          {:error, _reason, _detail} = err -> err
        end
    end
  rescue
    e -> {:error, :upstream_error, "openapi call raised: #{Exception.message(e)}"}
  catch
    :exit, {:noproc, _} -> {:error, :upstream_unavailable, "openapi upstream '#{name}' exited"}
    :exit, {:timeout, _} -> {:error, :upstream_error, "openapi checkout timeout"}
  end

  @impl Upstream
  def stop(name) when is_binary(name) do
    case whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5_000)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  @doc false
  def child_spec_for_registry do
    {Registry, keys: :unique, name: @registry}
  end

  @impl GenServer
  def init({name, config}) do
    case SchemaLoader.load(config) do
      {:ok, schema} ->
        case Compiler.compile(schema, config) do
          {:ok, tools} ->
            operations = Map.new(tools, &{&1["name"], &1})

            {:ok,
             %{
               name: name,
               config: config,
               tools: tools,
               operations: operations,
               base_uri: URI.parse(Map.fetch!(config, :base_url))
             }}

          {:error, reason, detail} ->
            {:stop, {reason, detail}}
        end

      {:error, reason, detail} ->
        {:stop, {reason, detail}}
    end
  end

  @impl GenServer
  def handle_call(:list_tools, _from, state), do: {:reply, {:ok, state.tools}, state}

  def handle_call({:checkout, tool_name}, _from, state) do
    case Map.fetch(state.operations, tool_name) do
      {:ok, tool} ->
        {:reply,
         {:ok,
          %{
            name: state.name,
            tool: tool,
            config: state.config,
            base_uri: state.base_uri
          }}, state}

      :error ->
        {:reply, {:error, :upstream_error, "unknown OpenAPI tool '#{tool_name}'"}, state}
    end
  end

  defp execute(snap, args, opts) do
    if Code.ensure_loaded?(Req) do
      do_execute(snap, args, opts)
    else
      {:error, :upstream_unavailable, "req library not loaded"}
    end
  end

  defp do_execute(snap, args, opts) do
    with {:ok, merged_args} <- merge_default_args(snap.tool, args),
         {:ok, url} <- build_url(snap.base_uri, snap.tool, merged_args),
         {:ok, headers} <- request_headers(snap.config),
         {:ok, req_opts, max_bytes} <- build_req_opts(url, headers, snap.config, opts),
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

  defp merge_default_args(tool, args) do
    defaults = get_in(tool, ["_ptc", "defaultArgs"]) || %{}
    {:ok, Map.merge(defaults, args)}
  end

  defp build_url(base_uri, tool, args) do
    path = get_in(tool, ["_ptc", "path"])
    schema = tool["inputSchema"] || %{}
    properties = Map.get(schema, "properties", %{})

    route_names = route_params(path)

    with {:ok, path} <- interpolate_path(path, route_names, args) do
      with {:ok, query} <-
             args
             |> Enum.reject(fn {key, _value} -> to_string(key) in route_names end)
             |> Enum.filter(fn {key, _value} -> Map.has_key?(properties, to_string(key)) end)
             |> query_pairs() do
        uri = %{
          base_uri
          | path: join_paths(base_uri.path, path),
            query: encode_query(query)
        }

        {:ok, URI.to_string(uri)}
      end
    end
  end

  defp query_pairs(args) do
    args
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, acc} ->
      if scalar_query_value?(value) do
        {:cont, {:ok, [{to_string(key), value} | acc]}}
      else
        {:halt,
         {:error, :upstream_error,
          "unsupported query arg '#{key}': OpenAPI v1 supports scalar query values only"}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      err -> err
    end
  end

  defp scalar_query_value?(value) do
    is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value)
  end

  defp encode_query([]), do: nil
  defp encode_query(query), do: URI.encode_query(query)

  defp route_params(path) do
    Regex.scan(~r/\{([^}]+)\}/, path)
    |> Enum.map(fn [_, name] -> name end)
  end

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
    with {:ok, auth_headers} <- auth_headers(config) do
      {:ok,
       [{"accept", "application/json"} | Map.get(config, :static_headers, [])] ++ auth_headers}
    end
  end

  defp auth_headers(config) do
    credentials = Map.get(config, :credentials, Credentials)

    config
    |> Map.get(:auth, [])
    |> Enum.reduce_while({:ok, []}, fn emitter, {:ok, acc} ->
      with {:ok, materialization} <- Credentials.materialize(credentials, emitter.binding),
           {:ok, %RedactedHeaders{} = wrapper} <-
             Credentials.apply_emitter(materialization, emitter) do
        {:cont, {:ok, acc ++ RedactedHeaders.headers(wrapper)}}
      else
        {:error, reason, detail} ->
          {:halt, {:error, :upstream_unavailable, "#{reason}: #{detail}"}}
      end
    end)
  end

  defp build_req_opts(url, headers, config, opts) do
    timeout =
      min(
        Keyword.get(opts, :timeout, @default_request_timeout_ms),
        Map.get(config, :request_timeout_ms, @default_request_timeout_ms)
      )

    max_bytes =
      min(
        Keyword.get(opts, :max_response_bytes, @default_max_response_bytes),
        Map.get(config, :max_response_bytes, @default_max_response_bytes)
      )

    {:ok,
     [
       url: url,
       method: :get,
       headers: headers,
       receive_timeout: timeout,
       connect_options: [
         timeout: Map.get(config, :connect_timeout_ms, @default_connect_timeout_ms)
       ],
       retry: false,
       decode_body: false,
       into: cap_collector(max_bytes)
     ], max_bytes}
  end

  defp map_response(%{status: status} = resp, max_bytes) when status in 200..299 do
    {body, overflow?} = extract_body_state(resp)

    cond do
      overflow? ->
        {:error, :response_too_large, "response exceeded #{max_bytes} bytes"}

      status == 204 or body == "" ->
        {:ok, nil}

      true ->
        case Jason.decode(body) do
          {:ok, decoded} ->
            {:ok, %{"structuredContent" => decoded}}

          {:error, reason} ->
            {:error, :upstream_error, "malformed JSON response: #{inspect(reason)}"}
        end
    end
  end

  defp map_response(%{status: 400} = resp, _max_bytes), do: problem_error(:tool_error, resp)

  defp map_response(%{status: 401}, _max_bytes),
    do: {:error, :upstream_unavailable, "auth_failed"}

  defp map_response(%{status: 403} = resp, _max_bytes), do: problem_error(:tool_error, resp)
  defp map_response(%{status: 404} = resp, _max_bytes), do: problem_error(:tool_error, resp)
  defp map_response(%{status: 422} = resp, _max_bytes), do: problem_error(:tool_error, resp)
  defp map_response(%{status: 429} = resp, _max_bytes), do: problem_error(:rate_limited, resp)

  defp map_response(%{status: status}, _max_bytes) when status >= 500,
    do: {:error, :upstream_unavailable, "http #{status}"}

  defp map_response(%{status: status}, _max_bytes),
    do: {:error, :upstream_error, "http #{status}"}

  defp problem_error(reason, resp) do
    {body, _overflow?} = extract_body_state(resp)
    detail = if body == "", do: "http #{resp.status}", else: String.slice(body, 0, 500)
    {:error, reason, detail}
  end

  defp extract_body_state(%{private: private}) do
    case Map.get(private, :cap_state) do
      nil ->
        {"", false}

      %{chunks: chunks, overflow: overflow?} ->
        {IO.iodata_to_binary(chunks), overflow?}
    end
  end

  defp cap_collector(cap) do
    fn {:data, data}, {req, resp} ->
      state =
        resp.private
        |> Map.get(:cap_state, %{bytes: 0, chunks: [], overflow: false})
        |> Map.put(:cap, cap)

      new_size = state.bytes + byte_size(data)

      cond do
        state.overflow ->
          {:halt, {req, resp}}

        new_size > cap ->
          new_state = %{state | overflow: true}
          {:halt, {req, put_in(resp.private[:cap_state], new_state)}}

        true ->
          new_state = %{state | bytes: new_size, chunks: [state.chunks, data]}
          {:cont, {req, put_in(resp.private[:cap_state], new_state)}}
      end
    end
  end

  defp via(name), do: {:via, Registry, {@registry, name}}

  defp whereis(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
