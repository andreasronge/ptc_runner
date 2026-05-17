defmodule PtcRunnerMcp.Http.Origin do
  @moduledoc false

  alias PtcRunnerMcp.Http.Config

  @spec allowed?(Plug.Conn.t(), map()) :: boolean()
  def allowed?(conn, cfg) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [] -> true
      [origin | _] -> allowed_origin?(origin, cfg)
    end
  end

  @spec allowed_origin?(String.t(), map()) :: boolean()
  def allowed_origin?(origin, cfg) when is_binary(origin) do
    normalized = normalize(origin)
    allowed = Enum.map(Map.get(cfg, :allowed_origins, []), &normalize/1)

    cond do
      normalized == nil ->
        false

      allowed != [] ->
        normalized in allowed

      Config.loopback_host?(Map.fetch!(cfg, :host)) ->
        loopback_origin?(normalized)

      true ->
        false
    end
  end

  defp loopback_origin?(origin) do
    uri = URI.parse(origin)
    uri.scheme in ["http", "https"] and Config.loopback_host?(uri.host || "")
  end

  defp normalize("null"), do: nil

  defp normalize(origin) when is_binary(origin) do
    uri = URI.parse(origin)

    with scheme when scheme in ["http", "https"] <- lower(uri.scheme),
         host when is_binary(host) <- lower(uri.host) do
      port = normalized_port(scheme, uri.port)
      scheme <> "://" <> host <> port
    else
      _ -> nil
    end
  end

  defp lower(nil), do: nil
  defp lower(value), do: String.downcase(value)

  defp normalized_port("http", 80), do: ""
  defp normalized_port("https", 443), do: ""
  defp normalized_port(_scheme, nil), do: ""
  defp normalized_port(_scheme, port), do: ":" <> Integer.to_string(port)
end
