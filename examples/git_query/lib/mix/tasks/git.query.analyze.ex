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

  @shortdoc "Analyze TraceLog trace files"

  # TODO: Implement when #745 (core TraceLog) and #746 (nested agents) land
  #
  # This task will use:
  # - PtcRunner.TraceLog.Analyzer.load/1
  # - PtcRunner.TraceLog.Analyzer.summary/1
  # - PtcRunner.TraceLog.Analyzer.print_timeline/1
  # - PtcRunner.TraceLog.Analyzer.compare/1
  # - PtcRunner.TraceLog.Analyzer.aggregate/1
  # - PtcRunner.TraceLog.Analyzer.load_tree/1 (from #746)
  # - PtcRunner.TraceLog.Analyzer.print_tree/1 (from #746)
  # - PtcRunner.TraceLog.Analyzer.tree_summary/1 (from #746)
  # - PtcRunner.TraceLog.Analyzer.critical_path/1 (from #746)

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
    Mix.shell().info("")
    Mix.shell().info("[Stub - waiting for #745 and #746]")
    Mix.shell().info("")
    Mix.shell().info("Paths: #{inspect(paths)}")
    Mix.shell().info("Options: #{inspect(opts)}")
    Mix.shell().info("")

    cond do
      opts[:compare] ->
        Mix.shell().info("Would compare #{length(paths)} trace files")

      opts[:aggregate] ->
        Mix.shell().info("Would aggregate statistics from #{length(paths)} trace files")

      opts[:tree] ->
        Mix.shell().info("Would show tree visualization for: #{hd(paths)}")

      opts[:tree_summary] ->
        Mix.shell().info("Would show tree summary for: #{hd(paths)}")

      opts[:critical_path] ->
        Mix.shell().info("Would show critical path for: #{hd(paths)}")

      opts[:timeline] ->
        Mix.shell().info("Would show timeline for: #{hd(paths)}")

      opts[:slowest] ->
        n = opts[:slowest] || 5
        Mix.shell().info("Would show #{n} slowest operations in: #{hd(paths)}")

      true ->
        Mix.shell().info("Would show summary for: #{hd(paths)}")
    end
  end
end
