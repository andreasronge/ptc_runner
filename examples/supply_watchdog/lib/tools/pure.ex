defmodule SupplyWatchdog.Tools.Pure do
  @moduledoc """
  Pure data transformation tools for the Supply Watchdog.

  These functions don't depend on external state (filesystem, base_path)
  and can be referenced directly as `&function/arity` for automatic
  @spec and @doc extraction by PtcRunner.Tool.
  """

  # ============================================
  # Pattern Detection Tools
  # ============================================

  @doc "Search records for a substring pattern in a specific field. Returns matching records."
  @spec grep(%{data: [map()], field: String.t(), pattern: String.t()}) :: {:ok, [map()]}
  def grep(%{"data" => data, "field" => field, "pattern" => pattern}) do
    matches =
      Enum.filter(data, fn record ->
        value = Map.get(record, field, "") |> to_string()
        String.contains?(value, pattern)
      end)

    {:ok, matches}
  end

  @doc "Group records by one or more fields. Returns list of groups with key, records, and count."
  @spec group_by(%{data: [map()], fields: [String.t()]}) :: {:ok, [map()]}
  def group_by(%{"data" => data, "fields" => fields}) do
    grouped =
      Enum.group_by(data, fn record ->
        Enum.map(fields, &Map.get(record, &1)) |> Enum.join("|")
      end)

    result =
      Enum.map(grouped, fn {key, records} ->
        %{"key" => key, "records" => records, "count" => length(records)}
      end)

    {:ok, result}
  end

  @doc """
  Filter records by a condition map.

  Condition format: `{"field": "stock", "op": "lt", "value": 0}`

  Operators: eq, ne, lt, gt, le, ge
  """
  @spec filter(%{data: [map()], condition: map()}) :: {:ok, [map()]}
  def filter(%{"data" => data, "condition" => condition}) do
    field = Map.get(condition, "field")
    op = Map.get(condition, "op")
    value = Map.get(condition, "value")

    matches =
      Enum.filter(data, fn record ->
        record_value = Map.get(record, field)
        compare(record_value, op, value)
      end)

    {:ok, matches}
  end

  @doc "Count the number of items in a list."
  @spec count(%{data: [any()]}) :: {:ok, integer()}
  def count(%{"data" => data}) do
    {:ok, length(data)}
  end

  # ============================================
  # Statistical Analysis Tools
  # ============================================

  @doc "Calculate z-scores for a numeric field. Adds 'z_score' field to each record."
  @spec z_score(%{data: [map()], field: String.t()}) :: {:ok, [map()]}
  def z_score(%{"data" => data, "field" => field}) do
    values = Enum.map(data, &(Map.get(&1, field) |> to_number()))
    mean = Enum.sum(values) / max(length(values), 1)
    std_dev = calculate_std_dev(values, mean)

    result =
      Enum.map(data, fn record ->
        value = Map.get(record, field) |> to_number()
        z = if std_dev > 0, do: (value - mean) / std_dev, else: 0.0
        Map.put(record, "z_score", Float.round(z, 2))
      end)

    {:ok, result}
  end

  @doc """
  Find records where a field value exceeds a threshold.

  Mode: "absolute" (value > threshold) or "zscore" (z-score > threshold).
  """
  @spec detect_spikes(%{data: [map()], field: String.t(), threshold: number(), mode: String.t()}) ::
          {:ok, [map()]}
  def detect_spikes(args) do
    data = Map.get(args, "data")
    field = Map.get(args, "field")
    threshold = Map.get(args, "threshold")
    mode = Map.get(args, "mode", "absolute")

    spikes =
      case mode do
        "zscore" ->
          values = Enum.map(data, &(Map.get(&1, field) |> to_number()))
          mean = Enum.sum(values) / max(length(values), 1)
          std_dev = calculate_std_dev(values, mean)

          Enum.filter(data, fn record ->
            value = Map.get(record, field) |> to_number()
            z = if std_dev > 0, do: abs(value - mean) / std_dev, else: 0.0
            z > threshold
          end)

        _ ->
          Enum.filter(data, fn record ->
            value = Map.get(record, field) |> to_number()
            value > threshold
          end)
      end

    {:ok, spikes}
  end

  @doc "Find duplicate records based on key fields. Returns all records that share the same key."
  @spec detect_duplicates(%{data: [map()], key_fields: [String.t()]}) :: {:ok, [map()]}
  def detect_duplicates(%{"data" => data, "key_fields" => key_fields}) do
    grouped =
      Enum.group_by(data, fn record ->
        Enum.map(key_fields, &Map.get(record, &1)) |> Enum.join("|")
      end)

    duplicates =
      grouped
      |> Enum.filter(fn {_key, records} -> length(records) > 1 end)
      |> Enum.flat_map(fn {_key, records} ->
        Enum.map(records, &Map.put(&1, "duplicate_group", true))
      end)

    {:ok, duplicates}
  end

  @doc "Sort and rank records by a numeric field. Order: 'asc' or 'desc' (default: desc)."
  @spec rank_by(%{data: [map()], field: String.t(), order: String.t()}) :: {:ok, [map()]}
  def rank_by(args) do
    data = Map.get(args, "data")
    field = Map.get(args, "field")
    order = Map.get(args, "order", "desc")

    sorted =
      Enum.sort_by(data, &(Map.get(&1, field) |> to_number()), fn a, b ->
        if order == "asc", do: a <= b, else: a >= b
      end)

    ranked =
      sorted
      |> Enum.with_index(1)
      |> Enum.map(fn {record, rank} -> Map.put(record, "rank", rank) end)

    {:ok, ranked}
  end

  # ============================================
  # Helper Functions
  # ============================================

  defp compare(a, "eq", b), do: a == b
  defp compare(a, "ne", b), do: a != b
  defp compare(a, "lt", b), do: to_number(a) < to_number(b)
  defp compare(a, "gt", b), do: to_number(a) > to_number(b)
  defp compare(a, "le", b), do: to_number(a) <= to_number(b)
  defp compare(a, "ge", b), do: to_number(a) >= to_number(b)
  defp compare(_, _, _), do: false

  defp to_number(n) when is_number(n), do: n

  defp to_number(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp to_number(_), do: 0

  defp calculate_std_dev(values, mean) do
    n = length(values)

    if n < 2 do
      0.0
    else
      variance = Enum.sum(Enum.map(values, fn v -> :math.pow(v - mean, 2) end)) / n
      :math.sqrt(variance)
    end
  end
end
