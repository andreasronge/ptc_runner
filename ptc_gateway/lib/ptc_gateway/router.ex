defmodule PtcGateway.Router do
  @moduledoc false
  @behaviour Plug
  @impl true
  def init(opts), do: opts
  @impl true
  def call(%{request_path: "/mcp"} = conn, opts), do: PtcGateway.MCP.call(conn, opts)
  def call(conn, opts), do: PtcGateway.Health.call(conn, opts)
end
