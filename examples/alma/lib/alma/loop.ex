defmodule Alma.Loop do
  @moduledoc """
  Runs a single ALMA iteration: sample parents, generate a design,
  evaluate on collection and deployment tasks, and archive.

  The SubAgent handles its own validation — if it produces broken code,
  the SubAgent catches it during execution. No external debug/fix loop needed.
  """

  alias Alma.{Analysis, Archive, DebugAgent, MetaAgent, MemoryHarness}
  alias Alma.Environments.GraphWorld

  require Logger

  @doc """
  Runs one iteration of the ALMA loop.

  Returns the updated archive.
  """
  def iteration(archive, generation, env_config, episodes, opts \\ []) do
    verbose = Keyword.get(opts, :verbose, false)
    env_module = Keyword.get(opts, :environment, GraphWorld)

    opts =
      if function_exported?(env_module, :context_schema, 0) do
        Keyword.put_new(opts, :context_schema, env_module.context_schema())
      else
        opts
      end

    opts =
      Keyword.put_new_lazy(opts, :observe_fn, fn ->
        fn task_config ->
          state = env_module.reset(task_config)
          observation = env_module.observe(state)

          real_goal = env_module.format_goal(state[:goal] || task_config.goal)
          {observation, real_goal}
        end
      end)

    # 1. Sample parents
    {parents, archive} = Archive.sample(archive, 2)
    parent_ids = Enum.map(parents, & &1.id)

    :telemetry.execute(
      [:alma, :iteration, :start],
      %{},
      %{generation: generation, parent_ids: parent_ids}
    )

    start_time = System.monotonic_time(:millisecond)

    # Harness needs :observe_fn but not :context_schema
    # MetaAgent needs :context_schema but not :observe_fn
    # MetaAgent/DebugAgent use :meta_llm (falls back to :llm)
    harness_opts = Keyword.drop(opts, [:context_schema, :meta_llm])

    meta_llm = Keyword.get(opts, :meta_llm) || Keyword.get(opts, :llm)

    meta_opts =
      opts
      |> Keyword.drop([:observe_fn, :meta_llm])
      |> Keyword.put(:llm, meta_llm)

    # 2. DebugAgent analyzes parent runtime logs, then MetaAgent generates
    if verbose, do: IO.write("Gen #{generation}: analyzing...")

    Alma.Trace.span(
      "alma:iteration",
      %{"generation" => generation, "parent_ids" => parent_ids},
      fn ->
        meta_opts =
          Alma.Trace.span(
            "alma:debug_agent",
            %{"generation" => generation, "parent_count" => length(parents)},
            fn ->
              case DebugAgent.analyze(parents, meta_opts) do
                {:ok, critique, child_trace_id} ->
                  result =
                    if critique != "",
                      do: Keyword.put(meta_opts, :analyst_critique, critique),
                      else: meta_opts

                  if child_trace_id do
                    {:__trace_meta__, result, %{child_trace_id: child_trace_id}}
                  else
                    result
                  end

                {:error, _reason} ->
                  meta_opts
              end
            end
          )

        max_attempts = Keyword.get(opts, :examine_retries, 2) + 1

        if verbose, do: IO.write(" designing...")

        case generate_with_examine(
               parents,
               meta_opts,
               env_config,
               harness_opts,
               max_attempts
             ) do
          {:ok, design} ->
            if verbose, do: IO.write(" evaluating...")

            run_evaluation(
              archive,
              design,
              generation,
              env_config,
              episodes,
              harness_opts,
              verbose,
              start_time: start_time,
              parent_ids: parent_ids,
              env_module: env_module
            )

          {:error, reason} ->
            if verbose, do: IO.puts(" failed")

            Logger.warning(
              "ALMA: generation failed for generation #{generation}: #{inspect(reason)}"
            )

            archive
        end
      end
    )
  end

  # Generate a design and examine it. Retries up to max_attempts if recall
  # output is empty or trivial (< 20 chars after 2 collection episodes).
  defp generate_with_examine(parents, meta_opts, env_config, harness_opts, max_attempts) do
    Enum.reduce_while(1..max_attempts, {:error, "no attempts"}, fn attempt, _acc ->
      Alma.Trace.span(
        "alma:generate_attempt",
        %{"attempt" => attempt, "max_attempts" => max_attempts},
        fn ->
          case MetaAgent.generate(parents, meta_opts) do
            {:ok, design} ->
              case examine(design, env_config, harness_opts, attempt) do
                :ok ->
                  {:halt, {:ok, design}}

                {:retry, reason} when attempt < max_attempts ->
                  Logger.info(
                    "ALMA: examine failed (attempt #{attempt}/#{max_attempts}): #{reason}"
                  )

                  {:cont, {:error, reason}}

                {:retry, reason} ->
                  Logger.warning(
                    "ALMA: examine failed on final attempt, proceeding anyway: #{reason}"
                  )

                  {:halt, {:ok, design}}
              end

            {:error, reason} ->
              if attempt < max_attempts do
                {:cont, {:error, reason}}
              else
                {:halt, {:error, reason}}
              end
          end
        end
      )
    end)
  end

  # Runs a quick smoke test: 2 collection episodes to build memory, then
  # 1 recall to check if the design produces useful advice text.
  defp examine(design, env_config, opts, attempt) do
    env_module = Keyword.get(opts, :environment, GraphWorld)

    Alma.Trace.span(
      "alma:examine",
      %{"design" => design.name, "attempt" => attempt},
      fn ->
        # Generate 2 collection tasks with a distinct seed range
        examine_env = Map.put(env_config, :seed, Map.get(env_config, :seed, 42) + 5000)
        collection_tasks = env_module.generate_tasks(2, examine_env)

        # Run collection to build memory
        {_results, memory, errors} =
          MemoryHarness.evaluate_collection(design, collection_tasks, opts)

        if errors != [] do
          {:retry, "mem-update errors: #{Enum.join(errors, "; ")}"}
        else
          # Generate a recall task and check advice quality
          recall_env = Map.put(env_config, :seed, Map.get(env_config, :seed, 42) + 6000)
          [recall_task] = env_module.generate_tasks(1, recall_env)

          # Replace placeholder goal with real goal from environment
          observe_fn = Keyword.get(opts, :observe_fn)

          {retrieve_opts, recall_task} =
            if observe_fn do
              case observe_fn.(recall_task) do
                {obs, real_goal} when is_binary(real_goal) ->
                  updated = Map.put(recall_task, :goal, real_goal)
                  {Keyword.put(opts, :current_observation, obs), updated}

                obs when is_binary(obs) ->
                  {Keyword.put(opts, :current_observation, obs), recall_task}
              end
            else
              {opts, recall_task}
            end

          {advice, recall_error, _log} =
            MemoryHarness.retrieve(design, recall_task, memory, retrieve_opts)

          cond do
            recall_error != nil ->
              {:retry, "recall error: #{recall_error}"}

            not is_binary(advice) ->
              {:retry,
               "recall must return a string, got a #{type_name(advice)}. Use (str ...) to build the advice string."}

            String.length(advice) < 20 ->
              {:retry,
               "recall returned trivial advice (#{String.length(advice)} chars): \"#{advice}\". Include specific details from stored knowledge."}

            true ->
              :ok
          end
        end
      end
    )
  end

  defp run_evaluation(archive, design, generation, env_config, episodes, opts, verbose,
         start_time: start_time,
         parent_ids: parent_ids,
         env_module: env_module
       ) do
    # 3. Collection phase — use family batch if family is set
    collection_tasks =
      if Map.get(env_config, :family) do
        env_module.generate_family_tasks(episodes, env_config)
      else
        env_module.generate_tasks(episodes, env_config)
      end

    # Carry forward memory from prior generation if persist_memory is enabled
    collection_opts =
      if Keyword.get(opts, :persist_memory, false) do
        prior_memory = Archive.latest_memory(archive)
        Keyword.put(opts, :initial_memory, prior_memory)
      else
        opts
      end

    {collection_results, final_memory, collection_errors} =
      Alma.Trace.span(
        "alma:collection",
        %{"design" => design.name, "episodes" => episodes},
        fn ->
          MemoryHarness.evaluate_collection(design, collection_tasks, collection_opts)
        end
      )

    # 4. Deployment phase — multiple seed offsets for robust scoring
    deploy_seeds = Keyword.get(opts, :deploy_seeds, 3)

    {deployment_results, deployment_errors} =
      Alma.Trace.span(
        "alma:deployment",
        %{"design" => design.name, "seeds" => deploy_seeds, "episodes_per_seed" => episodes},
        fn ->
          1..deploy_seeds
          |> Enum.map(fn seed_idx ->
            seed_offset = 1000 * seed_idx
            deployment_env = Map.update!(env_config, :seed, &(&1 + seed_offset))
            deployment_tasks = env_module.generate_tasks(episodes, deployment_env)

            Alma.Trace.span(
              "alma:deploy_seed",
              %{"seed_idx" => seed_idx, "seed_offset" => seed_offset},
              fn ->
                MemoryHarness.evaluate_deployment(design, final_memory, deployment_tasks, opts)
              end
            )
          end)
          |> Enum.reduce({[], []}, fn {results, errors}, {all_results, all_errors} ->
            {all_results ++ results, all_errors ++ errors}
          end)
        end
      )

    deployment_tasks =
      1..deploy_seeds
      |> Enum.flat_map(fn seed_idx ->
        seed_offset = 1000 * seed_idx
        deployment_env = Map.update!(env_config, :seed, &(&1 + seed_offset))
        env_module.generate_tasks(episodes, deployment_env)
      end)

    # 5. Analyze, score, and archive
    collection_score = score_results(collection_results)
    deployment_score = score_results(deployment_results)
    baseline_score = Keyword.get(opts, :baseline_score, 0.0)
    normalized_score = deployment_score - baseline_score
    all_errors = Enum.uniq(collection_errors ++ deployment_errors)

    analysis = Analysis.analyze_results(deployment_results, deployment_tasks, env_module)
    compressed = Analysis.compress_trajectories(deployment_results, deployment_tasks, env_module)

    entry = %{
      design: design,
      score: normalized_score,
      trajectories: deployment_results,
      collection_trajectories: collection_results,
      parent_ids: parent_ids,
      generation: generation,
      errors: all_errors,
      analysis: analysis,
      compressed_trajectories: compressed,
      final_memory: final_memory
    }

    archive = Archive.add(archive, entry)
    duration_ms = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:alma, :iteration, :stop],
      %{
        duration: duration_ms,
        collection_score: collection_score,
        deployment_score: deployment_score,
        normalized_score: normalized_score,
        baseline_score: baseline_score
      },
      %{
        generation: generation,
        design_name: design.name,
        archive_size: length(archive.entries)
      }
    )

    Alma.Trace.span(
      "alma:scores",
      %{
        "generation" => generation,
        "design_name" => design.name,
        "collection_score" => collection_score,
        "deployment_score" => deployment_score,
        "normalized_score" => normalized_score,
        "baseline_score" => baseline_score,
        "archive_size" => length(archive.entries),
        "mem_update_source" => design.mem_update_source,
        "recall_source" => design.recall_source
      },
      fn ->
        %{
          "collection" => collection_score,
          "deployment" => deployment_score,
          "normalized" => normalized_score
        }
      end
    )

    if verbose do
      IO.puts(" done")

      print_iteration_summary(
        generation,
        design,
        collection_score,
        deployment_score,
        normalized_score,
        baseline_score,
        archive
      )
    end

    archive
  end

  @doc """
  Scores a list of task results by averaging per-episode scores.

  Each successful episode scores between 0.5 and 1.0 based on step efficiency.
  Failed episodes score 0.0.
  """
  def score_results(results) do
    if results == [] do
      0.0
    else
      results
      |> Enum.map(fn r ->
        if r.success? do
          # Reward efficiency: fewer steps = higher score
          # max_steps is 20, so normalize inversely
          max(0.5, 1.0 - r.steps / 40.0)
        else
          0.0
        end
      end)
      |> then(&(Enum.sum(&1) / length(&1)))
    end
  end

  defp print_iteration_summary(
         generation,
         design,
         collection_score,
         deployment_score,
         normalized_score,
         baseline_score,
         archive
       ) do
    IO.puts("--- Generation #{generation} ---")
    IO.puts("  Design: #{design.name}")
    IO.puts("  Collection score: #{Float.round(collection_score * 1.0, 2)}")

    IO.puts(
      "  Deployment score: #{Float.round(deployment_score * 1.0, 2)}" <>
        " (normalized: #{Float.round(normalized_score * 1.0, 2)}, baseline: #{Float.round(baseline_score * 1.0, 2)})"
    )

    IO.puts("  #{Archive.summary(archive)}")
  end

  defp type_name(value) when is_map(value), do: "map"
  defp type_name(value) when is_list(value), do: "list"
  defp type_name(value) when is_number(value), do: "number"
  defp type_name(value) when is_nil(value), do: "nil"
  defp type_name(_value), do: "non-string value"
end
