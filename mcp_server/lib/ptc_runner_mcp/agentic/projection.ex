defmodule PtcRunnerMcp.Agentic.Projection do
  @moduledoc """
  Shared response-projection constants for SubAgent-backed `ptc_task`.

  Phase 0 keeps these names in one place so adapter, ledger, and tests do not
  invent divergent atoms or JSON reason strings.
  """

  @partial_side_effects :partial_side_effects

  @doc "Internal atom used when a non-terminal turn follows write/unknown attempts."
  @spec partial_side_effects() :: :partial_side_effects
  def partial_side_effects, do: @partial_side_effects

  @doc "JSON reason string for partial side-effect failures."
  @spec reason_string(atom()) :: String.t()
  def reason_string(@partial_side_effects), do: "partial_side_effects"
  def reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
end
