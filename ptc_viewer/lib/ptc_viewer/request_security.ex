defmodule PtcViewer.RequestSecurity do
  @moduledoc false

  import Plug.Conn, only: [get_req_header: 2]

  @local_hosts ["localhost", "127.0.0.1", "::1"]

  def valid_host?(conn) do
    conn.scheme == :http and local_host?(conn.host) and conn.port == expected_port(conn) and
      valid_host_header?(conn)
  end

  # HTTP/2 uses :authority, which Bandit projects into conn.host/port.
  # For HTTP/1 absolute-form targets, also check Host: Bandit takes the
  # connection authority from the target rather than that header.
  defp valid_host_header?(conn) do
    case get_req_header(conn, "host") do
      [] ->
        true

      [authority] ->
        case URI.new("http://" <> authority) do
          {:ok, uri} ->
            local_host?(uri.host) and uri.port == conn.port and
              canonical_host(uri.host) == canonical_host(conn.host) and
              is_nil(uri.userinfo) and uri.path in [nil, ""] and
              is_nil(uri.query) and is_nil(uri.fragment)

          {:error, _reason} ->
            false
        end

      _invalid ->
        false
    end
  end

  defp local_host?(host), do: canonical_host(host) in @local_hosts
  defp canonical_host("[::1]"), do: "::1"
  defp canonical_host(host), do: host

  def valid_origin?(conn) do
    with true <- valid_host?(conn),
         [origin] <- get_req_header(conn, "origin"),
         {:ok, %URI{scheme: "http", host: host, port: port} = uri} <- URI.new(origin),
         true <- canonical_host(host) == canonical_host(conn.host) and port == conn.port,
         true <-
           is_nil(uri.userinfo) and uri.path in [nil, ""] and
             is_nil(uri.query) and is_nil(uri.fragment) do
      true
    else
      _invalid -> false
    end
  end

  defp expected_port(conn) do
    config = conn.assigns.viewer_config

    case Keyword.get(config, :expected_port) do
      port when is_integer(port) -> port
      _none -> PtcViewer.Server.expected_port(Keyword.fetch!(config, :viewer_server))
    end
  catch
    :exit, _reason -> -1
  end
end
