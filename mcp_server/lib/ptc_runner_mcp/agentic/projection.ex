defmodule PtcRunnerMcp.Agentic.Projection do
  @moduledoc """
  Shared response-projection constants for SubAgent-backed `lisp_task`.

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

  @doc "Projects compact LLM-facing upstream result summaries."
  @spec upstream_results([map()]) :: [map()]
  def upstream_results(entries) when is_list(entries) do
    entries
    |> Enum.map(&upstream_result/1)
    |> Enum.reject(&is_nil/1)
  end

  defp ledger_entry(entry) do
    # `result_bytes` (`integer | null`) and `oversize` (`boolean`) per
    # `Plans/ptc-runner-mcp-payload-reduction.md` §4.1 — always present
    # on the projection so the `lisp_task` `upstream_calls[]` shape
    # matches the `lisp_eval` one. An `:attempted`-only entry
    # (interrupted before completion) has neither key in the ledger →
    # `result_bytes: null`, `oversize: false`.
    %{
      "server" => Map.fetch!(entry, :server),
      "tool" => Map.fetch!(entry, :tool),
      "status" => status_string(Map.fetch!(entry, :status)),
      "duration_ms" => Map.get(entry, :duration_ms, 0),
      "effect" => Atom.to_string(Map.fetch!(entry, :effect)),
      "result_bytes" => normalize_result_bytes(Map.get(entry, :result_bytes)),
      "oversize" => Map.get(entry, :oversize, false) == true
    }
    |> maybe_put("reason", Map.get(entry, :error_reason))
    |> maybe_put("error", Map.get(entry, :error))
  end

  defp upstream_result(%{status: :ok, result_overview: overview} = entry) when is_map(overview) do
    %{
      "server" => Map.fetch!(entry, :server),
      "tool" => Map.fetch!(entry, :tool),
      "status" => "ok"
    }
    |> Map.merge(overview)
  end

  defp upstream_result(%{status: :error} = entry) do
    %{
      "server" => Map.fetch!(entry, :server),
      "tool" => Map.fetch!(entry, :tool),
      "status" => "error"
    }
    |> maybe_put("reason", Map.get(entry, :error_reason))
    |> maybe_put("error", Map.get(entry, :error))
  end

  defp upstream_result(_entry), do: nil

  defp normalize_result_bytes(n) when is_integer(n) and n >= 0, do: n
  defp normalize_result_bytes(_), do: nil

  defp status_string(:attempted), do: "attempted"
  defp status_string(:ok), do: "ok"
  defp status_string(:error), do: "error"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
