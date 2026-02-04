defmodule SupplyWatchdog do
  @moduledoc """
  Supply Watchdog - Tiered anomaly detection for inventory data.

  Demonstrates how to chain SubAgents where each tier's output
  becomes the next tier's input, using the filesystem as the
  communication medium.

  ## Architecture

  ```
  Human Input: "Find duplicates in inventory"
        │
        ▼
  ┌─────────────────────────────────────┐
  │ Tier 1: Pattern Detector            │
  │ - Reads data/inventory.csv          │
  │ - Generates detection code          │
  │ - Writes flags/tier1.json           │
  └─────────────────────────────────────┘
        │
        ▼
  ┌─────────────────────────────────────┐
  │ Tier 2: Statistical Analyzer        │
  │ - Reads flags/tier1.json            │
  │ - Calculates z-scores, ranks        │
  │ - Writes flags/tier2.json           │
  └─────────────────────────────────────┘
        │
        ▼
  ┌─────────────────────────────────────┐
  │ Tier 3: Root Cause Reasoner         │
  │ - Reads flags/tier2.json            │
  │ - Looks up history, proposes fixes  │
  │ - Writes fixes/proposed.json        │
  └─────────────────────────────────────┘
  ```

  ## Quick Start

      # Generate test data
      {:ok, _} = SupplyWatchdog.generate_data(seed: 42)

      # Run single detector
      {:ok, result} = SupplyWatchdog.run_detector("find negative stock values")

      # Run full pipeline
      {:ok, result} = SupplyWatchdog.run_pipeline("find duplicate inventory entries")

  """

  alias PtcRunner.SubAgent
  alias SupplyWatchdog.{Agent, Generators}

  @base_path Path.expand(".", __DIR__) |> Path.join("..")

  @doc """
  Generate test inventory data with injected anomalies.

  ## Options

    * `:num_records` - Number of normal records (default: 50)
    * `:anomalies` - List of `{type, count}` tuples
    * `:seed` - Random seed (default: 42)

  ## Example

      {:ok, info} = SupplyWatchdog.generate_data(
        num_records: 100,
        anomalies: [{:duplicate, 3}, {:negative_stock, 2}]
      )

  """
  def generate_data(opts \\ []) do
    {:ok, data} = Generators.Inventory.generate(opts)

    # Write inventory.csv
    csv_content = Generators.Inventory.to_csv(data.records)
    csv_path = Path.join(@base_path, "data/inventory.csv")
    File.mkdir_p!(Path.dirname(csv_path))
    File.write!(csv_path, csv_content)

    # Write ground truth for validation
    truth_path = Path.join(@base_path, "data/ground_truth.json")
    File.write!(truth_path, Jason.encode!(data.ground_truth, pretty: true))

    # Generate history file (past values for context)
    history_content = generate_history(data.records)
    history_path = Path.join(@base_path, "data/inventory_history.csv")
    File.write!(history_path, history_content)

    {:ok,
     %{
       records: length(data.records),
       anomalies: data.ground_truth.total_anomalies,
       by_type: data.ground_truth.by_type,
       files: [csv_path, truth_path, history_path]
     }}
  end

  @doc """
  Run the single-pass detector agent.

  This is simpler than the full pipeline - good for testing
  specific anomaly detection.

  ## Example

      {:ok, result} = SupplyWatchdog.run_detector("find negative stock values")

  """
  def run_detector(task, opts \\ []) do
    llm = Keyword.get(opts, :llm) || default_llm()
    trace = Keyword.get(opts, :trace, false)

    agent = Agent.detector(@base_path, llm: llm)

    context = %{
      "task" => task,
      "data_path" => "data/inventory.csv"
    }

    run_opts = [context: context, llm: llm]
    run_opts = if trace, do: Keyword.put(run_opts, :tracer, tracer_opts()), else: run_opts

    SubAgent.run(agent, run_opts)
  end

  @doc """
  Run the full three-tier pipeline.

  1. Tier 1 detects patterns based on task description
  2. Tier 2 statistically analyzes flagged records
  3. Tier 3 determines root causes and proposes fixes

  ## Example

      {:ok, result} = SupplyWatchdog.run_pipeline("find duplicate inventory entries")

  """
  def run_pipeline(task, opts \\ []) do
    llm = Keyword.get(opts, :llm) || default_llm()
    trace = Keyword.get(opts, :trace, false)
    stop_after = Keyword.get(opts, :stop_after, :tier3)

    results = %{task: task, tiers: %{}}

    # Tier 1
    IO.puts("\n=== Tier 1: Pattern Detection ===")
    IO.puts("Task: #{task}")

    tier1_agent = Agent.tier1(@base_path, llm: llm)
    tier1_opts = [context: %{"task" => task}, llm: llm]
    tier1_opts = if trace, do: Keyword.put(tier1_opts, :tracer, tracer_opts()), else: tier1_opts

    case SubAgent.run(tier1_agent, tier1_opts) do
      {:ok, step} ->
        IO.puts("Tier 1 result: #{inspect(step.return)}")
        results = put_in(results, [:tiers, :tier1], step.return)

        if stop_after == :tier1 do
          {:ok, results}
        else
          run_tier2(results, llm, trace, stop_after)
        end

      {:error, reason} = error ->
        IO.puts("Tier 1 failed: #{inspect(reason)}")
        error
    end
  end

  defp run_tier2(results, llm, trace, stop_after) do
    IO.puts("\n=== Tier 2: Statistical Analysis ===")

    tier2_agent = Agent.tier2(@base_path, llm: llm)
    tier2_opts = [context: %{"input_path" => "flags/tier1.json"}, llm: llm]
    tier2_opts = if trace, do: Keyword.put(tier2_opts, :tracer, tracer_opts()), else: tier2_opts

    case SubAgent.run(tier2_agent, tier2_opts) do
      {:ok, step} ->
        IO.puts("Tier 2 result: #{inspect(step.return)}")
        results = put_in(results, [:tiers, :tier2], step.return)

        if stop_after == :tier2 do
          {:ok, results}
        else
          run_tier3(results, llm, trace)
        end

      {:error, reason} = error ->
        IO.puts("Tier 2 failed: #{inspect(reason)}")
        error
    end
  end

  defp run_tier3(results, llm, trace) do
    IO.puts("\n=== Tier 3: Root Cause Analysis ===")

    tier3_agent = Agent.tier3(@base_path, llm: llm)
    tier3_opts = [context: %{"input_path" => "flags/tier2.json"}, llm: llm]
    tier3_opts = if trace, do: Keyword.put(tier3_opts, :tracer, tracer_opts()), else: tier3_opts

    case SubAgent.run(tier3_agent, tier3_opts) do
      {:ok, step} ->
        IO.puts("Tier 3 result: #{inspect(step.return)}")
        results = put_in(results, [:tiers, :tier3], step.return)
        {:ok, results}

      {:error, reason} = error ->
        IO.puts("Tier 3 failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Validate results against ground truth.

  ## Example

      {:ok, score} = SupplyWatchdog.validate()

  """
  def validate do
    truth_path = Path.join(@base_path, "data/ground_truth.json")
    flags_path = Path.join(@base_path, "flags/tier1.json")

    with {:ok, truth_json} <- File.read(truth_path),
         {:ok, flags_json} <- File.read(flags_path) do
      truth = Jason.decode!(truth_json)
      flags = Jason.decode!(flags_json)

      detected = length(flags)
      expected = truth["total_anomalies"]

      precision = if detected > 0, do: min(expected, detected) / detected, else: 0
      recall = if expected > 0, do: min(expected, detected) / expected, else: 0

      f1 = if precision + recall > 0, do: 2 * precision * recall / (precision + recall), else: 0

      {:ok,
       %{
         expected: expected,
         detected: detected,
         precision: Float.round(precision, 2),
         recall: Float.round(recall, 2),
         f1: Float.round(f1, 2)
       }}
    end
  end

  @doc """
  Clean up generated files.
  """
  def clean do
    paths = [
      Path.join(@base_path, "data"),
      Path.join(@base_path, "flags"),
      Path.join(@base_path, "fixes"),
      Path.join(@base_path, "traces")
    ]

    for path <- paths do
      if File.exists?(path), do: File.rm_rf!(path)
    end

    :ok
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp generate_history(records) do
    # Generate 7 days of history for each SKU/warehouse combo
    header = "sku,warehouse,stock,updated_at"

    history_records =
      records
      |> Enum.filter(&is_nil(&1.anomaly))
      |> Enum.take(20)
      |> Enum.flat_map(fn r ->
        for day <- 1..7 do
          # Vary stock by ±10%
          variation = :rand.uniform() * 0.2 - 0.1
          stock = round(r.stock * (1 + variation))
          timestamp = DateTime.add(r.updated_at, -day * 86400, :second)

          "#{r.sku},#{r.warehouse},#{stock},#{DateTime.to_iso8601(timestamp)}"
        end
      end)

    Enum.join([header | history_records], "\n")
  end

  defp default_llm do
    # Use bedrock:haiku if AWS credentials available, otherwise fall back to haiku (openrouter)
    model = System.get_env("LLM_MODEL", "bedrock:haiku")
    LLMClient.callback(model)
  end

  defp tracer_opts do
    traces_dir = Path.join(@base_path, "traces")
    File.mkdir_p!(traces_dir)

    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    path = Path.join(traces_dir, "trace_#{timestamp}.jsonl")

    [path: path]
  end
end
