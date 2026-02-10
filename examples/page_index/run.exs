#!/usr/bin/env elixir

# PageIndex - Hierarchical Document Retrieval
#
# Usage:
#   mix run run.exs --index data/3M_2022_10K.pdf    # Create index
#   mix run run.exs --show data/3M_2022_10K_index.json  # Show existing index

# Start PdfExtractor GenServer (requires Python with pdfplumber)
{:ok, _} = Application.ensure_all_started(:pdf_extractor)
{:ok, _} = PdfExtractor.start_link([])

defmodule TokenTracker do
  @moduledoc false
  # Tracks token usage across all LLM calls via telemetry.

  def start do
    if :ets.whereis(__MODULE__) == :undefined do
      :ets.new(__MODULE__, [:named_table, :public, :set])
    end

    :ets.insert(__MODULE__, {:totals, 0, 0, 0, 0, 0})

    :telemetry.attach(
      "token-tracker",
      [:ptc_runner, :sub_agent, :llm, :stop],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event(_event, measurements, _meta, _config) do
    input = Map.get(measurements, :input_tokens, 0)
    output = Map.get(measurements, :output_tokens, 0)
    cache_creation = Map.get(measurements, :cache_creation_tokens, 0)
    cache_read = Map.get(measurements, :cache_read_tokens, 0)

    :ets.update_counter(__MODULE__, :totals, [
      {2, input},
      {3, output},
      {4, cache_creation},
      {5, cache_read},
      {6, 1}
    ])
  end

  def summary do
    [{:totals, input, output, cache_creation, cache_read, calls}] =
      :ets.lookup(__MODULE__, :totals)

    %{
      llm_calls: calls,
      input_tokens: input,
      output_tokens: output,
      cache_creation_tokens: cache_creation,
      cache_read_tokens: cache_read,
      total_tokens: input + output
    }
  end

  def print_summary do
    stats = summary()
    IO.puts("\nToken usage (#{stats.llm_calls} LLM calls):")
    IO.puts("  Input:  #{stats.input_tokens}")
    IO.puts("  Output: #{stats.output_tokens}")

    if stats.cache_creation_tokens > 0 or stats.cache_read_tokens > 0 do
      IO.puts("  Cache write: #{stats.cache_creation_tokens}")
      IO.puts("  Cache read:  #{stats.cache_read_tokens}")

      if stats.input_tokens > 0 do
        cache_pct = Float.round(stats.cache_read_tokens / stats.input_tokens * 100, 1)
        IO.puts("  Cache hit:   #{cache_pct}% of input tokens")
      end
    end
  end
end

defmodule CLI do
  def main(args) do
    {opts, _rest, _} =
      OptionParser.parse(args,
        switches: [
          index: :string,
          show: :string,
          query: :string,
          pdf: :string,
          trace: :boolean,
          model: :string,
          cache: :boolean,
          help: :boolean
        ],
        aliases: [
          h: :help,
          m: :model,
          q: :query,
          t: :trace,
          c: :cache
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
      -c, --cache           Enable prompt caching (reduces cost on repeated queries)
      -t, --trace           Enable tracing (writes to traces/ directory)
      -h, --help            Show this help

    Examples:
      mix run run.exs --index data/3M_2022_10K.pdf
      mix run run.exs --query "What was 3M's total revenue in 2022?" --pdf data/3M_2022_10K.pdf
      mix run run.exs --query "Is 3M capital intensive?" --pdf data/3M_2022_10K.pdf --cache
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
    trace = opts[:trace] || false
    cache = opts[:cache] || false

    pdf_path = opts[:pdf]

    unless pdf_path do
      IO.puts("Error: --pdf <path> is required with --query")
      System.halt(1)
    end

    index_path = index_path_for(pdf_path)

    IO.puts("Query: #{query}")
    IO.puts("Model: #{model}")
    IO.puts("Index: #{index_path}")
    if cache, do: IO.puts("Cache: enabled")
    if trace, do: IO.puts("Tracing: enabled")
    IO.puts("")

    TokenTracker.start()

    llm_opts = if cache, do: [cache: true], else: []
    llm = LLMClient.callback(model, llm_opts)

    case PageIndex.load_index(index_path) do
      {:ok, tree} ->
        run_query(tree, query, llm, pdf_path, trace: trace)
        TokenTracker.print_summary()

      {:error, reason} ->
        IO.puts("Error loading index: #{inspect(reason)}")
        IO.puts("Run --index #{pdf_path} first to create the index.")
    end
  end

  defp index_path_for(pdf_path) do
    String.replace(pdf_path, ~r/\.pdf$/i, "_index.json")
  end

  defp with_optional_trace(trace?, query, func) do
    if trace? do
      File.mkdir_p!("traces")
      trace_file = "traces/minimal_#{System.system_time(:second)}.jsonl"

      {:ok, result, path} =
        PtcRunner.TraceLog.with_trace(func,
          path: trace_file,
          meta: %{query: query, mode: "minimal"}
        )

      IO.puts("\nTrace written to: #{path}")
      IO.puts("View with: open priv/trace_viewer.html (then drop the .jsonl file)")
      result
    else
      func.()
    end
  end

  defp run_query(tree, query, llm, pdf_path, opts) do
    retriever_opts = [llm: llm, pdf_path: pdf_path, quality_gate: true]

    result =
      with_optional_trace(opts[:trace], query, fn ->
        PageIndex.PlanRetriever.retrieve(tree, query, retriever_opts)
      end)

    case result do
      {:ok, result} ->
        IO.puts("\n" <> String.duplicate("=", 60))
        IO.puts("ANSWER (after #{result.replans} replans, #{result.tasks_executed} tasks):")
        IO.puts(String.duplicate("=", 60))
        IO.puts(inspect_answer(result.answer))

        IO.puts("\nSources:")

        for source <- result.sources || [] do
          section = inspect_field(source.section)
          page = inspect_field(source.page)
          IO.puts("  - #{section} (page #{page})")
        end

      {:error, result} ->
        IO.puts("Error: #{inspect(result.reason)}")
        IO.puts("Replans attempted: #{result.replans}")
    end
  end

  defp inspect_answer(answer) when is_binary(answer), do: answer

  defp inspect_answer(answer) when is_map(answer) do
    answer["answer"] || answer["reasoning"] || inspect(answer)
  end

  defp inspect_answer(answer), do: inspect(answer)

  defp inspect_field(value) when is_binary(value), do: value
  defp inspect_field(value) when is_number(value), do: to_string(value)
  defp inspect_field(value), do: inspect(value)

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
