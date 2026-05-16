defmodule PtcRunnerMcp.Http.Server do
  @moduledoc false

  alias PtcRunnerMcp.Http.Router

  @spec child_spec(map()) :: {module(), keyword()}
  def child_spec(config) do
    plug = {__MODULE__.PlugWithConfig, config}

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

  defmodule PlugWithConfig do
    @moduledoc false

    def init(config), do: config

    def call(conn, config) do
      conn
      |> Plug.Conn.put_private(:ptc_http_config, config)
      |> Router.call([])
    end
  end
end
