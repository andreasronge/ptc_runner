defmodule PtcRunner.LLM.CompatHTTP do
  @moduledoc false

  alias PtcRunner.HTTPEndpoint
  alias PtcRunner.Kernel.ProviderError

  @max_body_bytes 4_194_304
  @max_error_bytes 4_096

  def request(method, base_uri, path, opts, credential \\ nil) do
    with {:ok, uri} <- HTTPEndpoint.validate(base_uri, credential) do
      opts =
        opts
        |> Keyword.put(:url, HTTPEndpoint.append_path(uri, path))
        |> Keyword.put(:method, method)
        |> Keyword.put(:redirect, false)
        |> Keyword.put(:retry, false)
        |> Keyword.put(:raw, true)
        |> Keyword.put(:compressed, false)
        |> Keyword.put(:into, &collect_body/2)

      opts = if credential, do: Keyword.put(opts, :auth, {:bearer, credential}), else: opts
      normalize_response(Req.request(opts))
    end
  end

  defp collect_body({:data, data}, {request, %{body: body} = response}) do
    limit = if response.status == 200, do: @max_body_bytes, else: @max_error_bytes
    remaining = limit - byte_size(body)

    if byte_size(data) <= remaining do
      {:cont, {request, %{response | body: body <> data}}}
    else
      body =
        if response.status == 200, do: :too_large, else: body <> binary_part(data, 0, remaining)

      {:halt, {request, %{response | body: body}}}
    end
  end

  defp normalize_response({:ok, %{body: :too_large}}),
    do: {:error, ProviderError.new(:invalid_result, "LLM response exceeds 4194304 bytes")}

  defp normalize_response({:ok, %{status: 200, body: body} = response}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, %{response | body: decoded}}
      {:error, _} -> {:error, ProviderError.new(:invalid_result, "LLM response is not JSON")}
    end
  end

  defp normalize_response({:ok, %{status: status, body: body} = response}) when status != 200,
    do: {:ok, %{response | body: PtcRunner.Utf8.truncate_valid(body, @max_error_bytes)}}

  defp normalize_response(result), do: result
end
