defmodule PtcDemo.Ablation.Runner do
  @moduledoc """
  Runs ablation experiments: variant x test x N runs matrix.

  Thin orchestration over `PtcDemo.LispTestRunner`.
  """

  alias PtcDemo.LispTestRunner
  alias PtcRunner.Metrics.TurnAnalysis

  @type variant :: %{
          name: String.t(),
          agent_overrides: keyword()
        }

  @type run_result :: %{
          variant: String.t(),
          test_index: pos_integer(),
          run: pos_integer(),
          passed?: boolean(),
          metrics: map(),
          duration_ms: non_neg_integer()
        }

  @doc """
  Run an ablation experiment.

  ## Options

    * `:runs` - Number of runs per test per variant (default: 1)
    * `:tests` - List of test indices to run (required)
    * `:model` - Model override
    * `:verbose` - Show detailed output (default: false)
    * `:agent` - Agent module (default: PtcDemo.Agent)
  """
  @spec run([variant()], keyword()) :: [run_result()]
  def run(variants, opts \\ []) do
    runs = Keyword.get(opts, :runs, 1)

    tests =
      Keyword.fetch!(opts, :tests)

    model = Keyword.get(opts, :model)
    agent_mod = Keyword.get(opts, :agent, PtcDemo.Agent)

    total_cases = length(tests)
    total_runs = length(variants) * total_cases * runs

    IO.puts("\n=== Ablation Experiment ===")
    IO.puts("Variants: #{Enum.map_join(variants, ", ", & &1.name)}")
    IO.puts("Tests: #{total_cases}, Runs per test: #{runs}")
    IO.puts("Total runs: #{total_runs}")
    IO.puts("")

    results =
      for variant <- variants do
        IO.write("#{variant.name}: ")

        variant_results =
          for run_num <- 1..runs do
            for test_index <- tests do
              start = System.monotonic_time(:millisecond)

              # Run the test with this variant's overrides
              run_opts = [
                runs: 1,
                verbose: false,
                agent_overrides: Map.get(variant, :agent_overrides, []),
                agent: agent_mod
              ]

              # Policy variants use :prompt for runner-level routing (prompt_for_test)
              run_opts =
                case Map.get(variant, :prompt) do
                  nil -> run_opts
                  prompt -> Keyword.put(run_opts, :prompt, prompt)
                end

              run_opts = if model, do: Keyword.put(run_opts, :model, model), else: run_opts

              test_result = LispTestRunner.run_one(test_index, run_opts)

              duration = System.monotonic_time(:millisecond) - start

              # Extract metrics from Step
              step = test_result[:step]
              passed? = test_result[:passed] || false

              metrics =
                if step do
                  TurnAnalysis.analyze(step, passed?: passed?)
                else
                  TurnAnalysis.analyze(%PtcRunner.Step{}, passed?: passed?)
                end

              # Progress indicator
              if passed?, do: IO.write("."), else: IO.write("X")

              %{
                variant: variant.name,
                test_index: test_index,
                run: run_num,
                passed?: passed?,
                metrics: metrics,
                duration_ms: duration
              }
            end
          end

        IO.puts("")
        List.flatten(variant_results)
      end

    List.flatten(results)
  end
end
