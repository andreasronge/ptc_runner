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

  @doc "Projects internal ledger entries to the MCP response `upstream_calls` shape."
  @spec ledger_entries([map()]) :: [map()]
  def ledger_entries(entries) when is_list(entries) do
    Enum.map(entries, &ledger_entry/1)
  end

  defp ledger_entry(entry) do
    %{
      "server" => Map.fetch!(entry, :server),
      "tool" => Map.fetch!(entry, :tool),
      "status" => status_string(Map.fetch!(entry, :status)),
      "duration_ms" => Map.get(entry, :duration_ms, 0),
      "effect" => Atom.to_string(Map.fetch!(entry, :effect)),
      "turn" => Map.fetch!(entry, :turn),
      "args_hash" => Map.fetch!(entry, :args_hash)
    }
    |> maybe_put("result_bytes", Map.get(entry, :result_bytes))
    |> maybe_put("reason", Map.get(entry, :error_reason))
    |> maybe_put("error", Map.get(entry, :error))
  end

  defp status_string(:attempted), do: "attempted"
  defp status_string(:ok), do: "ok"
  defp status_string(:error), do: "error"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
