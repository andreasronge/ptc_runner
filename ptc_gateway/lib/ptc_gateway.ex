defmodule PtcGateway do
  @moduledoc """
  Stdio MCP gateway that serves compiled applications as tools.

  `start/1` binds one stdio connection. `start_http/1` binds streamable HTTP
  on loopback unless the host names `{0, 0, 0, 0}`. `PtcGateway.HTTP.Router`
  is the HTTP front door; Bandit/Plug stay in this companion. Each
  `tools/call` runs in its own request owner. The owner monitors the
  connection process; connection death kills every in-flight call. In-flight
  admission is non-blocking: saturation is a closed rejection, not a queue.

  The pinned protocol is MCP `2026-07-28`. Stdio uses newline-delimited JSON
  and rejects HTTP `Content-Length` framing. HTTP POST `/mcp` uses JSON
  bodies; `notifications/cancelled` is stdio-only. This companion does not
  compile applications; the host passes already-compiled tool descriptors and
  a call function per tool.
  """

  alias PtcGateway.HTTP.Server, as: HTTPServer
  alias PtcGateway.Server

  @doc """
  Starts one gateway lifecycle on the supplied stdio devices.

  ## Options

  `:tools` is a list of tool maps with `:name`, `:description`, `:input_schema`,
  `:output_schema`, `:meta`, and `:call`. `:max_in_flight` is a positive
  integer. `:read` and `:write` override stdio for tests.
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, atom()}
  def start(opts \\ [])

  def start(opts) when is_list(opts) do
    with :ok <- started() do
      Server.start(opts)
    end
  end

  def start(_opts), do: {:error, :invalid_gateway_config}

  @doc """
  Starts one streamable HTTP gateway on loopback unless `:ip` is `{0, 0, 0, 0}`.

  `:token` is the already-validated bearer secret from the host. `:port` `0`
  binds an ephemeral port. `:host` is the canonical Host-header name (no
  scheme or port). Loopback defaults it to `"127.0.0.1"`; a wildcard bind
  requires an explicit host.

  The gateway never puts the token in plug options, supervisor child specs,
  process status, or Bandit `:stop` telemetry. Bandit copies the raw
  `Plug.Conn` into `:start` and `:exception` before the plug can strip
  `Authorization`; those events therefore include the wire header. This
  companion does not start `Bandit.Trace`.
  """
  @spec start_http(keyword()) :: {:ok, pid()} | {:error, atom()}
  def start_http(opts \\ [])

  def start_http(opts) when is_list(opts) do
    with :ok <- started() do
      HTTPServer.start(opts)
    end
  end

  def start_http(_opts), do: {:error, :invalid_gateway_config}

  @doc "Stops the gateway and its in-flight request owners."
  @spec stop(pid()) :: :ok
  def stop(pid), do: Server.stop(pid)

  @doc "Returns the bound HTTP listener address and actual port."
  @spec listener_info(pid()) ::
          {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, atom()}
  def listener_info(pid), do: HTTPServer.listener_info(pid)

  defp started do
    case Application.ensure_all_started(:ptc_gateway) do
      {:ok, _started} -> :ok
      {:error, _reason} -> {:error, :gateway_start_failed}
    end
  end
end
