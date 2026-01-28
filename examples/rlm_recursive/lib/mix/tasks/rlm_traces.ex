defmodule Mix.Tasks.RlmTraces do
  @shortdoc "Export, view, or clean RLM recursive traces"
  @moduledoc """
  Manage trace files from RLM recursive benchmarks.

  ## Usage

      # Export all traces to Chrome DevTools format
      mix rlm_traces --export

      # Export and open in Chrome
      mix rlm_traces --export --open

      # Export a specific trace file
      mix rlm_traces --export --file traces/recursive_trace.jsonl

      # Print trace tree(s) to terminal
      mix rlm_traces --tree

      # Clean up all trace files
      mix rlm_traces --clean

  ## Options

    * `--export` - Export traces to Chrome format (.json)
    * `--tree` - Print trace tree(s) to terminal
    * `--clean` - Delete all trace files (.jsonl and .json)
    * `--open` - Open in Chrome after export (macOS/Linux/Windows)
    * `--file` - Specify a single trace file (default: all .jsonl files)

  ## Trace Files

  Traces are stored in `traces/` (gitignored):
    * `*.jsonl` - Raw trace events (JSONL format)
    * `*.json` - Chrome DevTools format (after --export)

  ## Viewing in Chrome

  After export:
    1. Open Chrome DevTools (F12) → Performance tab
    2. Click 'Load profile...' and select a .json file
    3. Or navigate to chrome://tracing and load the file
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          export: :boolean,
          tree: :boolean,
          clean: :boolean,
          open: :boolean,
          file: :string
        ]
      )

    Mix.Task.run("app.start")

    cond do
      opts[:clean] ->
        clean_traces()

      opts[:export] ->
        export_traces(opts[:file], opts[:open])

      opts[:tree] ->
        print_trees(opts[:file])

      true ->
        IO.puts(@moduledoc)
    end
  end

  defp export_traces(file, open?) do
    alias PtcRunner.TraceLog.Analyzer

    files = trace_files(file)

    if Enum.empty?(files) do
      Mix.raise("No trace files found in #{trace_dir()}. Run benchmarks with --trace first.")
    end

    IO.puts("Exporting #{length(files)} trace file(s) to Chrome format...\n")

    exported =
      Enum.map(files, fn jsonl ->
        json = String.replace(jsonl, ".jsonl", ".json")

        case Analyzer.load_tree(jsonl) do
          {:ok, tree} ->
            case Analyzer.export_chrome_trace(tree, json) do
              :ok ->
                IO.puts("  ✓ #{Path.basename(json)}")
                {:ok, json}

              {:error, reason} ->
                IO.puts("  ✗ #{Path.basename(jsonl)}: #{inspect(reason)}")
                {:error, jsonl}
            end

          {:error, reason} ->
            IO.puts("  ✗ #{Path.basename(jsonl)}: #{inspect(reason)}")
            {:error, jsonl}
        end
      end)

    success_count = Enum.count(exported, &match?({:ok, _}, &1))
    IO.puts("\nExported #{success_count}/#{length(files)} trace(s)")

    IO.puts("\nTo view in Chrome:")
    IO.puts("  1. Open DevTools (F12) → Performance tab")
    IO.puts("  2. Click 'Load profile...' and select a .json file")
    IO.puts("  Or navigate to chrome://tracing and load the file")

    if open? do
      case Enum.find(exported, &match?({:ok, _}, &1)) do
        {:ok, first_json} -> open_in_browser(first_json)
        nil -> :ok
      end
    end
  end

  defp print_trees(file) do
    alias PtcRunner.TraceLog.Analyzer

    files = trace_files(file)

    if Enum.empty?(files) do
      Mix.raise("No trace files found in #{trace_dir()}. Run benchmarks with --trace first.")
    end

    Enum.each(files, fn jsonl ->
      IO.puts("\n#{String.duplicate("─", 60)}")
      IO.puts("Trace: #{Path.basename(jsonl)}")
      IO.puts(String.duplicate("─", 60))

      case Analyzer.load_tree(jsonl) do
        {:ok, tree} ->
          Analyzer.print_tree(tree)

        {:error, reason} ->
          IO.puts("  Failed to load: #{inspect(reason)}")
      end
    end)
  end

  defp clean_traces do
    jsonl_files = Path.wildcard(Path.join(trace_dir(), "*.jsonl"))
    json_files = Path.wildcard(Path.join(trace_dir(), "*.json"))
    all_files = jsonl_files ++ json_files

    if Enum.empty?(all_files) do
      IO.puts("No trace files to clean")
    else
      Enum.each(all_files, fn path ->
        File.rm(path)
        IO.puts("Deleted: #{Path.basename(path)}")
      end)

      IO.puts("\nDeleted #{length(all_files)} file(s)")
    end
  end

  defp trace_files(nil) do
    Path.wildcard(Path.join(trace_dir(), "*.jsonl"))
    |> Enum.sort()
  end

  defp trace_files(file) do
    if File.exists?(file) do
      [file]
    else
      full_path = Path.join(trace_dir(), file)

      if File.exists?(full_path) do
        [full_path]
      else
        Mix.raise("Trace file not found: #{file}")
      end
    end
  end

  defp trace_dir do
    cwd = File.cwd!()

    if String.ends_with?(cwd, "examples/rlm_recursive") do
      "traces"
    else
      "examples/rlm_recursive/traces"
    end
  end

  defp open_in_browser(path) do
    case :os.type() do
      {:unix, :darwin} -> System.cmd("open", [path])
      {:unix, _} -> System.cmd("xdg-open", [path])
      {:win32, _} -> System.cmd("cmd", ["/c", "start", path])
    end
  end
end
