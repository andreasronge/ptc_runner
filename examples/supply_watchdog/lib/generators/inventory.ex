defmodule SupplyWatchdog.Generators.Inventory do
  @moduledoc """
  Generates inventory data with injected anomalies for testing the watchdog agents.

  ## Anomaly Types

  - `:duplicate` - Exact duplicate entries (same SKU, warehouse, stock, timestamp)
  - `:doubled_stock` - Stock value exactly doubled from previous day
  - `:negative_stock` - Impossible negative stock values
  - `:stale_timestamp` - Timestamps older than expected (stale data)
  - `:spike` - Sudden large increase (>3 sigma from moving average)

  ## Example

      {:ok, data} = Inventory.generate(
        num_records: 100,
        anomalies: [
          {:duplicate, 3},
          {:doubled_stock, 2},
          {:negative_stock, 1}
        ],
        seed: 42
      )

  """

  @skus ~w(HRG-1001 HRG-1002 HRG-2001 HRG-2002 HRG-3001 HRG-3002 HRG-4001 HRG-4002 HRG-5001 HRG-5002)
  @warehouses ~w(WH-EU WH-US WH-APAC)

  @doc """
  Generate inventory data with specified anomalies.

  ## Options

    * `:num_records` - Number of normal records to generate (default: 50)
    * `:anomalies` - List of `{type, count}` tuples specifying anomalies to inject
    * `:seed` - Random seed for reproducibility (default: 42)
    * `:base_date` - Base date for timestamps (default: ~U[2026-02-03 00:00:00Z])

  ## Returns

    * `{:ok, %{records: [...], anomalies: [...], ground_truth: %{...}}}`

  """
  def generate(opts \\ []) do
    num_records = Keyword.get(opts, :num_records, 50)
    anomalies_spec = Keyword.get(opts, :anomalies, default_anomalies())
    seed = Keyword.get(opts, :seed, 42)
    base_date = Keyword.get(opts, :base_date, ~U[2026-02-03 00:00:00Z])

    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    # Generate normal records
    normal_records = generate_normal_records(num_records, base_date)

    # Inject anomalies
    {all_records, injected_anomalies} =
      inject_anomalies(normal_records, anomalies_spec, base_date)

    # Sort by timestamp
    sorted_records = Enum.sort_by(all_records, & &1.updated_at, DateTime)

    {:ok,
     %{
       records: sorted_records,
       anomalies: injected_anomalies,
       ground_truth: build_ground_truth(injected_anomalies)
     }}
  end

  @doc """
  Convert records to CSV string.
  """
  def to_csv(records) do
    header = "sku,warehouse,stock,updated_at"

    rows =
      Enum.map(records, fn r ->
        "#{r.sku},#{r.warehouse},#{r.stock},#{DateTime.to_iso8601(r.updated_at)}"
      end)

    Enum.join([header | rows], "\n")
  end

  @doc """
  Convert records to JSON-lines format.
  """
  def to_jsonl(records) do
    records
    |> Enum.map(fn r ->
      Jason.encode!(%{
        sku: r.sku,
        warehouse: r.warehouse,
        stock: r.stock,
        updated_at: DateTime.to_iso8601(r.updated_at)
      })
    end)
    |> Enum.join("\n")
  end

  # Private functions

  defp default_anomalies do
    [
      {:duplicate, 2},
      {:doubled_stock, 2},
      {:negative_stock, 1},
      {:spike, 2}
    ]
  end

  defp generate_normal_records(count, base_date) do
    for i <- 1..count do
      sku = Enum.random(@skus)
      warehouse = Enum.random(@warehouses)
      stock = :rand.uniform(1000) + 100
      # Spread timestamps over the day
      offset_seconds = :rand.uniform(86400)
      timestamp = DateTime.add(base_date, offset_seconds, :second)

      %{
        id: i,
        sku: sku,
        warehouse: warehouse,
        stock: stock,
        updated_at: timestamp,
        anomaly: nil
      }
    end
  end

  defp inject_anomalies(records, anomalies_spec, base_date) do
    Enum.reduce(anomalies_spec, {records, []}, fn {type, count}, {recs, anomalies} ->
      inject_anomaly_type(recs, anomalies, type, count, base_date)
    end)
  end

  defp inject_anomaly_type(records, anomalies, :duplicate, count, _base_date) do
    # Pick random records to duplicate
    to_duplicate = Enum.take_random(records, count)

    new_records =
      Enum.map(to_duplicate, fn r ->
        # Exact duplicate with slightly different timestamp (1 second later)
        %{
          r
          | id: length(records) + :rand.uniform(10000),
            updated_at: DateTime.add(r.updated_at, 1, :second),
            anomaly: :duplicate
        }
      end)

    new_anomalies =
      Enum.map(new_records, fn r ->
        %{
          type: :duplicate,
          sku: r.sku,
          warehouse: r.warehouse,
          stock: r.stock,
          description: "Exact duplicate entry"
        }
      end)

    {records ++ new_records, anomalies ++ new_anomalies}
  end

  defp inject_anomaly_type(records, anomalies, :doubled_stock, count, base_date) do
    # Create records where stock is exactly 2x a previous value
    new_records =
      for _ <- 1..count do
        source = Enum.random(records)
        doubled_stock = source.stock * 2
        # Next day timestamp
        timestamp = DateTime.add(base_date, 86400 + :rand.uniform(3600), :second)

        %{
          id: length(records) + :rand.uniform(10000),
          sku: source.sku,
          warehouse: source.warehouse,
          stock: doubled_stock,
          updated_at: timestamp,
          anomaly: :doubled_stock
        }
      end

    new_anomalies =
      Enum.map(new_records, fn r ->
        %{
          type: :doubled_stock,
          sku: r.sku,
          warehouse: r.warehouse,
          stock: r.stock,
          description: "Stock value exactly doubled (was #{div(r.stock, 2)})"
        }
      end)

    {records ++ new_records, anomalies ++ new_anomalies}
  end

  defp inject_anomaly_type(records, anomalies, :negative_stock, count, base_date) do
    new_records =
      for _ <- 1..count do
        sku = Enum.random(@skus)
        warehouse = Enum.random(@warehouses)
        timestamp = DateTime.add(base_date, :rand.uniform(86400), :second)

        %{
          id: length(records) + :rand.uniform(10000),
          sku: sku,
          warehouse: warehouse,
          stock: -:rand.uniform(100),
          updated_at: timestamp,
          anomaly: :negative_stock
        }
      end

    new_anomalies =
      Enum.map(new_records, fn r ->
        %{
          type: :negative_stock,
          sku: r.sku,
          warehouse: r.warehouse,
          stock: r.stock,
          description: "Impossible negative stock value"
        }
      end)

    {records ++ new_records, anomalies ++ new_anomalies}
  end

  defp inject_anomaly_type(records, anomalies, :spike, count, base_date) do
    # Create records with unusually high stock (>5x normal range)
    new_records =
      for _ <- 1..count do
        sku = Enum.random(@skus)
        warehouse = Enum.random(@warehouses)
        spike_stock = :rand.uniform(5000) + 5000
        timestamp = DateTime.add(base_date, :rand.uniform(86400), :second)

        %{
          id: length(records) + :rand.uniform(10000),
          sku: sku,
          warehouse: warehouse,
          stock: spike_stock,
          updated_at: timestamp,
          anomaly: :spike
        }
      end

    new_anomalies =
      Enum.map(new_records, fn r ->
        %{
          type: :spike,
          sku: r.sku,
          warehouse: r.warehouse,
          stock: r.stock,
          description: "Unusual stock spike (#{r.stock} units)"
        }
      end)

    {records ++ new_records, anomalies ++ new_anomalies}
  end

  defp inject_anomaly_type(records, anomalies, :stale_timestamp, count, base_date) do
    # Create records with timestamps from a week ago (stale data)
    new_records =
      for _ <- 1..count do
        sku = Enum.random(@skus)
        warehouse = Enum.random(@warehouses)
        stock = :rand.uniform(1000) + 100
        # 7 days ago
        timestamp = DateTime.add(base_date, -7 * 86400 + :rand.uniform(3600), :second)

        %{
          id: length(records) + :rand.uniform(10000),
          sku: sku,
          warehouse: warehouse,
          stock: stock,
          updated_at: timestamp,
          anomaly: :stale_timestamp
        }
      end

    new_anomalies =
      Enum.map(new_records, fn r ->
        %{
          type: :stale_timestamp,
          sku: r.sku,
          warehouse: r.warehouse,
          stock: r.stock,
          description: "Stale timestamp (#{DateTime.to_iso8601(r.updated_at)})"
        }
      end)

    {records ++ new_records, anomalies ++ new_anomalies}
  end

  defp build_ground_truth(anomalies) do
    %{
      total_anomalies: length(anomalies),
      by_type:
        anomalies
        |> Enum.group_by(& &1.type)
        |> Enum.map(fn {type, items} -> {type, length(items)} end)
        |> Map.new()
    }
  end
end
