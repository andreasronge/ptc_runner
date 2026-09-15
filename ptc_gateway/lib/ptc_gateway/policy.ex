defmodule PtcGateway.Policy do
  @moduledoc """
  Fixed listener authority and exact origin policy passed to the HTTP boundary.
  The warm owner is the opaque bearer handle. Header parsing and MCP dispatch
  are supplied by the MCP transport; this module never receives credentials.
  """
  @spec authority(map()) :: binary()
  def authority(%{"address" => address, "port" => port}) do
    host = if address == "::1", do: "[::1]", else: address
    if port == 80, do: host, else: host <> ":" <> Integer.to_string(port)
  end

  @spec valid_authority?(Plug.Conn.t(), map()) :: boolean()
  def valid_authority?(conn, listen) do
    Plug.Conn.get_req_header(conn, "host") == [authority(listen)] and
      conn.host in hosts(listen) and
      conn.port == listen["port"] and conn.scheme == :http
  end

  defp hosts(%{"address" => "::1"}), do: ["::1", "[::1]"]
  defp hosts(listen), do: [listen["address"]]

  @spec allowed_origin?(Plug.Conn.t(), map()) :: boolean()
  def allowed_origin?(conn, listen) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [] -> true
      [origin] -> origin in listen["allowed_origins"]
      _ -> false
    end
  end
end
