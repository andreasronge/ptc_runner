defmodule PtcRunnerMcp.Http.PlugWithConfig do
  @moduledoc false

  alias PtcRunnerMcp.Http.Router

  def init(config), do: config

  def call(conn, config) do
    conn
    |> Plug.Conn.put_private(:ptc_http_config, config)
    |> Router.call([])
  end
end
