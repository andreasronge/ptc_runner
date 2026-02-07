#!/usr/bin/env elixir

# Benchmark runner for PageIndex retrieval
#
# Usage:
#   mix run bench.exs [options]
#   --runs N          Runs per cell (default: 1)
#   --test-set NAME   Filter: "full", "tree_rag_showcase", or doc prefix like "3M_2022_10K" (default: "3M_2022_10K")
#   --models LIST     Comma-separated (default: "bedrock:haiku,bedrock:sonnet")
#   --modes LIST      Comma-separated (default: "agent,planner")

{:ok, _} = Application.ensure_all_started(:pdf_extractor)
{:ok, _} = PdfExtractor.start_link([])

defmodule Bench do
  def main(args) do
    {opts, _rest, _} =
      OptionParser.parse(args,
        switches: [
          runs: :integer,
          test_set: :string,
          models: :string,
          modes: :string,
          help: :boolean
        ],
        aliases: [h: :help, r: :runs, s: :test_set]
      )

    if opts[:help] do
      print_help()
    else
      run_benchmark(opts)
    end
  end

  defp print_help do
    IO.puts("""
    PageIndex Benchmark Runner

    Usage:
      mix run bench.exs [options]

    Options:
      -r, --runs N          Runs per cell (default: 1)
      -s, --test-set NAME   Filter: "full", "tree_rag_showcase", or doc prefix like "3M_2022_10K" (default: "3M_2022_10K")
      --models LIST         Comma-separated models (default: "bedrock:haiku,bedrock:sonnet")
      --modes LIST          Comma-separated modes (default: "agent,planner")
      -h, --help            Show this help

    Examples:
      mix run bench.exs --runs 1 --models bedrock:haiku --modes agent
      mix run bench.exs --runs 3
      mix run bench.exs --test-set full --runs 1
    """)
  end

  defp run_benchmark(opts) do
    runs_per_cell = opts[:runs] || 1
    test_set = opts[:test_set] || "3M_2022_10K"
    models = parse_list(opts[:models] || "bedrock:haiku,bedrock:sonnet")
    modes = parse_list(opts[:modes] || "agent,planner")

    # Load questions and filter
    questions = load_questions(test_set)

    if questions == [] do
      IO.puts("No questions found for test set: #{test_set}")
      System.halt(1)
    end

    # Check which indices exist, skip questions with missing ones
    {questions, skipped} = filter_by_available_index(questions)

    for {q, reason} <- skipped do
      IO.puts("WARN: Skipping #{q["id"]} — #{reason}")
    end

    # Pre-load indices
    indices = preload_indices(questions)

    # Create output directory
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
    output_dir = "bench_runs/#{timestamp}"
    traces_dir = Path.join(output_dir, "traces")
    File.mkdir_p!(traces_dir)

    total_runs = length(questions) * length(models) * length(modes) * runs_per_cell

    IO.puts("========================================")
    IO.puts("PageIndex Benchmark — #{timestamp}")
    IO.puts("Models: #{Enum.join(models, ", ")}")
    IO.puts("Modes: #{Enum.join(modes, ", ")}")
    IO.puts("Questions: #{length(questions)}")
    IO.puts("Runs per cell: #{runs_per_cell}")
    IO.puts("Total runs: #{total_runs}")
    IO.puts("========================================\n")

    # Build run matrix
    run_entries =
      for q <- questions,
          model <- models,
          mode <- modes,
          run_num <- 1..runs_per_cell do
        {q, model, mode, run_num}
      end

    # Execute sequentially
    {results, _counter} =
      Enum.map_reduce(run_entries, 1, fn {q, model, mode, run_num}, counter ->
        model_short = model |> String.split(":") |> List.last()

        IO.write(
          "[#{counter}/#{total_runs}] Q:#{q["id"]} #{model_short}/#{mode} run #{run_num}... "
        )

        run_id = String.pad_leading("#{counter}", 3, "0")
        trace_path = Path.join(traces_dir, "run_#{run_id}_#{model_short}_#{mode}.jsonl")
        tree = Map.fetch!(indices, q["doc_name"])

        entry = run_one(q, model, mode, run_num, run_id, tree, trace_path)

        duration_str = format_duration(entry.duration_ms)
        IO.puts("#{entry.status} (#{duration_str})")

        {entry, counter + 1}
      end)

    # Write manifest
    manifest = %{
      version: 1,
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      config: %{
        models: models,
        modes: modes,
        runs_per_cell: runs_per_cell,
        test_set: test_set
      },
      runs: results
    }

    manifest_path = Path.join(output_dir, "manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))

    # Print summary
    ok_count = Enum.count(results, &(&1.status == "ok"))
    error_count = Enum.count(results, &(&1.status == "error"))

    IO.puts("\n========================================")
    IO.puts("Results: #{ok_count} OK, #{error_count} errors")
    IO.puts("Manifest: #{manifest_path}")
    IO.puts("========================================")
  end

  defp run_one(question, model, mode, run_number, run_id, tree, trace_path) do
    llm = LLMClient.callback(model)
    pdf_path = "data/#{question["doc_name"]}"
    start_time = System.monotonic_time(:millisecond)

    {status, answer, error, replans, tasks_executed} =
      try do
        {:ok, result, _path} =
          PtcRunner.TraceLog.with_trace(
            fn ->
              case mode do
                "agent" ->
                  PageIndex.Retriever.retrieve(tree, question["question"],
                    llm: llm,
                    pdf_path: pdf_path
                  )

                "planner" ->
                  PageIndex.PlannerRetriever.retrieve(tree, question["question"],
                    llm: llm,
                    pdf_path: pdf_path,
                    quality_gate: true
                  )
              end
            end,
            path: trace_path,
            meta: %{
              question_id: question["id"],
              model: model,
              mode: mode,
              run_number: run_number
            }
          )

        case result do
          {:ok, step_or_result} ->
            {answer, replans, tasks} = extract_result(mode, step_or_result)
            {"ok", answer, nil, replans, tasks}

          {:error, step_or_result} ->
            error_msg = extract_error(mode, step_or_result)
            {"error", nil, error_msg, nil, nil}
        end
      rescue
        e ->
          {"error", nil, Exception.message(e), nil, nil}
      catch
        :exit, reason ->
          {"error", nil, "exit: #{inspect(reason)}", nil, nil}
      end

    elapsed = System.monotonic_time(:millisecond) - start_time

    %{
      id: "run_#{run_id}",
      question_id: question["id"],
      question: question["question"],
      ground_truth: question["answer"],
      difficulty: question["difficulty"],
      doc_name: question["doc_name"],
      model: model,
      mode: mode,
      run_number: run_number,
      status: status,
      answer: answer,
      error: error,
      trace_path: Path.relative_to(trace_path, Path.dirname(Path.dirname(trace_path))),
      duration_ms: elapsed,
      replans: replans,
      tasks_executed: tasks_executed
    }
  end

  defp extract_result("agent", step) do
    answer = extract_answer(step.return["answer"])
    {answer, nil, nil}
  end

  defp extract_result("planner", result) do
    answer = extract_answer(result.answer)
    {answer, result.replans, result.tasks_executed}
  end

  defp extract_answer(answer) when is_binary(answer), do: answer

  defp extract_answer(answer) when is_map(answer) do
    answer["answer"] || answer["reasoning"] || inspect(answer)
  end

  defp extract_answer(answer), do: inspect(answer)

  defp extract_error("agent", step), do: inspect(step.fail)
  defp extract_error("planner", result), do: inspect(result.reason)
  defp extract_error(_, other), do: inspect(other)

  defp load_questions(test_set) do
    data = Jason.decode!(File.read!("data/questions.json"))
    all_questions = data["questions"]
    test_sets = data["test_sets"]

    cond do
      # Named test set
      Map.has_key?(test_sets, test_set) ->
        ids = MapSet.new(test_sets[test_set])
        Enum.filter(all_questions, &MapSet.member?(ids, &1["id"]))

      # Doc prefix filter
      true ->
        doc_prefix = test_set <> ".pdf"

        matching = Enum.filter(all_questions, &(&1["doc_name"] == doc_prefix))

        if matching == [] do
          # Try as a substring match
          Enum.filter(all_questions, &String.contains?(&1["doc_name"], test_set))
        else
          matching
        end
    end
  end

  defp filter_by_available_index(questions) do
    Enum.split_with(questions, fn q ->
      index_path = index_path_for(q["doc_name"])
      File.exists?(index_path)
    end)
    |> then(fn {available, missing} ->
      skipped =
        Enum.map(missing, fn q ->
          {q, "index not found: #{index_path_for(q["doc_name"])}"}
        end)

      {available, skipped}
    end)
  end

  defp preload_indices(questions) do
    questions
    |> Enum.map(& &1["doc_name"])
    |> Enum.uniq()
    |> Map.new(fn doc_name ->
      index_path = index_path_for(doc_name)
      IO.puts("Loading index: #{index_path}")
      {:ok, tree} = PageIndex.load_index(index_path)
      {doc_name, tree}
    end)
  end

  defp index_path_for(doc_name) do
    base = String.replace(doc_name, ~r/\.pdf$/i, "")
    "data/#{base}_index.json"
  end

  defp parse_list(str) do
    str |> String.split(",") |> Enum.map(&String.trim/1)
  end

  defp format_duration(ms) when ms >= 1000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{ms}ms"
end

Bench.main(System.argv())
