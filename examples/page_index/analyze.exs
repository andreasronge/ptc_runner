#!/usr/bin/env elixir

# Analyze benchmark results from bench.exs
#
# Usage:
#   mix run analyze.exs <path_to_manifest_or_dir> [options]
#   --judge           Enable LLM-as-judge (off by default, costs money)
#   --model MODEL     Judge model (default: "bedrock:sonnet")

defmodule Analyze do
  alias PtcRunner.TraceLog.Analyzer

  def main(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        switches: [
          judge: :boolean,
          model: :string,
          help: :boolean
        ],
        aliases: [h: :help, m: :model]
      )

    cond do
      opts[:help] ->
        print_help()

      rest == [] ->
        # Try to find the latest manifest
        case find_latest_manifest() do
          nil ->
            IO.puts("Usage: mix run analyze.exs <manifest.json or bench_runs/<timestamp>>")
            IO.puts("No bench_runs/ directory found.")

          path ->
            IO.puts("Using latest: #{path}\n")
            analyze(path, opts)
        end

      true ->
        path = resolve_manifest_path(hd(rest))
        analyze(path, opts)
    end
  end

  defp print_help do
    IO.puts("""
    PageIndex Benchmark Analyzer

    Usage:
      mix run analyze.exs [manifest_or_dir] [options]

    Arguments:
      manifest_or_dir   Path to manifest.json or bench_runs/<timestamp> dir
                        (defaults to latest bench run)

    Options:
      --judge           Enable LLM-as-judge correctness evaluation
      -m, --model MODEL Judge model (default: "bedrock:sonnet")
      -h, --help        Show this help

    Examples:
      mix run analyze.exs                                    # Latest run
      mix run analyze.exs bench_runs/20260207T143052Z        # Specific run
      mix run analyze.exs bench_runs/20260207T143052Z --judge
    """)
  end

  defp find_latest_manifest do
    case File.ls("bench_runs") do
      {:ok, dirs} ->
        dirs
        |> Enum.sort(:desc)
        |> Enum.find_value(fn dir ->
          path = Path.join(["bench_runs", dir, "manifest.json"])
          if File.exists?(path), do: path
        end)

      {:error, _} ->
        nil
    end
  end

  defp resolve_manifest_path(path) do
    cond do
      String.ends_with?(path, ".json") -> path
      File.dir?(path) -> Path.join(path, "manifest.json")
      true -> path
    end
  end

  defp analyze(manifest_path, opts) do
    unless File.exists?(manifest_path) do
      IO.puts("Error: #{manifest_path} not found")
      System.halt(1)
    end

    manifest = Jason.decode!(File.read!(manifest_path))
    base_dir = Path.dirname(manifest_path)
    runs = manifest["runs"]

    IO.puts("Benchmark: #{manifest["timestamp"]}")
    IO.puts("Config: #{inspect(manifest["config"])}\n")

    # Enrich runs with trace stats
    enriched =
      Enum.map(runs, fn run ->
        trace_path = Path.join(base_dir, run["trace_path"])
        stats = extract_trace_stats(trace_path)

        planner_stats =
          if run["mode"] == "planner", do: extract_planner_stats(trace_path), else: %{}

        run
        |> Map.merge(stats)
        |> Map.merge(planner_stats)
      end)

    # Optionally judge correctness
    enriched =
      if opts[:judge] do
        judge_model = opts[:model] || "bedrock:sonnet"
        IO.puts("Running LLM-as-judge with #{judge_model}...\n")
        judge_runs(enriched, judge_model)
      else
        enriched
      end

    # Print results table
    print_table(enriched, opts[:judge])

    # Print summary
    print_summary(enriched, opts[:judge])
  end

  defp extract_trace_stats(trace_path) do
    if File.exists?(trace_path) do
      events = Analyzer.load(trace_path)
      summary = Analyzer.summary(events)

      tool_names = build_tool_frequency(events)

      %{
        "trace_duration_ms" => summary.duration_ms,
        "turns" => summary.turns,
        "llm_calls" => summary.llm_calls,
        "tool_calls" => summary.tool_calls,
        "tool_names" => tool_names,
        "tokens" => format_tokens(summary.tokens)
      }
    else
      %{
        "trace_duration_ms" => nil,
        "turns" => nil,
        "llm_calls" => 0,
        "tool_calls" => 0,
        "tool_names" => %{},
        "tokens" => nil
      }
    end
  end

  defp build_tool_frequency(events) do
    events
    |> Enum.filter(&(&1["event"] == "tool.stop"))
    |> Enum.map(&get_in(&1, ["metadata", "tool_name"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  defp format_tokens(nil), do: nil

  defp format_tokens(tokens) do
    %{
      "input" => tokens.input,
      "output" => tokens.output,
      "total" => tokens.total
    }
  end

  defp extract_planner_stats(trace_path) do
    if File.exists?(trace_path) do
      events = Analyzer.load(trace_path)

      # Parse agent types from the first LLM response (the plan)
      agent_types = extract_agent_types(events)

      # Count planned tasks from the plan JSON
      planned_tasks = extract_planned_task_count(events)

      %{
        "agent_types" => agent_types,
        "planned_tasks" => planned_tasks
      }
    else
      %{}
    end
  end

  defp extract_agent_types(events) do
    # Find the first llm.stop event — its response contains the plan JSON
    first_llm_stop =
      events
      |> Enum.find(&(&1["event"] == "llm.stop"))

    case first_llm_stop do
      nil ->
        []

      event ->
        response = get_in(event, ["metadata", "response"]) || ""
        parse_agent_types_from_plan(response)
    end
  end

  defp parse_agent_types_from_plan(response) when is_binary(response) do
    # Try to extract JSON from the response (may be wrapped in code blocks)
    json_str =
      case Regex.run(~r/```(?:json)?\s*\n(.*?)```/s, response) do
        [_, json] -> json
        _ -> response
      end

    case Jason.decode(json_str) do
      {:ok, %{"agents" => agents}} when is_map(agents) ->
        agents
        |> Map.keys()
        |> Enum.reject(&(&1 == "direct"))

      _ ->
        []
    end
  end

  defp parse_agent_types_from_plan(_), do: []

  defp extract_planned_task_count(events) do
    first_llm_stop = Enum.find(events, &(&1["event"] == "llm.stop"))

    case first_llm_stop do
      nil ->
        nil

      event ->
        response = get_in(event, ["metadata", "response"]) || ""

        json_str =
          case Regex.run(~r/```(?:json)?\s*\n(.*?)```/s, response) do
            [_, json] -> json
            _ -> response
          end

        case Jason.decode(json_str) do
          {:ok, %{"tasks" => tasks}} when is_list(tasks) -> length(tasks)
          _ -> nil
        end
    end
  end

  defp judge_runs(runs, judge_model) do
    llm = LLMClient.callback(judge_model)

    Enum.map(runs, fn run ->
      if run["status"] == "ok" and run["answer"] do
        verdict = judge_one(run, llm)
        Map.merge(run, verdict)
      else
        Map.merge(run, %{"verdict" => "skipped", "reasoning" => "run failed"})
      end
    end)
  end

  defp judge_one(run, llm) do
    prompt = """
    You are evaluating the correctness of a RAG system's answer against a ground truth.

    QUESTION: #{run["question"]}

    GROUND TRUTH: #{run["ground_truth"]}

    CANDIDATE ANSWER: #{run["answer"]}

    Judge the correctness of the candidate answer compared to the ground truth.
    Focus on factual accuracy, not exact wording. Consider:
    - Does the candidate capture the key facts from the ground truth?
    - Are the numbers/values approximately correct?
    - Is the overall conclusion correct?
    """

    case PtcRunner.SubAgent.run(prompt,
           output: :json,
           signature: "{verdict :string, reasoning :string}",
           llm: llm
         ) do
      {:ok, step} ->
        raw_verdict = step.return["verdict"] || "unknown"

        %{
          "verdict" => normalize_verdict(raw_verdict),
          "reasoning" => step.return["reasoning"] || ""
        }

      {:error, _} ->
        %{"verdict" => "error", "reasoning" => "judge failed"}
    end
  end

  defp normalize_verdict(raw) do
    case String.downcase(String.trim(raw)) do
      "correct" -> "correct"
      "partially_correct" -> "partially_correct"
      "partially correct" -> "partially_correct"
      "partially" -> "partially_correct"
      "partial" -> "partially_correct"
      "incorrect" -> "incorrect"
      other -> other
    end
  end

  defp print_table(runs, judge?) do
    # Header
    header =
      if judge? do
        "#{pad("Question (diff)", 30)} | #{pad("Model", 8)} | #{pad("Mode", 8)} | #{pad("Time", 7)} | #{pad("Turns", 5)} | #{pad("Tools", 5)} | #{pad("Tokens", 8)} | #{pad("Verdict", 18)}"
      else
        "#{pad("Question (diff)", 30)} | #{pad("Model", 8)} | #{pad("Mode", 8)} | #{pad("Time", 7)} | #{pad("Turns", 5)} | #{pad("Tools", 5)} | #{pad("Tokens", 8)}"
      end

    separator = String.duplicate("-", String.length(header))
    IO.puts(separator)
    IO.puts(header)
    IO.puts(separator)

    # Group by question for visual clarity
    runs
    |> Enum.group_by(& &1["question_id"])
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.each(fn {_qid, question_runs} ->
      first = hd(question_runs)
      difficulty_char = String.first(first["difficulty"] || "?") |> String.upcase()
      question_label = String.slice(first["question"], 0, 26) <> " (#{difficulty_char})"

      Enum.with_index(question_runs)
      |> Enum.each(fn {run, idx} ->
        q_col = if idx == 0, do: pad(question_label, 30), else: pad("", 30)
        model_short = run["model"] |> String.split(":") |> List.last()
        time_str = format_time(run["duration_ms"])
        turns_str = if run["turns"], do: "#{run["turns"]}", else: "-"
        tools_str = "#{run["tool_calls"] || 0}"
        tokens_str = format_token_count(run["tokens"])

        line =
          "#{q_col} | #{pad(model_short, 8)} | #{pad(run["mode"], 8)} | #{pad(time_str, 7)} | #{pad(turns_str, 5)} | #{pad(tools_str, 5)} | #{pad(tokens_str, 8)}"

        line =
          if judge? do
            verdict = run["verdict"] || "-"
            "#{line} | #{pad(verdict, 18)}"
          else
            line
          end

        IO.puts(line)
      end)

      IO.puts("")
    end)
  end

  defp print_summary(runs, judge?) do
    ok_runs = Enum.filter(runs, &(&1["status"] == "ok"))
    error_runs = Enum.filter(runs, &(&1["status"] == "error"))

    IO.puts("Summary:")
    IO.puts("  Runs: #{length(ok_runs)} OK, #{length(error_runs)} errors")

    if judge? do
      verdicts = Enum.frequencies_by(runs, & &1["verdict"])
      correct = Map.get(verdicts, "correct", 0)
      partial = Map.get(verdicts, "partially_correct", 0)
      incorrect = Map.get(verdicts, "incorrect", 0)
      IO.puts("  Correctness: #{correct} correct, #{partial} partial, #{incorrect} incorrect")
    end

    # Per-mode averages
    for mode <- ["agent", "planner"] do
      mode_runs = Enum.filter(ok_runs, &(&1["mode"] == mode))

      if mode_runs != [] do
        avg_duration = avg(mode_runs, & &1["duration_ms"])
        avg_tokens = avg_tokens(mode_runs)

        IO.puts(
          "  Avg #{mode}: #{format_time(avg_duration)}, #{format_token_count_raw(avg_tokens)} tokens"
        )
      end
    end

    # Planner agent types
    planner_runs = Enum.filter(runs, &(&1["mode"] == "planner"))

    agent_types =
      planner_runs
      |> Enum.flat_map(&(Map.get(&1, "agent_types") || []))
      |> Enum.uniq()
      |> Enum.sort()

    if agent_types != [] do
      IO.puts("  Planner agent types: #{Enum.join(agent_types, ", ")}")
    end
  end

  defp avg([], _fun), do: 0

  defp avg(runs, fun) do
    values = Enum.map(runs, fun) |> Enum.reject(&is_nil/1)
    if values == [], do: 0, else: Enum.sum(values) / length(values)
  end

  defp avg_tokens(runs) do
    totals =
      runs
      |> Enum.map(&get_in(&1, ["tokens", "total"]))
      |> Enum.reject(&is_nil/1)

    if totals == [], do: 0, else: Enum.sum(totals) / length(totals)
  end

  defp format_time(nil), do: "-"
  defp format_time(ms) when is_float(ms), do: format_time(round(ms))
  defp format_time(ms) when ms >= 1000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_time(ms), do: "#{ms}ms"

  defp format_token_count(nil), do: "-"

  defp format_token_count(%{"total" => total}) when is_integer(total) do
    format_token_count_raw(total)
  end

  defp format_token_count(_), do: "-"

  defp format_token_count_raw(n) when is_number(n) and n >= 1000 do
    "#{Float.round(n / 1000, 1)}k"
  end

  defp format_token_count_raw(n) when is_number(n), do: "#{round(n)}"
  defp format_token_count_raw(_), do: "-"

  defp pad(str, width) do
    str = to_string(str)
    len = String.length(str)

    if len >= width do
      String.slice(str, 0, width)
    else
      str <> String.duplicate(" ", width - len)
    end
  end
end

Analyze.main(System.argv())
