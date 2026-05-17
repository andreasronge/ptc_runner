defmodule PtcRunnerMcp.Http.Server do
  @moduledoc false

  alias PtcRunnerMcp.Http.PlugWithConfig

  @spec child_spec(map()) :: {module(), keyword()}
  def child_spec(config) do
    plug = {PlugWithConfig, config}

    {Bandit,
     plug: plug,
     scheme: :http,
     ip: parse_ip(config.host),
     port: config.port,
     thousand_island_options: [read_timeout: config.request_timeout_ms]}
  end

  defp parse_ip(host) do
    case :inet.parse_address(to_charlist(host)) do
      {:ok, ip} -> ip
      _ -> {127, 0, 0, 1}
    end
  end
end
