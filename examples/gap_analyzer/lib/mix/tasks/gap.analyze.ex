defmodule Mix.Tasks.Gap.Analyze do
  @moduledoc """
  Mix task to run compliance gap analysis.

  Usage:
      mix gap.analyze [OPTIONS]

  Options:
      --topic, -t      Starting topic to search for (default: "encryption")
      --all, -a        Analyze all requirements (ignores --topic)
      --iterations, -i Max investigation iterations (default: 3)
      --batch, -b      Requirements per iteration (default: 3)
      --debug, -d      Show debug output
  """
  use Mix.Task

  @shortdoc "Analyze requirements against policy for compliance gaps"

  def run(args) do
    Application.ensure_all_started(:gap_analyzer)
    GapAnalyzer.Env.load()

    {opts, _remaining, _} =
      OptionParser.parse(args,
        switches: [
          topic: :string,
          all: :boolean,
          iterations: :integer,
          batch: :integer,
          debug: :boolean
        ],
        aliases: [
          t: :topic,
          a: :all,
          i: :iterations,
          b: :batch,
          d: :debug
        ]
      )

    analyze_opts = [
      topic: opts[:topic] || "encryption",
      max_iterations: opts[:iterations] || 3,
      batch_size: opts[:batch] || 3,
      debug: opts[:debug] || false
    ]

    Mix.shell().info("Gap Analyzer - Elixir-driven Investigation")
    Mix.shell().info("==========================================\n")

    # Show LLM info
    model = LLMClient.default_model()
    Mix.shell().info("LLM: #{model}")

    # Quick LLM test
    case LLMClient.generate_text(model, [%{role: :user, content: "Say OK"}]) do
      {:ok, _} ->
        Mix.shell().info("LLM connection: OK\n")

      {:error, reason} ->
        Mix.shell().error("LLM connection failed: #{inspect(reason)}")
        System.halt(1)
    end

    result =
      if opts[:all] do
        Mix.shell().info("Mode: Analyzing ALL requirements")
        GapAnalyzer.analyze_all(analyze_opts)
      else
        Mix.shell().info("Mode: Topic-based analysis")
        Mix.shell().info("Starting topic: #{analyze_opts[:topic]}\n")
        GapAnalyzer.analyze(analyze_opts)
      end

    case result do
      {:ok, report} ->
        print_report(report)

      {:error, reason} ->
        Mix.shell().error("\nAnalysis failed!")
        Mix.shell().error(inspect(reason, pretty: true))
    end
  end

  defp print_report(report) do
    Mix.shell().info("\n" <> String.duplicate("=", 60))
    Mix.shell().info("GAP ANALYSIS REPORT")
    Mix.shell().info(String.duplicate("=", 60))

    # Summary stats
    compliant = report[:compliant_count] || report["compliant_count"] || 0
    gaps = report[:gap_count] || report["gap_count"] || 0
    findings = report[:findings] || []

    Mix.shell().info("\nSummary:")
    Mix.shell().info("  Findings:    #{length(findings)}")
    Mix.shell().info("  Compliant:   #{compliant}")
    Mix.shell().info("  Gaps:        #{gaps}")

    # Executive summary
    summary = report[:summary] || report["summary"]

    if summary do
      Mix.shell().info("\nExecutive Summary:")
      Mix.shell().info("  #{summary}")
    end

    # Critical gaps
    critical = report[:critical_gaps] || report["critical_gaps"] || []

    if length(critical) > 0 do
      Mix.shell().info("\nCritical Gaps:")

      Enum.each(critical, fn gap ->
        gap_text = if is_map(gap), do: inspect(gap), else: gap
        Mix.shell().info("  - #{gap_text}")
      end)
    end

    # Recommendations
    recs = report[:recommendations] || report["recommendations"] || []

    if length(recs) > 0 do
      Mix.shell().info("\nRecommendations:")

      Enum.each(recs, fn rec ->
        rec_text = if is_map(rec), do: inspect(rec), else: rec
        Mix.shell().info("  - #{rec_text}")
      end)
    end

    # Detailed findings
    if length(findings) > 0 do
      Mix.shell().info("\n" <> String.duplicate("-", 60))
      Mix.shell().info("DETAILED FINDINGS")
      Mix.shell().info(String.duplicate("-", 60))

      Enum.each(findings, fn finding ->
        req_id = finding[:requirement_id] || finding["requirement_id"] || "Unknown"
        status = finding[:status] || finding["status"] || "unknown"
        gap = finding[:gap] || finding["gap"]
        reasoning = finding[:reasoning] || finding["reasoning"]

        status_icon =
          case String.downcase(to_string(status)) do
            "compliant" -> "[OK]"
            "gap" -> "[GAP]"
            _ -> "[?]"
          end

        Mix.shell().info("\n#{status_icon} #{req_id}")

        if gap do
          gap_text = if is_map(gap), do: inspect(gap), else: gap
          Mix.shell().info("  Gap: #{gap_text}")
        end

        if reasoning do
          reasoning_text = if is_map(reasoning), do: inspect(reasoning), else: reasoning
          Mix.shell().info("  Reasoning: #{String.slice(to_string(reasoning_text), 0, 200)}...")
        end
      end)
    end

    Mix.shell().info("\n" <> String.duplicate("=", 60))
  end
end
