defmodule PtcRunnerMcp.AggregatorConfig do
  @moduledoc """
  Runtime configuration for aggregator-mode behavior that is not a
  resource limit.

  The `:read_only` flag is an operator assertion used for MCP tool
  annotations. It does not enforce read-only behavior by itself; the
  configured upstreams must enforce that policy.
  """

  @default_read_only false

  @typedoc "Aggregator-mode configuration stored in persistent_term."
  @type t :: %{
          read_only: boolean(),
          raw_envelope_default: boolean(),
          upstreams: map()
        }

  @doc "Default aggregator config."
  @spec defaults() :: t()
  def defaults do
    %{
      read_only: @default_read_only,
      raw_envelope_default: false,
      upstreams: %{}
    }
  end

  @doc """
  Set process-wide aggregator config.

  Unknown keys are ignored. Missing keys fall back to defaults.
  """
  @spec set(map()) :: :ok
  def set(overrides) when is_map(overrides) do
    merged = Map.merge(defaults(), Map.take(overrides, Map.keys(defaults())))
    :persistent_term.put({__MODULE__, :config}, merged)
    :ok
  end

  @doc "Read current process-wide aggregator config."
  @spec get() :: t()
  def get do
    :persistent_term.get({__MODULE__, :config}, defaults())
  end

  @doc """
  True when the operator asserted that configured upstreams are read-only.

  This controls MCP tool annotations only; it is intentionally not an
  authorization or policy-enforcement layer.
  """
  @spec read_only?() :: boolean()
  def read_only?, do: get().read_only == true

  @doc """
  True when raw MCP envelope retention is enabled for an upstream tool.
  """
  @spec raw_envelope_enabled?(String.t(), String.t()) :: boolean()
  def raw_envelope_enabled?(server, tool) when is_binary(server) and is_binary(tool) do
    config = get()
    upstream = get_in(config, [:upstreams, server]) || %{}
    tool_config = get_in(upstream, [:tools, tool]) || %{}

    cond do
      is_boolean(Map.get(tool_config, :raw_envelope)) ->
        tool_config.raw_envelope

      is_boolean(Map.get(upstream, :raw_envelope)) ->
        upstream.raw_envelope

      true ->
        config.raw_envelope_default == true
    end
  end
end
