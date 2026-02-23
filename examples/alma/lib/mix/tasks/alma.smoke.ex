defmodule Mix.Tasks.Alma.Smoke do
  @moduledoc """
  Smoke test to verify an LLM can drive the ALMA task agent.

  Runs a single easy GraphWorld episode (3 rooms, object adjacent to start)
  and reports whether the model can drive the task agent via native tool calling.

  ## Usage

      mix alma.smoke [options]

  ## Options

    * `--model` - LLM model to test (default: "bedrock:haiku")
    * `--rooms` - number of rooms (default: 3)
    * `--seed`  - random seed (default: 100)

  ## Examples

      mix alma.smoke --model groq:gpt-oss
      mix alma.smoke --model bedrock:sonnet
  """

  use Mix.Task

  alias Alma.Environments.GraphWorld
  alias Alma.Environments.GraphWorld.Generator

  @shortdoc "Smoke test an LLM for ALMA task agent compatibility"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [model: :string, rooms: :integer, seed: :integer]
      )

    model = Keyword.get(opts, :model, "bedrock:haiku")
    rooms = Keyword.get(opts, :rooms, 3)
    seed = Keyword.get(opts, :seed, 100)

    raw_llm = LLMClient.callback(model)
    {:ok, stats} = Agent.start_link(fn -> %{calls: 0, total_us: 0} end)

    llm = fn req ->
      {us, result} = :timer.tc(fn -> raw_llm.(req) end)
      Agent.update(stats, fn s -> %{s | calls: s.calls + 1, total_us: s.total_us + us} end)
      result
    end

    Mix.shell().info("ALMA smoke test: #{model}")
    Mix.shell().info("  rooms: #{rooms}, seed: #{seed}\n")

    task_config = Generator.generate_task(%{rooms: rooms, seed: seed, objects: 2})
    goal = task_config.goal
    Mix.shell().info("Task: place #{goal.object} in #{goal.destination}")
    Mix.shell().info("Start: #{task_config.agent_location}")

    state = GraphWorld.reset(task_config)
    obs = GraphWorld.observe(state)
    Mix.shell().info("Objects visible: #{inspect(obs.objects)}")
    Mix.shell().info("Exits: #{inspect(obs.exits)}\n")

    Mix.shell().info("Running task agent...")

    {t1_us, result} = :timer.tc(fn -> Alma.TaskAgent.run(task_config, "", llm: llm) end)
    t1_ms = div(t1_us, 1000)

    Mix.shell().info("")

    if result.success? do
      Mix.shell().info("PASS - completed in #{result.steps} steps (#{t1_ms}ms)")
      Mix.shell().info("Actions: #{inspect(result.actions)}")
    else
      Mix.shell().info("FAIL (#{t1_ms}ms)")

      if result[:error] do
        Mix.shell().info("Error: #{format_error(result.error)}")
      end

      Mix.shell().info("Actions taken: #{inspect(result.actions)}")
      Mix.shell().info("Steps: #{result.steps}")

      if result.observation_log != [] do
        last = List.last(result.observation_log)
        Mix.shell().info("Last observation: #{inspect(last, limit: 5)}")
      end
    end

    # Run a second episode with knowledge to test recall tool
    Mix.shell().info("\n--- Round 2 (with recall advice) ---")

    advice =
      "The #{goal.object} is near #{task_config.agent_location}. Pick it up and go to #{goal.destination}."

    Mix.shell().info("Advice: #{advice}\n")

    {t2_us, result2} = :timer.tc(fn -> Alma.TaskAgent.run(task_config, advice, llm: llm) end)
    t2_ms = div(t2_us, 1000)

    if result2.success? do
      Mix.shell().info("PASS - completed in #{result2.steps} steps (#{t2_ms}ms)")
    else
      Mix.shell().info("FAIL (#{t2_ms}ms)")

      if result2[:error] do
        Mix.shell().info("Error: #{format_error(result2.error)}")
      end
    end

    # Summary
    total_ms = t1_ms + t2_ms
    total_steps = result.steps + result2.steps
    llm_stats = Agent.get(stats, & &1)
    Agent.stop(stats)
    llm_ms = div(llm_stats.total_us, 1000)

    Mix.shell().info("\n--- Summary ---")
    pass_count = Enum.count([result, result2], & &1.success?)
    Mix.shell().info("#{pass_count}/2 episodes passed")
    Mix.shell().info("Total time: #{total_ms}ms (#{t1_ms}ms + #{t2_ms}ms)")

    Mix.shell().info(
      "LLM time: #{llm_ms}ms (#{llm_stats.calls} calls, #{pct(llm_ms, total_ms)}% of total)"
    )

    if llm_stats.calls > 0 do
      avg_llm_ms = div(llm_ms, llm_stats.calls)
      Mix.shell().info("Avg LLM call: #{avg_llm_ms}ms")
    end

    Mix.shell().info("Total steps: #{total_steps}")

    if total_steps > 0 do
      avg_ms = div(total_ms, total_steps)
      Mix.shell().info("Avg time per step: #{avg_ms}ms")
    end

    if pass_count == 0 do
      Mix.shell().info("Model #{model} is NOT suitable for ALMA task agents.")
    else
      Mix.shell().info("Model #{model} is suitable for ALMA task agents.")
    end
  end

  defp pct(_part, 0), do: 0
  defp pct(part, total), do: div(part * 100, total)

  defp format_error(%PtcRunner.Step{fail: %{message: msg}}), do: msg
  defp format_error(error), do: inspect(error, limit: 3)
end
