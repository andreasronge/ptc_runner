defmodule PtcGateway.HTTPClient do
  @moduledoc false

  def get(url, headers \\ []) do
    request(:get, url, headers, nil)
  end

  def post(url, body, headers \\ []) do
    request(:post, url, headers, body)
  end

  defp request(method, url, headers, body) do
    http_headers =
      Enum.map(headers, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    http_request =
      case body do
        nil -> {String.to_charlist(url), http_headers}
        payload -> {String.to_charlist(url), http_headers, ~c"application/json", payload}
      end

    case :httpc.request(method, http_request, [timeout: 2_000], body_format: :binary) do
      {:ok, {{_http, status, _reason}, _headers, response}} ->
        {status, decode_body(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_body(""), do: %{}

  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end
end
