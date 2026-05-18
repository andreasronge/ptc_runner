defmodule PtcRunnerMcp.Http.Host do
  @moduledoc false

  alias PtcRunnerMcp.Http.Config

  @spec allowed?(Plug.Conn.t(), map()) :: boolean()
  def allowed?(conn, cfg) do
    if Config.loopback_host?(Map.fetch!(cfg, :host)) do
      loopback_host?(conn.host)
    else
      true
    end
  end

  defp loopback_host?(host) when is_binary(host) do
    host
    |> host_without_port()
    |> Config.loopback_host?()
  end

  defp loopback_host?(_host), do: false

  defp host_without_port("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [host, _suffix] -> host
      _ -> rest
    end
  end

  defp host_without_port(host) do
    case URI.parse("//" <> host) do
      %URI{host: parsed} when is_binary(parsed) -> parsed
      _ -> host
    end
  end
end
