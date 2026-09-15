defmodule PtcGateway.Health do
  @moduledoc """
  Bounded JSON health routes. Every path validates listener authority first.
  Health has no authentication or CORS. Warm runtime snapshots are the sole
  readiness source; saturation stays ready and runtime fencing stays live.
  MCP routing belongs to the transport issue; unmatched paths return 404.
  """
  @behaviour Plug
  import Plug.Conn
  alias PtcRunner.Kernel.WarmProviderRuntime

  @impl true
  def init(opts), do: opts
  @impl true
  def call(conn, opts) do
    if PtcGateway.Policy.valid_authority?(conn, opts[:listen]) do
      route(conn, opts)
    else
      reply(conn, 400, "invalid_authority")
    end
  end

  defp route(%{request_path: path, method: method} = conn, _)
       when path in ["/health/live", "/health/ready"] and method != "GET",
       do: conn |> put_resp_header("allow", "GET") |> reply(405, "method_not_allowed")

  defp route(%{request_path: "/health/live"} = conn, _), do: reply(conn, 200, "live")

  defp route(%{request_path: "/health/ready"} = conn, opts) do
    if WarmProviderRuntime.snapshot(opts[:warm]).ready,
      do: reply(conn, 200, "ready"),
      else: reply(conn, 503, "not_ready")
  end

  defp route(conn, _), do: reply(conn, 404, "not_found")

  defp reply(conn, status, value) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(%{status: value}))
  end
end
