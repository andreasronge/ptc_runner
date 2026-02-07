#!/usr/bin/env elixir

# PageIndex - Hierarchical Document Retrieval
#
# Usage:
#   mix run run.exs --index data/3M_2022_10K.pdf    # Create index
#   mix run run.exs --show data/3M_2022_10K_index.json  # Show existing index

# Start PdfExtractor GenServer (requires Python with pdfplumber)
{:ok, _} = Application.ensure_all_started(:pdf_extractor)
{:ok, _} = PdfExtractor.start_link([])

defmodule CLI do
  def main(args) do
    {opts, _rest, _} =
      OptionParser.parse(args,
        switches: [
          index: :string,
          show: :string,
          query: :string,
          pdf: :string,
          simple: :boolean,
          planner: :boolean,
          iterative: :boolean,
          trace: :boolean,
          model: :string,
          help: :boolean
        ],
        aliases: [
          h: :help,
          m: :model,
          q: :query,
          s: :simple,
          p: :planner,
          i: :iterative,
          t: :trace
        ]
      )

    cond do
      opts[:help] ->
        print_help()

      opts[:query] ->
        query_index(opts[:query], opts)

      opts[:index] ->
        index_document(opts[:index], opts)

      opts[:show] ->
        show_index(opts[:show])

      true ->
        IO.puts("No command specified. Use --help for usage.")
    end
  end

  defp print_help do
    IO.puts("""
    PageIndex - Hierarchical Document Retrieval

    Usage:
      mix run run.exs --index <pdf>                   Create index (TOC-based)
      mix run run.exs --query "<question>" --pdf <pdf> Query the index
      mix run run.exs --show <json>                    Display existing index

    Options:
      -m, --model <name>    LLM model (default: bedrock:haiku)
      --pdf <path>          PDF path for queries (required with --query)
      -s, --simple          Use simple retrieval (score all nodes, no recursion)
      -p, --planner         Use MetaPlanner for complex multi-hop questions
      -i, --iterative       Use iterative extraction/synthesis loop
      -t, --trace           Enable tracing (writes to traces/ directory)
      -h, --help            Show this help

    Examples:
      mix run run.exs --index data/3M_2022_10K.pdf
      mix run run.exs --query "What are 3M's business segments?" --pdf data/3M_2022_10K.pdf
      mix run run.exs --query "What drove operating margin change?" --pdf data/3M_2022_10K.pdf --simple
      mix run run.exs --show data/3M_2022_10K_index.json
    """)
  end

  defp index_document(pdf_path, opts) do
    model = opts[:model] || "bedrock:haiku"

    IO.puts("Indexing: #{pdf_path}")
    IO.puts("Model: #{model}\n")

    llm = LLMClient.callback(model)

    case PageIndex.index(pdf_path, llm: llm) do
      {:ok, tree} ->
        index_path = index_path_for(pdf_path)
        PageIndex.save_index(tree, index_path)

        node_count = count_nodes(tree)
        IO.puts("\n✓ Index saved to: #{index_path}")
        IO.puts("Total nodes: #{node_count}\n")

        IO.puts("Index structure:")
        PageIndex.print_tree(tree)

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
    end
  end

  defp count_nodes(tree) do
    children = Map.get(tree, :children, [])
    1 + Enum.sum(Enum.map(children, &count_nodes/1))
  end

  defp query_index(query, opts) do
    model = opts[:model] || "bedrock:haiku"
    simple = opts[:simple] || false
    planner = opts[:planner] || false
    iterative = opts[:iterative] || false
    trace = opts[:trace] || false

    pdf_path = opts[:pdf]

    unless pdf_path do
      IO.puts("Error: --pdf <path> is required with --query")
      System.halt(1)
    end

    index_path = index_path_for(pdf_path)

    mode =
      cond do
        iterative -> "iterative (extraction loop)"
        planner -> "planner (MetaPlanner with verification)"
        simple -> "simple (score all nodes)"
        true -> "agent (single-pass)"
      end

    IO.puts("Query: #{query}")
    IO.puts("Model: #{model}")
    IO.puts("Index: #{index_path}")
    IO.puts("Mode: #{mode}")
    if trace, do: IO.puts("Tracing: enabled")
    IO.puts("")

    llm = LLMClient.callback(model)

    case PageIndex.load_index(index_path) do
      {:ok, tree} ->
        cond do
          iterative ->
            run_iterative_query(tree, query, llm, pdf_path, trace: trace)

          planner ->
            run_planner_query(tree, query, llm, pdf_path, trace: trace)

          simple ->
            run_simple_query(tree, query, llm, pdf_path, trace: trace)

          true ->
            run_agent_query(tree, query, llm, pdf_path, trace: trace)
        end

      {:error, reason} ->
        IO.puts("Error loading index: #{inspect(reason)}")
        IO.puts("Run --index #{pdf_path} first to create the index.")
    end
  end

  defp index_path_for(pdf_path) do
    String.replace(pdf_path, ~r/\.pdf$/i, "_index.json")
  end

  defp with_optional_trace(trace?, prefix, query, func) do
    if trace? do
      File.mkdir_p!("traces")
      trace_file = "traces/#{prefix}_#{System.system_time(:second)}.jsonl"

      {:ok, result, path} =
        PtcRunner.TraceLog.with_trace(func,
          path: trace_file,
          meta: %{query: query, mode: prefix}
        )

      IO.puts("\nTrace written to: #{path}")
      IO.puts("View with: open priv/trace_viewer.html (then drop the .jsonl file)")
      result
    else
      func.()
    end
  end

  defp run_iterative_query(tree, query, llm, pdf_path, opts) do
    retriever_opts = [llm: llm, pdf_path: pdf_path]

    result =
      with_optional_trace(opts[:trace], "iterative", query, fn ->
        PageIndex.IterativeRetriever.retrieve(tree, query, retriever_opts)
      end)

    case result do
      {:ok, result} ->
        IO.puts("\n" <> String.duplicate("=", 60))
        IO.puts("ANSWER (#{result.iterations} iterations, #{result.findings_count} findings):")
        IO.puts(String.duplicate("=", 60))
        IO.puts(inspect_answer(result.answer))

        IO.puts("\nSources: #{Enum.join(result.sources || [], ", ")}")

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
    end
  end

  defp run_planner_query(tree, query, llm, pdf_path, opts) do
    retriever_opts = [llm: llm, pdf_path: pdf_path, quality_gate: true]

    result =
      with_optional_trace(opts[:trace], "planner", query, fn ->
        PageIndex.PlannerRetriever.retrieve(tree, query, retriever_opts)
      end)

    case result do
      {:ok, result} ->
        IO.puts("\n" <> String.duplicate("=", 60))
        IO.puts("ANSWER (after #{result.replans} replans, #{result.tasks_executed} tasks):")
        IO.puts(String.duplicate("=", 60))
        IO.puts(inspect_answer(result.answer))

        IO.puts("\nSources:")

        for source <- result.sources || [] do
          IO.puts("  - #{source.node_id} (pages #{source.pages})")
        end

      {:error, result} ->
        IO.puts("Error: #{inspect(result.reason)}")
        IO.puts("Replans attempted: #{result.replans}")
    end
  end

  defp run_simple_query(tree, query, llm, pdf_path, opts) do
    result =
      with_optional_trace(opts[:trace], "simple", query, fn ->
        PageIndex.Retriever.retrieve_simple(tree, query, llm: llm, pdf_path: pdf_path)
      end)

    case result do
      {:ok, result} ->
        IO.puts("\n" <> String.duplicate("=", 60))
        IO.puts("ANSWER:")
        IO.puts(String.duplicate("=", 60))
        IO.puts(result["answer"])
        IO.puts("\nSources: #{Enum.join(result["sources"] || [], ", ")}")

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
    end
  end

  defp run_agent_query(tree, query, llm, pdf_path, opts) do
    result =
      with_optional_trace(opts[:trace], "agent", query, fn ->
        PageIndex.Retriever.retrieve(tree, query, llm: llm, pdf_path: pdf_path)
      end)

    case result do
      {:ok, step} ->
        IO.puts("\n" <> String.duplicate("=", 60))
        IO.puts("ANSWER:")
        IO.puts(String.duplicate("=", 60))
        IO.puts(step.return["answer"])

        IO.puts("\nSources:")

        for source <- step.return["sources"] || [] do
          IO.puts("  - #{source["node_id"]} (pages #{source["pages"]})")
        end

      {:error, step} ->
        IO.puts("Error: #{inspect(step.fail)}")
    end
  end

  defp inspect_answer(answer) when is_binary(answer), do: answer

  defp inspect_answer(answer) when is_map(answer) do
    answer["answer"] || answer["reasoning"] || inspect(answer)
  end

  defp inspect_answer(answer), do: inspect(answer)

  defp show_index(json_path) do
    case PageIndex.load_index(json_path) do
      {:ok, tree} ->
        IO.puts("Index: #{json_path}\n")
        PageIndex.print_tree(tree)

      {:error, reason} ->
        IO.puts("Error loading index: #{inspect(reason)}")
    end
  end
end

CLI.main(System.argv())
