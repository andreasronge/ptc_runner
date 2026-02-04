defmodule SupplyWatchdog.Tools.FileOps do
  @moduledoc """
  File operation tools for the Supply Watchdog.

  These functions require a `base_path` to resolve relative paths.
  They are wrapped by `SupplyWatchdog.Tools` to inject the base_path.
  """

  @doc "Read a CSV file and return as list of record maps."
  @spec read_csv(String.t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def read_csv(base_path, path) do
    full_path = Path.join(base_path, path)

    case File.read(full_path) do
      {:ok, content} ->
        [header | rows] = String.split(content, "\n", trim: true)
        fields = String.split(header, ",")

        records =
          Enum.map(rows, fn row ->
            values = String.split(row, ",")

            Enum.zip(fields, values)
            |> Map.new(fn {k, v} -> {k, parse_value(v)} end)
          end)

        {:ok, records}

      {:error, reason} ->
        {:error, "Failed to read #{path}: #{inspect(reason)}"}
    end
  end

  @doc "Read a JSON file and return the parsed data."
  @spec read_json(String.t(), String.t()) :: {:ok, any()} | {:error, String.t()}
  def read_json(base_path, path) do
    full_path = Path.join(base_path, path)

    case File.read(full_path) do
      {:ok, content} -> {:ok, Jason.decode!(content)}
      {:error, reason} -> {:error, "Failed to read #{path}: #{inspect(reason)}"}
    end
  end

  @doc "Write data to a JSON file. Creates parent directories if needed."
  @spec write_json(String.t(), String.t(), any()) :: {:ok, map()}
  def write_json(base_path, path, data) do
    full_path = Path.join(base_path, path)
    File.mkdir_p!(Path.dirname(full_path))

    json = Jason.encode!(data, pretty: true)
    File.write!(full_path, json)

    {:ok, %{"written" => path, "records" => count_records(data)}}
  end

  @doc "Get historical stock values for a SKU from the history file."
  @spec get_history(String.t(), String.t(), integer()) :: {:ok, [map()]}
  def get_history(base_path, sku, _days \\ 7) do
    case read_csv(base_path, "data/inventory_history.csv") do
      {:ok, records} ->
        history =
          records
          |> Enum.filter(&(Map.get(&1, "sku") == sku))
          |> Enum.sort_by(&Map.get(&1, "updated_at"))

        {:ok, history}

      {:error, _} ->
        {:ok, []}
    end
  end

  @doc "Get related shipment records for a SKU."
  @spec get_related(String.t(), String.t()) :: {:ok, map()}
  def get_related(base_path, sku) do
    shipments =
      case read_csv(base_path, "data/shipments.csv") do
        {:ok, records} -> Enum.filter(records, &(Map.get(&1, "sku") == sku))
        {:error, _} -> []
      end

    {:ok, %{"shipments" => shipments}}
  end

  @doc "Record a proposed fix for an anomaly. Appends to the fixes file."
  @spec propose_fix(String.t(), map()) :: {:ok, map()}
  def propose_fix(base_path, args) do
    fix = %{
      "sku" => Map.get(args, "sku"),
      "warehouse" => Map.get(args, "warehouse"),
      "field" => Map.get(args, "field"),
      "old_value" => Map.get(args, "old_value"),
      "new_value" => Map.get(args, "new_value"),
      "reason" => Map.get(args, "reason"),
      "confidence" => Map.get(args, "confidence", 0.8),
      "proposed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    fixes_path = Path.join(base_path, "fixes/proposed.jsonl")
    File.mkdir_p!(Path.dirname(fixes_path))

    line = Jason.encode!(fix) <> "\n"
    File.write!(fixes_path, line, [:append])

    {:ok, fix}
  end

  # ============================================
  # Helpers
  # ============================================

  defp parse_value(v) do
    cond do
      Regex.match?(~r/^-?\d+$/, v) -> String.to_integer(v)
      Regex.match?(~r/^-?\d+\.\d+$/, v) -> String.to_float(v)
      true -> v
    end
  end

  defp count_records(data) when is_list(data), do: length(data)
  defp count_records(_), do: 1
end
