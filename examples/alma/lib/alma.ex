defmodule Alma do
  @moduledoc """
  ALMA — Autonomous Learning of Memory Algorithms.

  A meta-learning system that evolves memory designs for autonomous agents.
  Uses PTC-Lisp as the memory program language and an evolutionary archive
  to discover effective memory strategies.
  """

  alias Alma.{Archive, Loop, MemoryHarness}
  alias Alma.Environments.GraphWorld

  @doc """
  Runs the ALMA meta-learning loop.

  ## Options

    * `:llm` - LLM callback for task execution (required)
    * `:meta_llm` - LLM callback for meta agent and analyst (defaults to `:llm`)
    * `:iterations` - number of evolutionary iterations (default: 5)
    * `:episodes` - tasks per collection/deployment phase (default: 5)
    * `:rooms` - rooms per GraphWorld environment (default: 5)
    * `:seed` - random seed for reproducibility (default: 42)
    * `:family` - family seed for shared topology (default: same as `:seed`).
      Set to `nil` to disable family mode (legacy single-seed behavior).
    * `:verbose` - print progress (default: true)
    * `:trace` - write a JSONL trace file for ptc_viewer (default: false).
      Pass `true` for auto-named file in `traces/`, or a string path.

  Returns the final archive. When `:trace` is enabled, returns
  `{archive, trace_path}` instead.
  """
  def run(opts \\ []) do
    {trace, opts} = Keyword.pop(opts, :trace, false)

    if trace do
      trace_path = trace_path(trace)
      File.mkdir_p!(Path.dirname(trace_path))

      {:ok, archive, _path} =
        PtcRunner.TraceLog.with_trace(
          fn -> do_run(opts) end,
          path: trace_path,
          meta: %{
            iterations: Keyword.get(opts, :iterations, 5),
            episodes: Keyword.get(opts, :episodes, 5),
            rooms: Keyword.get(opts, :rooms, 5)
          }
        )

      {archive, trace_path}
    else
      do_run(opts)
    end
  end

  defp do_run(opts) do
    iterations = Keyword.get(opts, :iterations, 5)
    episodes = Keyword.get(opts, :episodes, 5)
    verbose = Keyword.get(opts, :verbose, true)

    preflight_check!(opts, verbose)

    env_module = Keyword.get(opts, :environment, GraphWorld)

    Code.ensure_loaded(env_module)

    env_config =
      if function_exported?(env_module, :setup, 1) do
        env_module.setup(opts)
      else
        %{seed: Keyword.get(opts, :seed, 42)}
      end

    observe_fn = fn task_config ->
      state = env_module.reset(task_config)
      observation = env_module.observe(state)

      # Return {observation, real_goal} so the harness can fix placeholder goals
      real_goal = env_module.format_goal(state[:goal] || task_config.goal)
      {observation, real_goal}
    end

    progress_fn =
      if verbose do
        fn result ->
          symbol = if result.success?, do: ".", else: "x"
          IO.write(symbol)
        end
      end

    harness_opts =
      Keyword.take(opts, [:llm, :environment])
      |> Keyword.put_new(:environment, env_module)
      |> Keyword.put(:observe_fn, observe_fn)
      |> then(fn o ->
        if progress_fn, do: Keyword.put(o, :on_task_done, progress_fn), else: o
      end)
      |> then(fn o ->
        if mc = env_config[:max_concurrency], do: Keyword.put(o, :max_concurrency, mc), else: o
      end)

    archive = Archive.new() |> Archive.seed_null() |> Archive.seed_environment(env_module)

    try do
      # Run baseline evaluation with null design (no memory) across multiple seeds
      deploy_seeds = Keyword.get(opts, :deploy_seeds, 3)
      null_design = MemoryHarness.null_design()

      total_baseline = deploy_seeds * episodes
      if verbose, do: IO.write("Running baseline (#{total_baseline} tasks)...")

      baseline_results =
        1..deploy_seeds
        |> Enum.flat_map(fn seed_idx ->
          seed_offset = 1000 * seed_idx
          baseline_env = Map.update!(env_config, :seed, &(&1 + seed_offset))
          baseline_tasks = env_module.generate_tasks(episodes, baseline_env)

          {results, _errors} =
            MemoryHarness.evaluate_deployment(null_design, %{}, baseline_tasks, harness_opts)

          results
        end)

      baseline_score = Loop.score_results(baseline_results)

      if verbose do
        IO.puts(" done")
        IO.puts("Baseline score (no memory): #{Float.round(baseline_score * 1.0, 2)}\n")
      end

      opts =
        opts
        |> Keyword.put(:baseline_score, baseline_score)
        |> Keyword.put(:observe_fn, observe_fn)

      opts =
        if mc = env_config[:max_concurrency],
          do: Keyword.put_new(opts, :max_concurrency, mc),
          else: opts

      archive =
        Enum.reduce(1..iterations, archive, fn gen, acc ->
          Loop.iteration(acc, gen, env_config, episodes, opts ++ [verbose: verbose])
        end)

      if verbose do
        IO.puts("\n=== Final Results ===")
        IO.puts(Archive.summary(archive))
      end

      archive
    after
      if function_exported?(env_module, :teardown, 1) do
        env_module.teardown(env_config)
      end
    end
  end

  defp preflight_check!(opts, verbose) do
    llm = Keyword.fetch!(opts, :llm)
    meta_llm = Keyword.get(opts, :meta_llm)
    ping = %{system: "Reply with OK.", messages: [%{role: :user, content: "ping"}]}

    models =
      if meta_llm && meta_llm != llm,
        do: [{"execution", llm}, {"meta", meta_llm}],
        else: [{"llm", llm}]

    if verbose, do: IO.write("Preflight check...")

    for {label, callback} <- models do
      case callback.(ping) do
        {:ok, _} ->
          if verbose, do: IO.write(" #{label} ok")

        {:error, reason} ->
          if verbose, do: IO.puts("")
          raise "Preflight failed for #{label} model: #{inspect(reason)}"
      end
    end

    if verbose, do: IO.puts("")
  end

  defp trace_path(true), do: "traces/alma_#{System.system_time(:second)}.jsonl"
  defp trace_path(path) when is_binary(path), do: path
end
