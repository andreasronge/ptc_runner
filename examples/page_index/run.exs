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
          plan_only: :boolean,
          plan: :string,
          help: :boolean
        ],
        aliases: [
          h: :help,
          m: :model,
          q: :query,
          t: :trace,
          c: :cache,
          p: :plan_only
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
      -p, --plan-only       Show generated plan without executing (saves to plans/)
      --plan <path>         Execute a saved plan (skip plan generation)
      -h, --help            Show this help

    Examples:
      mix run run.exs --index data/3M_2022_10K.pdf
      mix run run.exs --query "What was 3M's total revenue in 2022?" --pdf data/3M_2022_10K.pdf
      mix run run.exs --query "Is 3M capital intensive?" --pdf data/3M_2022_10K.pdf --cache
      mix run run.exs --query "Is 3M capital intensive?" --pdf data/3M_2022_10K.pdf -p -m bedrock:sonnet
      mix run run.exs --query "Is 3M capital intensive?" --pdf data/3M_2022_10K.pdf --plan plans/plan_123.json
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
    plan_only = opts[:plan_only] || false
    plan_path = opts[:plan]

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
    if plan_only, do: IO.puts("Plan only: yes")
    if plan_path, do: IO.puts("Plan: #{plan_path}")
    IO.puts("")

    TokenTracker.start()

    llm_opts = if cache, do: [cache: true], else: []
    llm = LLMClient.callback(model, llm_opts)

    case PageIndex.load_index(index_path) do
      {:ok, tree} ->
        cond do
          plan_only ->
            generate_plan_only(tree, query, llm)

          plan_path ->
            run_saved_plan(tree, query, llm, pdf_path, plan_path, trace: trace)

          true ->
            run_query(tree, query, llm, pdf_path, trace: trace)
        end

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

  defp generate_plan_only(tree, query, llm) do
    doc_title = tree.title || "Document"

    mission = """
    Answer this question about "#{doc_title}":

    QUESTION: #{query}

    Use the search tool to find relevant data from the document.
    """

    available_tools = %{
      "search" => """
      Search the document for specific data. Returns structured findings.
      Signature: (query :string) -> {findings [{label :string, value :any, unit :string, page :any, section :string, context :string}], sections_searched [:string]}

      Call with a specific data need, e.g.: (tool/search {:query "total revenue for 2022"})
      Use multiple search calls for different data points rather than one broad query.
      """
    }

    constraints = "The final synthesis task MUST have the id \"final_answer\"."

    IO.puts("Generating plan...")

    case PtcRunner.MetaPlanner.plan(mission,
           llm: llm,
           available_tools: available_tools,
           constraints: constraints
         ) do
      {:ok, plan} ->
        IO.puts("\n" <> String.duplicate("=", 60))
        IO.puts("GENERATED PLAN (#{length(plan.tasks)} tasks, #{map_size(plan.agents)} agents)")
        IO.puts(String.duplicate("=", 60))

        IO.puts("\nAgents:")

        for {name, spec} <- plan.agents do
          tools = if spec.tools == [], do: "(no tools)", else: Enum.join(spec.tools, ", ")
          IO.puts("  #{name}: #{tools}")
          IO.puts("    prompt: #{String.slice(spec.prompt, 0, 100)}...")
        end

        IO.puts("\nTasks:")

        for task <- plan.tasks do
          deps = if task.depends_on == [], do: "", else: " <- #{Enum.join(task.depends_on, ", ")}"
          gate = if task.quality_gate, do: " [GATE]", else: ""
          type = if task.type && task.type != "", do: " (#{task.type})", else: ""
          sig = if task.signature && task.signature != "", do: " -> #{task.signature}", else: ""

          IO.puts("\n  #{task.id}#{type}#{gate}#{deps}")
          IO.puts("    agent: #{task.agent}")
          IO.puts("    input: #{String.slice(task.input, 0, 200)}")
          if sig != "", do: IO.puts("    signature: #{sig}")

          if task.verification && task.verification != "" do
            IO.puts("    verification: #{task.verification}")
          end
        end

        IO.puts("\n" <> String.duplicate("=", 60))

        raw = plan_to_raw_json(plan)
        json = Jason.encode!(raw, pretty: true)

        # Save to plans/ directory
        File.mkdir_p!("plans")
        plan_file = "plans/plan_#{System.system_time(:second)}.json"
        File.write!(plan_file, json)
        IO.puts("\nPlan saved to: #{plan_file}")

        IO.puts("\nRaw JSON:")
        IO.puts(json)

      {:error, reason} ->
        IO.puts("Error generating plan: #{inspect(reason)}")
    end
  end

  defp plan_to_raw_json(plan) do
    %{
      "agents" =>
        Map.new(plan.agents, fn {name, spec} ->
          {name, %{"prompt" => spec.prompt, "tools" => spec.tools}}
        end),
      "tasks" =>
        Enum.map(plan.tasks, fn task ->
          base = %{
            "id" => task.id,
            "agent" => task.agent,
            "input" => task.input,
            "depends_on" => task.depends_on
          }

          optional = [
            {"quality_gate", task.quality_gate, &(&1 == true)},
            {"type", task.type, &(&1 && &1 != "")},
            {"signature", task.signature, &(&1 && &1 != "")},
            {"verification", task.verification, &(&1 && &1 != "")},
            {"output", to_string_or_nil(task.output), &(&1 && &1 != "")},
            {"on_verification_failure", atom_to_string(task.on_verification_failure),
             &(&1 && &1 != "stop")},
            {"on_failure", atom_to_string(task.on_failure), &(&1 && &1 != "stop")},
            {"max_retries", task.max_retries, &(&1 && &1 > 1)}
          ]

          Enum.reduce(optional, base, fn {key, value, include?}, acc ->
            if include?.(value), do: Map.put(acc, key, value), else: acc
          end)
        end)
    }
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp to_string_or_nil(val), do: val

  defp atom_to_string(nil), do: nil
  defp atom_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp atom_to_string(val), do: val

  defp run_saved_plan(tree, query, llm, pdf_path, plan_path, opts) do
    case File.read(plan_path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, raw_plan} ->
            case PtcRunner.Plan.parse(raw_plan) do
              {:ok, plan} ->
                IO.puts(
                  "Loaded plan: #{length(plan.tasks)} tasks, #{map_size(plan.agents)} agents"
                )

                execute_plan(tree, query, plan, llm, pdf_path, opts)

              {:error, reason} ->
                IO.puts("Error parsing plan: #{inspect(reason)}")
            end

          {:error, reason} ->
            IO.puts("Error decoding JSON: #{inspect(reason)}")
        end

      {:error, reason} ->
        IO.puts("Error reading #{plan_path}: #{inspect(reason)}")
    end
  end

  defp execute_plan(tree, query, plan, llm, pdf_path, opts) do
    nodes = PageIndex.RetrieverToolkit.flatten_tree(tree)

    # Pre-warm the PDF cache
    IO.puts("Pre-loading PDF pages...")
    {:ok, _} = PageIndex.get_content(pdf_path, 1, 1)
    IO.puts("PDF cache ready.")

    doc_title = tree.title || "Document"

    mission = """
    Answer this question about "#{doc_title}":

    QUESTION: #{query}

    Use the search tool to find relevant data from the document.
    """

    base_tools = %{
      "search" => PageIndex.RetrieverToolkit.make_search_tool(nodes, pdf_path, [])
    }

    executor_opts = [
      llm: llm,
      base_tools: base_tools,
      max_total_replans: 2,
      max_turns: 20,
      timeout: 60_000,
      quality_gate: true
    ]

    result =
      with_optional_trace(opts[:trace], query, fn ->
        case PtcRunner.PlanExecutor.execute(plan, mission, executor_opts) do
          {:ok, metadata} ->
            results = metadata.results
            final_result = PageIndex.RetrieverToolkit.find_synthesis_result(results)

            {:ok,
             %{
               answer:
                 final_result["answer"] || final_result["assessment"] ||
                   final_result["analysis"] || final_result,
               sources: PageIndex.RetrieverToolkit.extract_search_sources(results),
               replans: metadata.replan_count,
               tasks_executed: map_size(results)
             }}

          {:error, reason, metadata} ->
            {:error, %{reason: reason, replans: metadata.replan_count, partial_results: metadata}}
        end
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
