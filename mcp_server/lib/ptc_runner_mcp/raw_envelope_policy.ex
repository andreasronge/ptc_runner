defmodule PtcRunnerMcp.RawEnvelopePolicy do
  @moduledoc """
  Resolves whether `tool/mcp-call` should retain the raw MCP envelope.
  """

  alias PtcRunnerMcp.AggregatorConfig

  @doc """
  Returns true when raw envelope inclusion is enabled for `server.tool`.

  Precedence is tool override, upstream default, global default, then false.
  """
  @spec enabled?(String.t(), String.t()) :: boolean()
  def enabled?(server, tool) when is_binary(server) and is_binary(tool) do
    AggregatorConfig.raw_envelope_enabled?(server, tool)
  end
end
