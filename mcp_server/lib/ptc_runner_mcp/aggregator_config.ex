defmodule PtcRunnerMcp.AggregatorConfig do
  @moduledoc """
  Runtime configuration for aggregator-mode behavior that is not a
  resource limit.

  The `:read_only` flag is an operator assertion used for MCP tool
  annotations. It does not enforce read-only behavior by itself; the
  upstream MCP servers must be configured to enforce that policy.
  """

  @default_read_only false

  @typedoc "Aggregator-mode configuration stored in persistent_term."
  @type t :: %{
          read_only: boolean()
        }

  @doc "Default aggregator config."
  @spec defaults() :: t()
  def defaults do
    %{
      read_only: @default_read_only
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
end
