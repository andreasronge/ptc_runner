defmodule PtcDemo.Planning.Runner do
  @moduledoc """
  Runs planner→executor benchmark experiments.

  Compares three conditions on plan-mode test cases:
  - `:direct` — no plan, ReAct-style
  - `:planned` — LLM generates plan, executor runs with `plan:`
  - `:specified` — developer-specified plan steps (baseline)
  """

  alias PtcDemo.{LispTestRunner, SampleData}
  alias PtcRunner.Metrics.TurnAnalysis
  alias PtcRunner.SubAgent

  @type condition :: :direct | :planned | :specified

  @type run_result :: %{
          condition: String.t(),
          test_index: pos_integer(),
          run: pos_integer(),
          passed?: boolean(),
          metrics: map(),
          duration_ms: non_neg_integer(),
          tool_call_count: non_neg_integer(),
          plan_steps: [String.t()] | nil,
          planner_tokens: non_neg_integer() | nil,
          executor_tokens: non_neg_integer() | nil
        }

  @doc """
  Run a planning benchmark experiment.

  ## Options

    * `:runs` - Number of runs per test per condition (default: 1)
    * `:tests` - List of test indices to run (required)
    * `:model` - Model override
    * `:verbose` - Show detailed output (default: false)
    * `:agent` - Agent module (default: PtcDemo.Agent)
  """
  @spec run([condition()], keyword()) :: [run_result()]
  def run(conditions, opts \\ []) do
    runs = Keyword.get(opts, :runs, 1)
    tests = Keyword.fetch!(opts, :tests)
    model = Keyword.get(opts, :model)
    agent_mod = Keyword.get(opts, :agent, PtcDemo.Agent)
    verbose = Keyword.get(opts, :verbose, false)

    total_cases = length(tests)
    total_runs = length(conditions) * total_cases * runs

    IO.puts("\n=== Planning Benchmark ===")
    IO.puts("Conditions: #{Enum.map_join(conditions, ", ", &Atom.to_string/1)}")
    IO.puts("Tests: #{total_cases}, Runs per test: #{runs}")
    IO.puts("Total runs: #{total_runs}")
    IO.puts("")

    all_cases = test_cases()

    results =
      for condition <- conditions do
        condition_name = Atom.to_string(condition)
        IO.write("#{condition_name}: ")

        condition_results =
          for run_num <- 1..runs do
            for test_index <- tests do
              test_case = Enum.at(all_cases, test_index - 1)

              result =
                run_condition(condition, test_case, test_index, model, verbose, agent_mod)

              if result.passed?, do: IO.write("."), else: IO.write("X")
              %{result | run: run_num}
            end
          end

        IO.puts("")
        List.flatten(condition_results)
      end

    List.flatten(results)
  end

  defp run_condition(:direct, _test_case, index, model, _verbose, agent_mod) do
    start = System.monotonic_time(:millisecond)

    run_opts = [
      runs: 1,
      verbose: false,
      agent_overrides: [plan: nil],
      agent: agent_mod
    ]

    run_opts = if model, do: Keyword.put(run_opts, :model, model), else: run_opts

    test_result = LispTestRunner.run_one(index, run_opts)
    duration = System.monotonic_time(:millisecond) - start

    step = test_result[:step]
    passed? = test_result[:passed] || false
    metrics = analyze_step(step, passed?)

    %{
      condition: "direct",
      test_index: index,
      run: 1,
      passed?: passed?,
      metrics: metrics,
      duration_ms: duration,
      tool_call_count: count_tool_calls(step),
      plan_steps: nil,
      planner_tokens: nil,
      executor_tokens: nil
    }
  end

  defp run_condition(:specified, test_case, index, model, _verbose, agent_mod) do
    start = System.monotonic_time(:millisecond)

    run_opts = [
      runs: 1,
      verbose: false,
      agent: agent_mod
    ]

    run_opts = if model, do: Keyword.put(run_opts, :model, model), else: run_opts

    test_result = LispTestRunner.run_one(index, run_opts)
    duration = System.monotonic_time(:millisecond) - start

    step = test_result[:step]
    passed? = test_result[:passed] || false
    metrics = analyze_step(step, passed?)

    %{
      condition: "specified",
      test_index: index,
      run: 1,
      passed?: passed?,
      metrics: metrics,
      duration_ms: duration,
      tool_call_count: count_tool_calls(step),
      plan_steps: Map.get(test_case, :plan),
      planner_tokens: nil,
      executor_tokens: extract_total_tokens(step)
    }
  end

  defp run_condition(:planned, test_case, index, model, verbose, agent_mod) do
    start = System.monotonic_time(:millisecond)

    # Phase 1: Run planner
    case run_planner(test_case.query, model) do
      {:ok, plan_steps, planner_step} ->
        planner_tokens = extract_total_tokens(planner_step)

        if verbose do
          IO.puts("\n  Planner generated #{length(plan_steps)} steps:")
          Enum.each(plan_steps, fn s -> IO.puts("    - #{s}") end)
        end

        # Phase 2: Run executor with generated plan
        # Use the same prompt routing as direct/specified (via :auto → :explicit_return for multi-turn)
        prompt_profile =
          if Map.get(test_case, :max_turns, 1) > 1, do: :explicit_return, else: :single_shot

        agent_mod.reset()
        agent_mod.set_data_mode(:schema)
        agent_mod.set_prompt_profile(prompt_profile)

        ask_opts = [
          max_turns: Map.get(test_case, :max_turns, 6),
          expect: Map.get(test_case, :expect),
          plan: plan_steps,
          trace_label: "planning-benchmark-#{index}"
        ]

        ask_opts =
          if sig = Map.get(test_case, :signature) do
            Keyword.put(ask_opts, :signature, sig)
          else
            ask_opts
          end

        {passed?, executor_step} =
          case agent_mod.ask(test_case.query, ask_opts) do
            {:ok, _formatted} ->
              # Use raw step.return for validation, not the formatted display string
              step = agent_mod.last_step()
              raw_value = step.return
              validation = PtcDemo.TestRunner.Base.validate_result(raw_value, test_case)

              if verbose do
                if validation.passed do
                  IO.puts("  Executor PASS: #{inspect(raw_value)}")
                else
                  IO.puts("  Executor FAIL (validation): #{inspect(validation[:error])}")
                  IO.puts("  Got: #{inspect(raw_value)}")
                end
              end

              {validation.passed, step}

            {:error, reason} ->
              if verbose do
                IO.puts("  Executor FAIL (error): #{inspect(reason)}")
              end

              {false, agent_mod.last_step()}
          end

        duration = System.monotonic_time(:millisecond) - start
        executor_tokens = extract_total_tokens(executor_step)

        # Combine metrics: use executor step for turn analysis, add planner tokens
        metrics = analyze_step(executor_step, passed?)

        combined_tokens =
          (planner_tokens || 0) + (metrics[:total_tokens] || 0)

        metrics = Map.put(metrics, :total_tokens, combined_tokens)

        %{
          condition: "planned",
          test_index: index,
          run: 1,
          passed?: passed?,
          metrics: metrics,
          duration_ms: duration,
          tool_call_count: count_tool_calls(executor_step),
          plan_steps: plan_steps,
          planner_tokens: planner_tokens,
          executor_tokens: executor_tokens
        }

      {:error, planner_step} ->
        if verbose do
          reason = planner_step.fail || planner_step.return || "unknown"
          IO.puts("\n  Planner failed: #{inspect(reason)}")
        end

        duration = System.monotonic_time(:millisecond) - start
        planner_tokens = extract_total_tokens(planner_step)

        # Include planner token cost in metrics even on failure
        metrics = analyze_step(nil, false)

        metrics =
          if planner_tokens do
            Map.put(metrics, :total_tokens, planner_tokens)
          else
            metrics
          end

        %{
          condition: "planned",
          test_index: index,
          run: 1,
          passed?: false,
          metrics: metrics,
          duration_ms: duration,
          tool_call_count: 0,
          plan_steps: nil,
          planner_tokens: planner_tokens,
          executor_tokens: nil
        }
    end
  end

  # Build and run the planner SubAgent
  defp run_planner(query, model_override) do
    # Use model override or fall back to Agent's current model
    model = model_override || PtcDemo.Agent.model()

    agent =
      SubAgent.new(
        prompt: "Decompose this task into steps:\n\n{{task}}",
        signature: "(task :string) -> {steps [:string]}",
        output: :text,
        max_turns: 1,
        system_prompt: %{prefix: planner_system_prompt()}
      )

    trace_path = planner_trace_path()

    try do
      {:ok, result, _trace_path} =
        PtcRunner.TraceLog.with_trace(
          fn ->
            SubAgent.run(agent, llm: model, context: %{"task" => query})
          end,
          path: trace_path,
          trace_kind: "planning",
          producer: "demo.planner",
          model: model,
          query: String.slice(query, 0, 200)
        )

      case result do
        {:ok, step} ->
          case step.return do
            %{"steps" => steps} when is_list(steps) ->
              {:ok, steps, step}

            _other ->
              {:error, step}
          end

        {:error, step} ->
          {:error, step}
      end
    rescue
      e ->
        {:error, %PtcRunner.Step{fail: %{reason: Exception.message(e)}}}
    end
  end

  defp planner_trace_path do
    trace_dir = "traces"
    File.mkdir_p!(trace_dir)
    datetime = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    unique_id = :erlang.unique_integer([:positive])
    Path.join(trace_dir, "planner_#{datetime}_#{unique_id}.jsonl")
  end

  defp planner_system_prompt do
    descriptions = SampleData.context_descriptions()

    schema_text =
      descriptions
      |> Enum.map_join("\n", fn {name, desc} -> "- #{name}: #{desc}" end)

    """
    You are a task decomposition planner. Given a data analysis task, break it into \
    sequential steps that an executor agent will follow.

    The executor has access to these tools:
    - search(query :string) -> [{id, title, topic, snippet}] — Search documents by keyword
    - fetch(id :string) -> {id, title, topic, content} — Fetch full document by ID

    The executor has these datasets in context (accessible as variables):
    #{schema_text}

    Return a list of 2-6 clear, actionable steps. Each step should describe one logical \
    operation. Keep steps focused — prefer more smaller steps over fewer large ones.
    """
  end

  defp analyze_step(nil, passed?) do
    TurnAnalysis.analyze(%PtcRunner.Step{}, passed?: passed?)
  end

  defp analyze_step(step, passed?) do
    TurnAnalysis.analyze(step, passed?: passed?)
  end

  defp extract_total_tokens(nil), do: nil

  defp extract_total_tokens(%{usage: %{total_tokens: t}}), do: t
  defp extract_total_tokens(_), do: nil

  defp count_tool_calls(nil), do: 0
  defp count_tool_calls(%{tool_calls: calls}) when is_list(calls), do: length(calls)
  defp count_tool_calls(_), do: 0

  defp test_cases do
    alias PtcDemo.TestRunner.TestCase

    TestCase.common_test_cases() ++
      TestCase.lisp_specific_cases() ++
      TestCase.multi_turn_cases() ++
      TestCase.plan_cases()
  end
end
