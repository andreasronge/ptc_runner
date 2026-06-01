defmodule PtcRunner.Upstream.Transport do
  @moduledoc """
  Behaviour for root-owned upstream client transports.

  Transports return `PtcRunner.Upstream.Result` tuples and normalize any
  protocol-specific envelopes before values reach `tool/call`.
  """

  alias PtcRunner.Upstream.Result

  @type server_name :: String.t()
  @type tool_name :: String.t()
  @type tool_schema :: map()
  @type upstream :: map()
  @type call_opts :: [
          timeout: pos_integer(),
          max_response_bytes: pos_integer()
        ]

  @callback list_tools(upstream()) ::
              {:ok, [tool_schema()]} | {:error, Result.reason(), String.t()}

  @callback call(upstream(), tool_name(), args :: map(), call_opts()) :: Result.t()

  @doc """
  Start a transport GenServer with `:trap_exit` temporarily enabled in the
  caller, so a child that fails during `init/1` surfaces as `{:error, reason}`
  instead of crashing the (often unsupervised) caller. The caller's original
  `:trap_exit` flag is restored afterward.

  Shared by the stateful MCP transports (`McpHttp`, `McpStdio`).
  """
  @spec start_trapped(module(), server_name(), map()) :: GenServer.on_start()
  def start_trapped(module, name, config) when is_binary(name) and is_map(config) do
    parent_trap = Process.flag(:trap_exit, true)

    try do
      GenServer.start_link(module, {name, config})
    after
      Process.flag(:trap_exit, parent_trap)
    end
  end
end
