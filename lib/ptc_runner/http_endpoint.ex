defmodule PtcRunner.HTTPEndpoint do
  @moduledoc false

  # Parse once and carry the URI through validation and path construction.
  def parse(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, uri} -> uri
      {:error, _} -> nil
    end
  end

  def validate(url, credential) when is_binary(url), do: validate(parse(url), credential)

  def validate(%URI{scheme: scheme, host: host, port: port} = uri, credential)
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             is_integer(port) and port in 1..65_535 do
    cond do
      uri.userinfo != nil or uri.query != nil or uri.fragment != nil ->
        {:error, :invalid_endpoint}

      scheme == "http" and credential != nil and not loopback?(host) ->
        {:error, :insecure_endpoint}

      true ->
        {:ok, uri}
    end
  end

  def validate(_url, _credential), do: {:error, :invalid_endpoint}

  def append_path(%URI{} = uri, path),
    do: %{uri | path: String.trim_trailing(uri.path || "", "/") <> path}

  defp loopback?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _other -> String.downcase(host) == "localhost"
    end
  end
end
