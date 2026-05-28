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
end
