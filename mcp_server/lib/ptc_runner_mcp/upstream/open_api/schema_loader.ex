defmodule PtcRunnerMcp.Upstream.OpenApi.SchemaLoader do
  @moduledoc false

  alias PtcRunnerMcp.Credentials
  alias PtcRunnerMcp.Credentials.RedactedHeaders

  @default_schema_max_bytes 2 * 1024 * 1024

  @spec load(map()) :: {:ok, map()} | {:error, atom(), String.t()}
  def load(%{schema_file: path} = config) when is_binary(path) do
    max_bytes = Map.get(config, :schema_max_bytes, @default_schema_max_bytes)

    with {:ok, info} <- File.stat(path),
         :ok <- check_size(info.size, max_bytes),
         {:ok, body} <- File.read(path) do
      decode_schema(body)
    else
      {:error, reason} ->
        {:error, :upstream_unavailable, "schema_file: #{format_file_error(reason)}"}
    end
  end

  def load(%{schema_url: url} = config) when is_binary(url) do
    if Code.ensure_loaded?(Req) do
      do_fetch(url, config)
    else
      {:error, :upstream_unavailable, "req library not loaded"}
    end
  end

  defp do_fetch(url, config) do
    max_bytes = Map.get(config, :schema_max_bytes, @default_schema_max_bytes)

    with {:ok, auth_headers} <- auth_headers(config) do
      headers = Map.get(config, :static_headers, []) ++ auth_headers

      opts = [
        url: url,
        method: :get,
        headers: headers,
        receive_timeout: Map.get(config, :request_timeout_ms, 30_000),
        retry: false,
        decode_body: false,
        into: cap_collector(max_bytes)
      ]

      case Req.request(opts) do
        {:ok, %{status: status} = resp} when status in 200..299 ->
          decode_schema_response(resp, max_bytes)

        {:ok, %{status: status}} ->
          {:error, :upstream_unavailable, "schema_url returned http #{status}"}

        {:error, exception} ->
          {:error, :upstream_unavailable, Exception.message(exception)}
      end
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
        {:error, :unknown_binding, _detail} ->
          {:halt,
           {:error, :upstream_unavailable, "schema auth resolution_failed: #{emitter.binding}"}}

        {:error, :resolution_failed, _detail} ->
          {:halt,
           {:error, :upstream_unavailable, "schema auth resolution_failed: #{emitter.binding}"}}

        {:error, reason, _detail} ->
          {:halt, {:error, :upstream_unavailable, "schema auth #{reason}: #{emitter.binding}"}}
      end
    end)
  end

  defp check_size(size, max_bytes) when is_integer(size) and size <= max_bytes, do: :ok
  defp check_size(_size, _max_bytes), do: {:error, :too_large}

  defp decode_schema(body) when is_binary(body) do
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
    {body, overflow?} = extract_body_state(resp)

    if overflow? do
      {:error, :response_too_large, "schema response exceeded #{max_bytes} bytes"}
    else
      decode_schema(body)
    end
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

  defp format_file_error(:too_large), do: "schema exceeds byte cap"
  defp format_file_error(reason), do: to_string(:file.format_error(reason))
end
