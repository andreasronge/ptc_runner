#!/usr/bin/env elixir

# Supply Watchdog CLI Runner
#
# Usage:
#   mix run run.exs                              # Run with defaults
#   mix run run.exs --task "find duplicates"    # Custom task
#   mix run run.exs --mode detector             # Single-pass mode
#   mix run run.exs --generate                  # Only generate data
#   mix run run.exs --clean                     # Clean up files

defmodule CLI do
  def main(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          task: :string,
          mode: :string,
          records: :integer,
          seed: :integer,
          generate: :boolean,
          clean: :boolean,
          validate: :boolean,
          trace: :boolean,
          stop_after: :string,
          help: :boolean
        ],
        aliases: [
          t: :task,
          m: :mode,
          r: :records,
          s: :seed,
          g: :generate,
          c: :clean,
          v: :validate,
          h: :help
        ]
      )

    cond do
      opts[:help] -> print_help()
      opts[:clean] -> run_clean()
      opts[:generate] -> run_generate(opts)
      opts[:validate] -> run_validate()
      true -> run_watchdog(opts)
    end
  end

  defp print_help do
    IO.puts("""
    Supply Watchdog - Tiered Anomaly Detection

    Usage:
      mix run run.exs [options]

    Options:
      -t, --task STRING      Task description (default: "find duplicate inventory entries")
      -m, --mode MODE        Mode: "pipeline" (default) or "detector"
      -r, --records N        Number of normal records to generate (default: 50)
      -s, --seed N           Random seed (default: 42)
      --stop-after TIER      Stop after tier: "tier1", "tier2", or "tier3" (default: tier3)
      --trace                Enable tracing
      -g, --generate         Only generate test data
      -c, --clean            Clean up generated files
      -v, --validate         Validate results against ground truth
      -h, --help             Show this help

    Examples:
      # Generate data and run full pipeline
      mix run run.exs --task "find duplicate entries"

      # Run single-pass detector
      mix run run.exs --mode detector --task "find negative stock"

      # Generate data with more records
      mix run run.exs --generate --records 200

      # Run only tier 1
      mix run run.exs --stop-after tier1

    Anomaly Types in Generated Data:
      - duplicate: Exact duplicate entries
      - doubled_stock: Stock value exactly doubled
      - negative_stock: Impossible negative values
      - spike: Unusually high stock values
    """)
  end

  defp run_clean do
    IO.puts("Cleaning up generated files...")
    SupplyWatchdog.clean()
    IO.puts("Done!")
  end

  defp run_generate(opts) do
    records = Keyword.get(opts, :records, 50)
    seed = Keyword.get(opts, :seed, 42)

    IO.puts("Generating test data...")
    IO.puts("  Records: #{records}")
    IO.puts("  Seed: #{seed}")

    {:ok, info} = SupplyWatchdog.generate_data(num_records: records, seed: seed)

    IO.puts("\nGenerated:")
    IO.puts("  Total records: #{info.records}")
    IO.puts("  Anomalies: #{info.anomalies}")
    IO.puts("  By type: #{inspect(info.by_type)}")
    IO.puts("\nFiles:")

    for file <- info.files do
      IO.puts("  #{file}")
    end
  end

  defp run_validate do
    IO.puts("Validating results...")

    case SupplyWatchdog.validate() do
      {:ok, score} ->
        IO.puts("\nValidation Results:")
        IO.puts("  Expected anomalies: #{score.expected}")
        IO.puts("  Detected: #{score.detected}")
        IO.puts("  Precision: #{score.precision}")
        IO.puts("  Recall: #{score.recall}")
        IO.puts("  F1 Score: #{score.f1}")

      {:error, reason} ->
        IO.puts("Validation failed: #{inspect(reason)}")
    end
  end

  defp run_watchdog(opts) do
    task =
      Keyword.get(
        opts,
        :task,
        "find duplicate inventory entries - same SKU and warehouse with identical stock values"
      )

    mode = Keyword.get(opts, :mode, "pipeline")
    records = Keyword.get(opts, :records, 50)
    seed = Keyword.get(opts, :seed, 42)
    trace = Keyword.get(opts, :trace, false)
    stop_after = Keyword.get(opts, :stop_after, "tier3") |> String.to_atom()

    # Generate data first
    IO.puts("=== Generating Test Data ===")
    {:ok, info} = SupplyWatchdog.generate_data(num_records: records, seed: seed)
    IO.puts("Generated #{info.records} records with #{info.anomalies} anomalies")
    IO.puts("Anomaly types: #{inspect(info.by_type)}")

    # Run the watchdog
    IO.puts("\n=== Running Supply Watchdog ===")
    IO.puts("Mode: #{mode}")
    IO.puts("Task: #{task}")

    result =
      case mode do
        "detector" ->
          SupplyWatchdog.run_detector(task, trace: trace)

        _ ->
          SupplyWatchdog.run_pipeline(task, trace: trace, stop_after: stop_after)
      end

    case result do
      {:ok, data} ->
        IO.puts("\n=== Results ===")
        IO.puts(inspect(data, pretty: true))

        # Run validation
        IO.puts("\n=== Validation ===")
        run_validate()

      {:error, reason} ->
        IO.puts("\nError: #{inspect(reason)}")
    end
  end
end

CLI.main(System.argv())
