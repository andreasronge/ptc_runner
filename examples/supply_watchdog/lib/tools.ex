defmodule SupplyWatchdog.Tools do
  @moduledoc """
  Tool collections for the Supply Watchdog agents.

  ## Tool Types

  **Pure functions** (from `Tools.Pure`): Use Elixir @spec/@doc for automatic
  signature extraction. Referenced as `&Pure.function/1`.

  **File operations** (from `Tools.FileOps`): Wrapped in closures to inject
  `base_path`. Use explicit PTC-Lisp signatures.

  ## Example

      # Pure function - @spec extracted automatically
      "grep" => &Pure.grep/1

      # File operation - closure with explicit signature
      "read_csv" => {
        fn %{"path" => path} -> FileOps.read_csv(base_path, path) end,
        signature: "(path :string) -> [:map]",
        description: "Read a CSV file"
      }

  """

  alias SupplyWatchdog.Tools.{Pure, FileOps}

  @doc """
  Get all Tier 1 tools (pattern detection).
  """
  def tier1_tools(base_path) do
    %{
      # Pure functions - @spec/@doc extracted automatically
      "grep" => &Pure.grep/1,
      "group_by" => &Pure.group_by/1,
      "filter" => &Pure.filter/1,
      "count" => &Pure.count/1,

      # File operations - need base_path closure
      "read_csv" => read_csv_tool(base_path),
      "write_json" => write_json_tool(base_path)
    }
  end

  @doc """
  Get all Tier 2 tools (statistical analysis).
  """
  def tier2_tools(base_path) do
    %{
      # Pure functions
      "z_score" => &Pure.z_score/1,
      "detect_spikes" => &Pure.detect_spikes/1,
      "detect_duplicates" => &Pure.detect_duplicates/1,
      "rank_by" => &Pure.rank_by/1,

      # File operations
      "read_json" => read_json_tool(base_path),
      "write_json" => write_json_tool(base_path)
    }
  end

  @doc """
  Get all Tier 3 tools (reasoning context).
  """
  def tier3_tools(base_path) do
    %{
      # File operations
      "read_json" => read_json_tool(base_path),
      "get_history" => get_history_tool(base_path),
      "get_related" => get_related_tool(base_path),
      "propose_fix" => propose_fix_tool(base_path),
      "write_json" => write_json_tool(base_path)
    }
  end

  # ============================================
  # File Operation Wrappers (need base_path)
  # ============================================

  defp read_csv_tool(base_path) do
    {fn %{"path" => path} -> FileOps.read_csv(base_path, path) end,
     signature: "(path :string) -> [:map]",
     description: "Read a CSV file and return as list of record maps."}
  end

  defp read_json_tool(base_path) do
    {fn %{"path" => path} -> FileOps.read_json(base_path, path) end,
     signature: "(path :string) -> :any",
     description: "Read a JSON file and return the parsed data."}
  end

  defp write_json_tool(base_path) do
    {fn %{"path" => path, "data" => data} -> FileOps.write_json(base_path, path, data) end,
     signature: "(path :string, data :any) -> {written :string, records :int}",
     description: "Write data to a JSON file. Creates parent directories if needed."}
  end

  defp get_history_tool(base_path) do
    {fn args ->
       sku = Map.get(args, "sku")
       days = Map.get(args, "days", 7)
       FileOps.get_history(base_path, sku, days)
     end,
     signature: "(sku :string, days :int) -> [:map]",
     description: "Get historical stock values for a SKU from the history file."}
  end

  defp get_related_tool(base_path) do
    {fn %{"sku" => sku} -> FileOps.get_related(base_path, sku) end,
     signature: "(sku :string) -> {shipments [:map]}",
     description: "Get related shipment records for a SKU."}
  end

  defp propose_fix_tool(base_path) do
    {fn args -> FileOps.propose_fix(base_path, args) end,
     signature:
       "(sku :string, warehouse :string, field :string, old_value :any, new_value :any, reason :string, confidence :number) -> :map",
     description: "Record a proposed fix for an anomaly. Appends to the fixes file."}
  end
end
