#!/usr/bin/env elixir

# PageIndex - Hierarchical Document Retrieval
#
# Usage:
#   mix run run.exs --index data/3M_2022_10K.pdf    # Create index
#   mix run run.exs --parse data/3M_2022_10K.pdf    # Parse only (no LLM)
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
          fine: :string,
          parse: :string,
          show: :string,
          query: :string,
          simple: :boolean,
          planner: :boolean,
          trace: :boolean,
          model: :string,
          help: :boolean
        ],
        aliases: [h: :help, m: :model, f: :fine, q: :query, s: :simple, p: :planner, t: :trace]
      )

    cond do
      opts[:help] ->
        print_help()

      opts[:query] ->
        query_index(opts[:query], opts)

      opts[:fine] ->
        fine_index_document(opts[:fine], opts)

      opts[:index] ->
        index_document(opts[:index], opts)

      opts[:parse] ->
        parse_document(opts[:parse])

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
      mix run run.exs --query "<question>"  Query the index (uses fine index)
      mix run run.exs --fine <pdf>          Create fine-grained index (TOC-based)
      mix run run.exs --index <pdf>         Create basic index (Item-level only)
      mix run run.exs --parse <pdf>         Parse structure only (no LLM)
      mix run run.exs --show <json>         Display existing index

    Options:
      -m, --model <name>    LLM model (default: bedrock:haiku)
      -s, --simple          Use simple retrieval (score all nodes, no recursion)
      -p, --planner         Use MetaPlanner for complex multi-hop questions
      -t, --trace           Enable tracing (writes to traces/ directory)
      -h, --help            Show this help

    Examples:
      mix run run.exs --query "What are 3M's business segments?"
      mix run run.exs --query "What drove operating margin change?" --simple
      mix run run.exs --fine data/3M_2022_10K.pdf
      mix run run.exs --show data/3M_2022_10K_fine_index.json
    """)
  end

  defp parse_document(pdf_path) do
    IO.puts("Parsing: #{pdf_path}\n")

    case PageIndex.parse(pdf_path) do
      {:ok, sections} ->
        IO.puts("Found #{length(sections)} sections:\n")

        for section <- sections do
          IO.puts("  #{section.id}: #{section.title}")
          IO.puts("    Pages: #{section.start_page}-#{section.end_page}")
          IO.puts("    Content: #{String.length(section.content)} chars")
          IO.puts("")
        end

      {:error, reason} ->
        IO.puts("Error: #{reason}")
    end
  end

  defp index_document(pdf_path, opts) do
    model = opts[:model] || "bedrock:haiku"

    IO.puts("Indexing: #{pdf_path}")
    IO.puts("Model: #{model}\n")

    # Create LLM callback for SubAgent
    llm = LLMClient.callback(model)

    case PageIndex.index(pdf_path, llm: llm) do
      {:ok, tree} ->
        # Save index
        index_path = String.replace(pdf_path, ~r/\.pdf$/i, "_index.json")
        PageIndex.save_index(tree, index_path)
        IO.puts("\n✓ Index saved to: #{index_path}\n")

        # Print tree
        IO.puts("Index structure:")
        PageIndex.print_tree(tree)

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
    end
  end

  defp fine_index_document(pdf_path, opts) do
    model = opts[:model] || "bedrock:haiku"

    IO.puts("Fine-grained Indexing: #{pdf_path}")
    IO.puts("Model: #{model}\n")

    llm = LLMClient.callback(model)

    case PageIndex.FineIndexer.index(pdf_path, llm: llm) do
      {:ok, tree} ->
        # Save index
        index_path = String.replace(pdf_path, ~r/\.pdf$/i, "_fine_index.json")
        PageIndex.FineIndexer.save(tree, index_path)
        IO.puts("\n✓ Fine index saved to: #{index_path}")

        # Count nodes
        node_count = count_nodes(tree)
        IO.puts("Total nodes: #{node_count}\n")

        # Print tree
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
    trace = opts[:trace] || false

    # Default paths
    index_path = "data/3M_2022_10K_fine_index.json"
    pdf_path = "data/3M_2022_10K.pdf"

    mode =
      cond do
        planner -> "planner (MetaPlanner with verification)"
        simple -> "simple (score all nodes)"
        true -> "agent (single-pass)"
      end

    IO.puts("Query: #{query}")
    IO.puts("Model: #{model}")
    IO.puts("Mode: #{mode}")
    if trace, do: IO.puts("Tracing: enabled")
    IO.puts("")

    llm = LLMClient.callback(model)

    case PageIndex.FineIndexer.load(index_path) do
      {:ok, tree} ->
        cond do
          planner ->
            run_planner_query(tree, query, llm, pdf_path, trace: trace)

          simple ->
            run_simple_query(tree, query, llm, pdf_path, trace: trace)

          true ->
            run_agent_query(tree, query, llm, pdf_path, trace: trace)
        end

      {:error, reason} ->
        IO.puts("Error loading index: #{inspect(reason)}")
        IO.puts("Run --fine first to create the index.")
    end
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

  defp run_planner_query(tree, query, llm, pdf_path, opts) do
    retriever_opts = [llm: llm, pdf_path: pdf_path]

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
  defp inspect_answer(answer) when is_map(answer), do: answer["answer"] || inspect(answer)
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
