defmodule Mix.Tasks.Rlm do
  @shortdoc "Run the RLM example with optional tracing"
  @moduledoc """
  Run the RLM (Recursive Language Model) example.

  ## Usage

      # Run without tracing
      mix rlm

      # Run with tracing enabled
      mix rlm --trace

      # Export existing trace to Chrome DevTools format
      mix rlm --export

      # View trace tree in terminal
      mix rlm --tree

      # Clean up trace files
      mix rlm --clean

  ## Options

    * `--trace` - Enable hierarchical tracing (creates .jsonl files)
    * `--export` - Export existing trace to Chrome format (.json)
    * `--tree` - Print trace tree to terminal
    * `--clean` - Delete all trace files
    * `--open` - Open Chrome DevTools trace viewer after export

  ## Examples

      # Full workflow: run with tracing, export, and open in Chrome
      mix rlm --trace
      mix rlm --export --open

      # Quick trace analysis
      mix rlm --tree

  ## Trace Files

  When tracing is enabled, files are created in `examples/rlm/traces/` (gitignored):
    * `rlm_trace.jsonl` - Main planner trace
    * `trace_<id>.jsonl` - One per worker (child traces)
    * `rlm_trace.json` - Chrome DevTools format (after --export)
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          trace: :boolean,
          export: :boolean,
          tree: :boolean,
          clean: :boolean,
          open: :boolean
        ]
      )

    cond do
      opts[:clean] ->
        clean_traces()

      opts[:export] ->
        export_trace(opts[:open])

      opts[:tree] ->
        print_tree()

      true ->
        run_example(opts[:trace])
    end
  end

  defp run_example(trace?) do
    # Ensure the app is started
    Mix.Task.run("app.start")

    # Set argv so the script sees --trace flag
    if trace?, do: System.put_env("PTC_RLM_TRACE", "1")

    IO.puts("Running RLM example#{if trace?, do: " with tracing", else: ""}...\n")

    # Run the example script
    Code.eval_file(example_script())

    if trace? do
      IO.puts("\n" <> String.duplicate("─", 60))
      IO.puts("Trace files created in #{trace_dir()}/")
      IO.puts("  • View tree:   mix rlm --tree")
      IO.puts("  • Export:      mix rlm --export")
      IO.puts("  • Clean up:    mix rlm --clean")
    end
  end

  defp export_trace(open?) do
    Mix.Task.run("app.start")

    alias PtcRunner.TraceLog.Analyzer

    main_trace = main_trace_path()

    unless File.exists?(main_trace) do
      Mix.raise("No trace file found at #{main_trace}. Run `mix rlm --trace` first.")
    end

    IO.puts("Loading trace tree...")

    chrome_trace = chrome_trace_path()

    case Analyzer.load_tree(main_trace) do
      {:ok, tree} ->
        IO.puts("Exporting to Chrome DevTools format...")

        case Analyzer.export_chrome_trace(tree, chrome_trace) do
          :ok ->
            IO.puts("Exported to: #{chrome_trace}")
            IO.puts("\nTo view in Chrome:")
            IO.puts("  1. Open DevTools (F12) → Performance tab")
            IO.puts("  2. Click 'Load profile...' and select #{chrome_trace}")
            IO.puts("  Or navigate to chrome://tracing and load the file")

            if open?, do: open_chrome_trace(chrome_trace)

          {:error, reason} ->
            Mix.raise("Export failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.raise("Failed to load trace: #{inspect(reason)}")
    end
  end

  defp print_tree do
    Mix.Task.run("app.start")

    alias PtcRunner.TraceLog.Analyzer

    main_trace = main_trace_path()

    unless File.exists?(main_trace) do
      Mix.raise("No trace file found at #{main_trace}. Run `mix rlm --trace` first.")
    end

    case Analyzer.load_tree(main_trace) do
      {:ok, tree} ->
        IO.puts("Trace tree:\n")
        Analyzer.print_tree(tree)

      {:error, reason} ->
        Mix.raise("Failed to load trace: #{inspect(reason)}")
    end
  end

  defp clean_traces do
    Mix.Task.run("app.start")

    alias PtcRunner.TraceLog.Analyzer

    main_trace = main_trace_path()
    chrome_trace = chrome_trace_path()
    trace_dir = trace_dir()

    # Delete tree if main trace exists
    if File.exists?(main_trace) do
      case Analyzer.load_tree(main_trace) do
        {:ok, tree} ->
          case Analyzer.delete_tree(tree) do
            {:ok, count} ->
              IO.puts("Deleted #{count} trace file(s)")

            {:error, reason} ->
              Mix.raise("Failed to delete traces: #{inspect(reason)}")
          end

        {:error, _} ->
          # Just delete the main file
          File.rm(main_trace)
          IO.puts("Deleted #{main_trace}")
      end
    end

    # Also delete Chrome export if it exists
    if File.exists?(chrome_trace) do
      File.rm(chrome_trace)
      IO.puts("Deleted #{chrome_trace}")
    end

    # Clean up any orphaned trace files
    Path.wildcard(Path.join(trace_dir, "trace_*.jsonl"))
    |> Enum.each(fn path ->
      File.rm(path)
      IO.puts("Deleted #{path}")
    end)

    IO.puts("Cleanup complete")
  end

  defp open_chrome_trace(chrome_trace) do
    case :os.type() do
      {:unix, :darwin} ->
        System.cmd("open", [chrome_trace])

      {:unix, _} ->
        System.cmd("xdg-open", [chrome_trace])

      {:win32, _} ->
        System.cmd("cmd", ["/c", "start", chrome_trace])
    end
  end

  # Path helpers that detect whether we're running from project root or examples/rlm/
  defp base_dir do
    cwd = File.cwd!()

    if String.ends_with?(cwd, "examples/rlm") do
      # Running from examples/rlm/ directory
      ""
    else
      # Running from project root
      "examples/rlm/"
    end
  end

  defp trace_dir, do: Path.join(base_dir(), "traces")
  defp main_trace_path, do: Path.join(trace_dir(), "rlm_trace.jsonl")
  defp chrome_trace_path, do: Path.join(trace_dir(), "rlm_trace.json")
  defp example_script, do: Path.join(base_dir(), "run.exs")
end
