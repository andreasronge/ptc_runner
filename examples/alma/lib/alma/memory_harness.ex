defmodule Alma.MemoryHarness do
  @moduledoc """
  Bridges memory designs to PTC-Lisp evaluation and task agent execution.

  A memory design contains live closures (`mem_update` and `recall`) that are
  called directly via `Lisp.run`, eliminating string eval entirely.

  Tools (`store-obs`, `find-similar`, `summarize`, `analyze`, `graph-update`,
  `graph-neighbors`, `graph-path`) are injected into the Lisp runtime for both
  `mem-update` and `recall` closures.
  """

  alias PtcRunner.Lisp
  alias Alma.VectorStore
  alias Alma.GraphStore

  @vector_store_key :__vector_store
  @graph_store_key :__graph_store

  @doc """
  Returns a no-op baseline design with no memory.
  """
  def null_design do
    %{
      name: "null",
      description: "No-op baseline with no memory",
      mem_update: nil,
      recall: nil,
      mem_update_source: "",
      recall_source: "",
      namespace: %{}
    }
  end

  @doc """
  Calls the design's `recall` closure with the given task info and memory.

  Accepts optional `:store_agents` tuple `{vs_agent, gs_agent}` to reuse
  shared store processes (e.g., during deployment with frozen memory).

  Returns `{advice_string, error | nil, runtime_log}`.
  """
  def retrieve(design, task_info, memory, opts \\ []) do
    design_name = Map.get(design, :name, "unknown")
    current_observation = Keyword.get(opts, :current_observation)

    Alma.Trace.span(
      "memory:retrieve",
      %{"design" => design_name},
      fn ->
        case design.recall do
          nil ->
            {"", nil, empty_log(:recall)}

          closure ->
            namespace = Map.get(design, :namespace, %{})

            run_memory =
              namespace
              |> Map.merge(strip_stores(memory))
              |> Map.put(:recall, closure)

            context =
              %{"task" => task_info}
              |> then(fn ctx ->
                if current_observation,
                  do: Map.put(ctx, "current_observation", current_observation),
                  else: ctx
              end)

            embed_mode = embed_mode(opts)

            case Keyword.get(opts, :store_agents) do
              {vs_agent, gs_agent} ->
                run_with_shared_agents(
                  "(recall)",
                  context,
                  run_memory,
                  vs_agent,
                  gs_agent,
                  opts
                )
                |> case do
                  {:ok, step, sim_stats} ->
                    {step.return || "", nil, extract_log(step, :recall, sim_stats, embed_mode)}

                  {:error, reason} ->
                    {"", "recall failed: #{format_error(reason)}", error_log(reason, :recall)}
                end

              nil ->
                run_with_tools("(recall)", context, run_memory, memory, opts)
                |> case do
                  {:ok, step, _updated_vs, _updated_gs, sim_stats} ->
                    {step.return || "", nil, extract_log(step, :recall, sim_stats, embed_mode)}

                  {:error, reason} ->
                    {"", "recall failed: #{format_error(reason)}", error_log(reason, :recall)}
                end
            end
        end
      end
    )
  end

  @doc """
  Calls the design's `mem_update` closure with episode data and memory.

  Returns `{updated_memory, error | nil, runtime_log}`.
  """
  def update(design, episode_data, memory, opts \\ []) do
    design_name = Map.get(design, :name, "unknown")

    context = %{
      "task" => episode_data.task,
      "actions" => episode_data.actions,
      "success" => episode_data.success,
      "observation_log" => episode_data.observation_log
    }

    Alma.Trace.span(
      "memory:update",
      %{"design" => design_name, "success" => episode_data.success},
      fn ->
        case design.mem_update do
          nil ->
            {memory, nil, empty_log(:"mem-update")}

          closure ->
            namespace = Map.get(design, :namespace, %{})

            run_memory =
              namespace
              |> Map.merge(strip_stores(memory))
              |> Map.put(:"mem-update", closure)

            embed_mode = embed_mode(opts)

            run_with_tools("(mem-update)", context, run_memory, memory, opts)
            |> case do
              {:ok, step, updated_vs, updated_gs, sim_stats} ->
                updated =
                  step.memory
                  |> Map.delete(:"mem-update")
                  |> Map.put(@vector_store_key, updated_vs)
                  |> Map.put(@graph_store_key, updated_gs)

                {updated, nil, extract_log(step, :"mem-update", sim_stats, embed_mode)}

              {:error, reason} ->
                {memory, "mem-update failed: #{format_error(reason)}",
                 error_log(reason, :"mem-update")}
            end
        end
      end
    )
  end

  @doc """
  Runs tasks sequentially during the collection phase, updating memory after each.

  Returns `{results, final_memory, errors}`.
  """
  def evaluate_collection(design, tasks, opts \\ []) do
    observe_fn = Keyword.get(opts, :observe_fn)
    on_task_done = Keyword.get(opts, :on_task_done)
    initial_memory = Keyword.get(opts, :initial_memory, %{})

    {rev_results, memory, rev_errors} =
      Enum.reduce(tasks, {[], initial_memory, []}, fn task_config, {results, memory, errors} ->
        retrieve_opts =
          if observe_fn,
            do: Keyword.put(opts, :current_observation, observe_fn.(task_config)),
            else: opts

        {knowledge, recall_error, recall_log} =
          retrieve(design, task_config, memory, retrieve_opts)

        knowledge = ensure_string(knowledge)
        result = Alma.TaskAgent.run(task_config, knowledge, opts)
        result = Map.put(result, :recall_advice, knowledge)

        episode_data = %{
          task: task_config,
          actions: result.actions,
          success: result.success?,
          observation_log: result.observation_log
        }

        {updated_memory, update_error, update_log} = update(design, episode_data, memory, opts)
        result = Map.put(result, :runtime_logs, [recall_log, update_log])
        if on_task_done, do: on_task_done.(result)

        new_errors =
          [update_error, recall_error]
          |> Enum.reject(&is_nil/1)

        {[result | results], updated_memory, new_errors ++ errors}
      end)

    {Enum.reverse(rev_results), memory, rev_errors |> Enum.reverse() |> Enum.uniq()}
  end

  @doc """
  Runs tasks with frozen memory during the deployment phase.

  Creates shared read-only store Agents once, reused by all concurrent tasks.
  This avoids copying the vector/graph stores into each task's sandbox process.

  Returns `{results, errors}`.
  """
  def evaluate_deployment(design, frozen_memory, tasks, opts \\ []) do
    observe_fn = Keyword.get(opts, :observe_fn)
    on_task_done = Keyword.get(opts, :on_task_done)

    # Create shared read-only Agents for the frozen stores
    vs = Map.get(frozen_memory, @vector_store_key, VectorStore.new())
    gs = Map.get(frozen_memory, @graph_store_key, GraphStore.new())
    {:ok, vs_agent} = Agent.start_link(fn -> vs end)
    {:ok, gs_agent} = Agent.start_link(fn -> gs end)

    try do
      {results, errors} =
        tasks
        |> Task.async_stream(
          fn task_config ->
            retrieve_opts =
              if observe_fn,
                do: Keyword.put(opts, :current_observation, observe_fn.(task_config)),
                else: opts

            retrieve_opts = Keyword.put(retrieve_opts, :store_agents, {vs_agent, gs_agent})

            {knowledge, recall_error, recall_log} =
              retrieve(design, task_config, frozen_memory, retrieve_opts)

            knowledge = ensure_string(knowledge)
            result = Alma.TaskAgent.run(task_config, knowledge, opts)
            result = Map.put(result, :recall_advice, knowledge)
            result = Map.put(result, :runtime_logs, [recall_log])
            {result, recall_error}
          end,
          max_concurrency: System.schedulers_online(),
          ordered: true,
          timeout: :infinity
        )
        |> Enum.reduce({[], []}, fn
          {:ok, {result, recall_error}}, {results, errors} ->
            if on_task_done, do: on_task_done.(result)
            errors = if recall_error, do: [recall_error | errors], else: errors
            {[result | results], errors}

          {:exit, reason}, {results, errors} ->
            result = %{
              success?: false,
              actions: [],
              steps: 0,
              observation_log: [],
              error: "task crashed: #{inspect(reason)}"
            }

            if on_task_done, do: on_task_done.(result)
            {[result | results], ["task crashed: #{inspect(reason)}" | errors]}
        end)

      {Enum.reverse(results), errors |> Enum.reverse() |> Enum.uniq()}
    after
      Agent.stop(vs_agent)
      Agent.stop(gs_agent)
    end
  end

  # Runs a Lisp expression with vector store and graph store tools injected.
  # Uses Agents to hold mutable state across tool calls within a single Lisp.run invocation.
  # Returns {:ok, step, updated_vector_store, updated_graph_store, sim_stats} | {:error, reason}.
  defp run_with_tools(expr, context, run_memory, memory, opts) do
    vs = Map.get(memory, @vector_store_key, VectorStore.new())
    gs = Map.get(memory, @graph_store_key, GraphStore.new())
    {:ok, vs_agent} = Agent.start_link(fn -> vs end)
    {:ok, gs_agent} = Agent.start_link(fn -> gs end)
    {:ok, stats_agent} = Agent.start_link(fn -> [] end)

    try do
      tools = build_tools(vs_agent, gs_agent, stats_agent, opts)

      case Lisp.run(expr,
             context: context,
             memory: run_memory,
             tools: tools,
             filter_context: false,
             max_heap: 6_250_000,
             max_tool_calls: 50
           ) do
        {:ok, step} ->
          updated_vs = Agent.get(vs_agent, & &1)
          updated_gs = Agent.get(gs_agent, & &1)
          sim_stats = Agent.get(stats_agent, & &1) |> Enum.reverse()
          {:ok, step, updated_vs, updated_gs, sim_stats}

        {:error, reason} ->
          {:error, reason}
      end
    after
      Agent.stop(vs_agent)
      Agent.stop(gs_agent)
      Agent.stop(stats_agent)
    end
  end

  # Runs a Lisp expression using shared (pre-existing) store Agents.
  # Used during deployment where stores are frozen and shared across tasks.
  # Returns {:ok, step, sim_stats} | {:error, reason}.
  defp run_with_shared_agents(expr, context, run_memory, vs_agent, gs_agent, opts) do
    {:ok, stats_agent} = Agent.start_link(fn -> [] end)

    try do
      tools = build_read_only_tools(vs_agent, gs_agent, stats_agent, opts)

      case Lisp.run(expr,
             context: context,
             memory: run_memory,
             tools: tools,
             filter_context: false,
             max_heap: 6_250_000,
             max_tool_calls: 50
           ) do
        {:ok, step} ->
          sim_stats = Agent.get(stats_agent, & &1) |> Enum.reverse()
          {:ok, step, sim_stats}

        {:error, reason} ->
          {:error, reason}
      end
    after
      Agent.stop(stats_agent)
    end
  end

  # Builds the tools map for Lisp.run. Tool closures read/write the vector store
  # and graph store through Agents for mutable state during a single execution.
  defp build_tools(vs_agent, gs_agent, stats_agent, opts) do
    embed_fn = build_embed_fn(opts)
    read_only = build_read_only_tools(vs_agent, gs_agent, stats_agent, opts, embed_fn)

    Map.merge(read_only, %{
      "store-obs" =>
        {fn args ->
           text = Map.fetch!(args, "text")
           metadata = Map.get(args, "metadata", %{})
           collection = Map.get(args, "collection", "default")

           {embed_us, vector} = :timer.tc(fn -> embed_fn.(text) end)

           Agent.update(stats_agent, fn stats ->
             [%{op: :store, embed_ms: div(embed_us, 1000)} | stats]
           end)

           Agent.get_and_update(vs_agent, fn vs ->
             {id, updated} = VectorStore.store(vs, text, vector, metadata, collection)
             {"stored:#{id}", updated}
           end)
         end, "(text :string, metadata :map, collection :string) -> :string"},
      "graph-update" =>
        {fn args ->
           edges = Map.fetch!(args, "edges")

           Agent.update(gs_agent, fn gs ->
             GraphStore.add_edges(gs, edges)
           end)

           "ok"
         end, "(edges [[:string]]) -> :string"}
    })
  end

  # Returns a function that embeds text using either a real embedding model or n-gram fallback.
  defp build_embed_fn(opts) do
    case Keyword.get(opts, :embed_model) do
      nil -> &VectorStore.embed/1
      model -> fn text -> LLMClient.embed!(model, text) end
    end
  end

  defp embed_mode(opts) do
    case Keyword.get(opts, :embed_model) do
      nil -> :ngram
      _model -> :dense
    end
  end

  # Builds read-only tools for shared store access during deployment.
  # No store-obs or graph-update — stores are frozen.
  defp build_read_only_tools(vs_agent, gs_agent, stats_agent, opts, embed_fn \\ nil) do
    embed_fn = embed_fn || build_embed_fn(opts)
    llm = Keyword.get(opts, :llm)

    # Execute queries inside the Agent callback so only the small result
    # (not the entire store) is copied across process boundaries.
    tools = %{
      "find-similar" =>
        {fn args ->
           query = Map.fetch!(args, "query")
           k = Map.get(args, "k", 3)
           collection = Map.get(args, "collection")
           contains = Map.get(args, "contains")

           {embed_us, query_vector} = :timer.tc(fn -> embed_fn.(query) end)

           results =
             Agent.get(vs_agent, fn vs ->
               VectorStore.find_similar(vs, query_vector, k, collection, contains)
             end)

           scores = Enum.map(results, & &1["score"])

           Agent.update(stats_agent, fn stats ->
             [
               %{
                 op: :find,
                 query: String.slice(query, 0, 80),
                 scores: scores,
                 embed_ms: div(embed_us, 1000)
               }
               | stats
             ]
           end)

           results
         end, "(query :string, k :int, collection :string, contains :string) -> [:map]"},
      "graph-neighbors" =>
        {fn args ->
           node = Map.fetch!(args, "node")
           Agent.get(gs_agent, fn gs -> GraphStore.neighbors(gs, node) end)
         end, "(node :string) -> [:string]"},
      "graph-path" =>
        {fn args ->
           from = Map.fetch!(args, "from")
           to = Map.fetch!(args, "to")
           Agent.get(gs_agent, fn gs -> GraphStore.shortest_path(gs, from, to) end)
         end, "(from :string, to :string) -> [:string]"}
    }

    if llm do
      tools
      |> Map.put("summarize", {
        fn args ->
          text = Map.fetch!(args, "text")
          instruction = Map.fetch!(args, "instruction")
          run_summarize(llm, text, instruction)
        end,
        "(text :string, instruction :string) -> :string"
      })
      |> Map.put("analyze", {
        fn args ->
          text = Map.fetch!(args, "text")
          instruction = Map.fetch!(args, "instruction")
          format = Map.get(args, "format", "text")
          run_analyze(llm, text, instruction, format)
        end,
        "(text :string, instruction :string, format :string) -> :any"
      })
    else
      tools
    end
  end

  defp run_summarize(llm, text, instruction) do
    request = %{
      system: "You are a concise text summarizer. Follow the instruction exactly.",
      messages: [%{role: :user, content: "#{instruction}\n\nText:\n#{text}"}]
    }

    case llm.(request) do
      {:ok, %{content: content}} when is_binary(content) -> content
      {:error, _reason} -> "summarization failed"
      _ -> "summarization failed"
    end
  end

  defp run_analyze(llm, text, instruction, format) do
    system =
      case format do
        "json" ->
          "You are an expert analyst. Follow the instruction exactly. Return ONLY valid JSON, no markdown fences."

        _ ->
          "You are an expert analyst. Follow the instruction exactly."
      end

    request = %{
      system: system,
      messages: [%{role: :user, content: "#{instruction}\n\nText:\n#{text}"}]
    }

    case llm.(request) do
      {:ok, %{content: content}} when is_binary(content) ->
        if format == "json" do
          case Jason.decode(content) do
            {:ok, parsed} -> parsed
            {:error, _} -> content
          end
        else
          content
        end

      {:error, _reason} ->
        "analysis failed"

      _ ->
        "analysis failed"
    end
  end

  # Strip vector/graph stores from memory before passing into the sandbox.
  # The stores are already held in Agents and accessed via tool closures,
  # so copying them into the sandbox process wastes heap.
  defp strip_stores(memory) do
    memory
    |> Map.delete(@vector_store_key)
    |> Map.delete(@graph_store_key)
  end

  defp ensure_string(value) when is_binary(value), do: value
  defp ensure_string(nil), do: ""
  defp ensure_string(value) when is_map(value), do: Jason.encode!(value)
  defp ensure_string(value) when is_list(value), do: Jason.encode!(value)
  defp ensure_string(value), do: to_string(value)

  defp extract_log(step, phase, similarity_stats \\ [], embed_mode \\ nil) do
    error =
      case step do
        %{fail: %{message: msg}} when is_binary(msg) -> msg
        _ -> nil
      end

    %{
      phase: phase,
      prints: step.prints || [],
      tool_calls:
        Enum.map(step.tool_calls || [], fn tc ->
          %{name: tc.name, args: tc.args, result: tc.result}
        end),
      return: step.return,
      error: error,
      similarity_stats: similarity_stats,
      embed_mode: embed_mode
    }
  end

  defp empty_log(phase),
    do: %{
      phase: phase,
      prints: [],
      tool_calls: [],
      return: nil,
      error: nil,
      similarity_stats: [],
      embed_mode: nil
    }

  # Extract partial log from a failed Step (preserves prints/tool_calls up to the crash)
  defp error_log(%PtcRunner.Step{} = step, phase), do: extract_log(step, phase)
  defp error_log(_reason, phase), do: empty_log(phase)

  defp format_error(%PtcRunner.Step{fail: %{message: message}}) when is_binary(message),
    do: message

  defp format_error(reason), do: inspect(reason)
end
