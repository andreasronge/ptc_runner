defmodule Mix.Tasks.Git.Query do
  @moduledoc """
  Query a git repository with natural language.

  Usage:
      mix git.query "question" [OPTIONS]

  Options:
      --repo, -r           Path to the git repository (default: current directory)
      --debug, -d          Show debug output
      --model, -m          LLM model to use
      --trace [PATH]       Enable trace collection (default: traces/{timestamp}.jsonl)
      --trace-summary      Print execution summary after query (requires --trace)
      --trace-timeline     Print ASCII timeline after query (requires --trace)

  Examples:
      mix git.query "Who contributed most this month?"
      mix git.query "What files changed the most recently?" --debug
      mix git.query "Show Alice's recent commits" --repo /path/to/repo
      mix git.query "Recent commits" --trace
      mix git.query "Recent commits" --trace traces/my-trace.jsonl --trace-summary
  """
  use Mix.Task

  @shortdoc "Query a git repository with natural language"

  def run(args) do
    Application.ensure_all_started(:git_query)
    GitQuery.Env.load()

    {opts, remaining, _} =
      OptionParser.parse(args,
        switches: [
          repo: :string,
          debug: :boolean,
          model: :string,
          trace: :string,
          trace_summary: :boolean,
          trace_timeline: :boolean
        ],
        aliases: [
          r: :repo,
          d: :debug,
          m: :model
        ]
      )

    question = Enum.join(remaining, " ")

    if question == "" do
      Mix.shell().error("Usage: mix git.query \"question\" [--repo PATH] [--debug]")
      Mix.shell().error("\nExample: mix git.query \"Who contributed most this month?\"")
      System.halt(1)
    end

    repo_path = opts[:repo] || File.cwd!()
    repo_path = Path.expand(repo_path)

    Mix.shell().info("")
    Mix.shell().info("Git Query")
    Mix.shell().info("=========")
    Mix.shell().info("Question: #{question}")
    Mix.shell().info("Repository: #{repo_path}")

    # Show LLM info
    model = opts[:model] || LLMClient.default_model()
    Mix.shell().info("LLM: #{model}")

    # Quick LLM test
    case LLMClient.generate_text(model, [%{role: :user, content: "Say OK"}]) do
      {:ok, _} ->
        Mix.shell().info("LLM connection: OK\n")

      {:error, reason} ->
        Mix.shell().error("LLM connection failed: #{inspect(reason)}")
        System.halt(1)
    end

    query_opts = [
      repo: repo_path,
      debug: opts[:debug] || false,
      model: opts[:model]
    ]

    # Run query with optional tracing
    {result, trace_path} = run_with_trace(question, query_opts, opts)

    case result do
      {:ok, answer} ->
        Mix.shell().info("\nAnswer:")
        Mix.shell().info("-------")
        Mix.shell().info(answer)
        Mix.shell().info("")

        # Show trace output if enabled
        if trace_path do
          Mix.shell().info("Trace: #{trace_path}")
          maybe_print_trace_summary(trace_path, opts)
          maybe_print_trace_timeline(trace_path, opts)
        end

      {:error, reason} ->
        Mix.shell().error("\nQuery failed!")
        Mix.shell().error(inspect(reason, pretty: true))
        System.halt(1)
    end
  end

  # Run query, optionally wrapped with trace collection
  defp run_with_trace(question, query_opts, opts) do
    if opts[:trace] do
      trace_path = trace_path(opts[:trace])

      # Ensure trace directory exists
      trace_path |> Path.dirname() |> File.mkdir_p!()

      {:ok, result, path} =
        PtcRunner.TraceLog.with_trace(
          fn -> GitQuery.query(question, query_opts) end,
          path: trace_path,
          meta: %{query: question, model: query_opts[:model]}
        )

      Mix.shell().info("Trace: #{path}")
      {result, path}
    else
      {GitQuery.query(question, query_opts), nil}
    end
  end

  defp trace_path(path) when is_binary(path) and path != "", do: path

  defp trace_path(_) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic)
    "traces/#{timestamp}.jsonl"
  end

  defp maybe_print_trace_summary(trace_path, opts) do
    if opts[:trace_summary] and trace_path do
      events = PtcRunner.TraceLog.Analyzer.load(trace_path)
      summary = PtcRunner.TraceLog.Analyzer.summary(events)
      print_summary(summary)
    end
  end

  defp print_summary(summary) do
    Mix.shell().info("\nTrace Summary")
    Mix.shell().info("─────────────")
    Mix.shell().info("  Duration:   #{summary.duration_ms || "N/A"}ms")
    Mix.shell().info("  Turns:      #{summary.turns || "N/A"}")
    Mix.shell().info("  LLM calls:  #{summary.llm_calls}")
    Mix.shell().info("  Tool calls: #{summary.tool_calls}")

    if summary.tokens do
      Mix.shell().info("  Tokens:     #{summary.tokens.input} in / #{summary.tokens.output} out")
    end
  end

  defp maybe_print_trace_timeline(trace_path, opts) do
    if opts[:trace_timeline] and trace_path do
      events = PtcRunner.TraceLog.Analyzer.load(trace_path)
      Mix.shell().info("\nTrace Timeline")
      Mix.shell().info("──────────────")
      PtcRunner.TraceLog.Analyzer.print_timeline(events)
    end
  end
end
