defmodule Mix.Tasks.Git.Query.Analyze do
  @moduledoc """
  Analyze TraceLog JSONL files from git.query executions.

  This is a separate task for offline analysis - it reads trace files
  and produces analysis output, it does not run queries.

  Usage:
      mix git.query.analyze PATH [OPTIONS]
      mix git.query.analyze traces/*.jsonl --compare

  Options:
      --timeline       Show ASCII timeline of execution
      --compare        Compare multiple trace files side by side
      --aggregate      Aggregate statistics across multiple traces
      --slowest N      Show N slowest operations (default: 5)
      --tree           Show nested agent tree visualization
      --tree-summary   Show aggregate stats for entire agent tree
      --critical-path  Show critical path (slowest sequential chain)

  Examples:
      mix git.query.analyze traces/my-trace.jsonl
      mix git.query.analyze traces/my-trace.jsonl --timeline
      mix git.query.analyze traces/benchmark-2024-01/*.jsonl --compare
      mix git.query.analyze traces/benchmark-2024-01/*.jsonl --aggregate
      mix git.query.analyze traces/orchestrator.jsonl --tree
  """
  use Mix.Task

  alias PtcRunner.TraceLog.Analyzer

  @shortdoc "Analyze TraceLog trace files"

  # TODO(#746): Tree-related features require nested agent support:
  # - load_tree/1, print_tree/1, tree_summary/1, critical_path/1
  #
  # TODO(#746): Multi-file features require comparison/aggregation:
  # - compare/1, aggregate/1

  def run(args) do
    {opts, paths, _} =
      OptionParser.parse(args,
        switches: [
          timeline: :boolean,
          compare: :boolean,
          aggregate: :boolean,
          slowest: :integer,
          tree: :boolean,
          tree_summary: :boolean,
          critical_path: :boolean
        ]
      )

    if paths == [] do
      Mix.shell().error("Usage: mix git.query.analyze PATH [OPTIONS]")
      Mix.shell().error("\nExample: mix git.query.analyze traces/my-trace.jsonl --timeline")
      System.halt(1)
    end

    Mix.shell().info("")
    Mix.shell().info("Git Query Trace Analyzer")
    Mix.shell().info("========================")

    cond do
      opts[:compare] ->
        # TODO(#746): Implement compare/1
        Mix.shell().info("\n[Compare: requires #746 - comparison/aggregation support]")
        Mix.shell().info("Would compare #{length(paths)} trace files")

      opts[:aggregate] ->
        # TODO(#746): Implement aggregate/1
        Mix.shell().info("\n[Aggregate: requires #746 - comparison/aggregation support]")
        Mix.shell().info("Would aggregate statistics from #{length(paths)} trace files")

      opts[:tree] ->
        # TODO(#746): Implement load_tree/1, print_tree/1
        Mix.shell().info("\n[Tree: requires #746 - nested agent support]")
        Mix.shell().info("Would show tree visualization for: #{hd(paths)}")

      opts[:tree_summary] ->
        # TODO(#746): Implement tree_summary/1
        Mix.shell().info("\n[Tree summary: requires #746 - nested agent support]")
        Mix.shell().info("Would show tree summary for: #{hd(paths)}")

      opts[:critical_path] ->
        # TODO(#746): Implement critical_path/1
        Mix.shell().info("\n[Critical path: requires #746 - nested agent support]")
        Mix.shell().info("Would show critical path for: #{hd(paths)}")

      opts[:timeline] ->
        show_timeline(hd(paths))

      opts[:slowest] ->
        n = opts[:slowest] || 5
        show_slowest(hd(paths), n)

      true ->
        show_summary(hd(paths))
    end
  end

  defp show_summary(path) do
    events = Analyzer.load(path)
    summary = Analyzer.summary(events)

    Mix.shell().info("\nFile: #{path}")
    Mix.shell().info("")
    Mix.shell().info("Summary")
    Mix.shell().info("───────")
    Mix.shell().info("  Duration:   #{summary.duration_ms || "N/A"}ms")
    Mix.shell().info("  Turns:      #{summary.turns || "N/A"}")
    Mix.shell().info("  LLM calls:  #{summary.llm_calls}")
    Mix.shell().info("  Tool calls: #{summary.tool_calls}")
    Mix.shell().info("  Status:     #{summary.status || "N/A"}")

    if summary.tokens do
      Mix.shell().info("  Tokens:     #{summary.tokens.input} in / #{summary.tokens.output} out")
    end
  end

  defp show_timeline(path) do
    events = Analyzer.load(path)

    Mix.shell().info("\nFile: #{path}")
    Mix.shell().info("")
    Mix.shell().info("Timeline")
    Mix.shell().info("────────")
    Analyzer.print_timeline(events)
  end

  defp show_slowest(path, n) do
    events = Analyzer.load(path)
    slowest = Analyzer.slowest(events, n)

    Mix.shell().info("\nFile: #{path}")
    Mix.shell().info("")
    Mix.shell().info("#{n} Slowest Operations")
    Mix.shell().info("─────────────────────")

    Enum.each(slowest, fn event ->
      duration = event["duration_ms"] || 0
      event_type = event["event"]
      Mix.shell().info("  #{duration}ms - #{event_type}")
    end)
  end
end
