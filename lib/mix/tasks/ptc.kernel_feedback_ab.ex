defmodule Mix.Tasks.Ptc.KernelFeedbackAb do
  @shortdoc "Run the S19 feedback-only A/B shakedown"
  @moduledoc """
  Runs the preregistered S19 feedback-only A/B shakedown.

      mix ptc.kernel_feedback_ab --mock --runs 1
      mix ptc.kernel_feedback_ab --live --model deepseek --runs 5 --allow-failures
      mix ptc.kernel_feedback_ab --live --model deepseek --runs 5 --allow-failures --report reports/kernel_eval/s19-feedback-ab-live.md
      mix ptc.kernel_feedback_ab --live --model deepseek --case context_aggregation --cell C --runs 20 --stop-on-failure --unsafe-debug-report reports/kernel_eval/debug-c-context.md
  """

  use Mix.Task

  alias PtcRunner.Kernel.FeedbackAB

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          suite: :string,
          runs: :integer,
          case: :string,
          cell: :string,
          model: :string,
          seed: :string,
          report: :string,
          unsafe_debug_report: :string,
          stop_on_failure: :boolean,
          live: :boolean,
          mock: :boolean,
          allow_failures: :boolean
        ]
      )

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    mode = if opts[:live], do: :live, else: :mock
    {debug_agent, cleanup_debug} = unsafe_debug_agent(opts[:unsafe_debug_report])

    eval_opts =
      opts
      |> Keyword.take([:suite, :runs, :case, :cell, :model, :seed, :stop_on_failure])
      |> Keyword.put(:mode, mode)
      |> maybe_put_debug_agent(debug_agent)

    try do
      case FeedbackAB.run(eval_opts) do
        {:ok, result} ->
          markdown = FeedbackAB.render_markdown(result)
          Mix.shell().info(markdown)
          maybe_write_report(opts[:report], markdown)
          maybe_write_unsafe_debug(opts[:unsafe_debug_report], result)

          if opts[:allow_failures] != true and not FeedbackAB.passed?(result) do
            Mix.raise(
              "feedback A/B shakedown failed: #{FeedbackAB.failure_count(result)} case(s) failed"
            )
          end

        {:error, {:missing_api_key, key, model}} ->
          Mix.raise("#{key} is required for live model #{model}")

        {:error, reason} ->
          Mix.raise("feedback A/B shakedown failed: #{inspect(reason)}")
      end
    after
      cleanup_debug.()
    end
  end

  defp maybe_write_report(nil, _markdown), do: :ok

  defp maybe_write_report(path, markdown) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, markdown <> "\n")
    Mix.shell().info("Wrote #{path}")
  end

  defp unsafe_debug_agent(nil), do: {nil, fn -> :ok end}

  defp unsafe_debug_agent(_path) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    {agent, fn -> if Process.alive?(agent), do: Agent.stop(agent) end}
  end

  defp maybe_put_debug_agent(opts, nil), do: opts
  defp maybe_put_debug_agent(opts, agent), do: Keyword.put(opts, :unsafe_debug_agent, agent)

  defp maybe_write_unsafe_debug(nil, _result), do: :ok

  defp maybe_write_unsafe_debug(path, result) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, FeedbackAB.render_unsafe_debug(result) <> "\n")
    Mix.shell().info("Wrote unsafe debug report #{path}")
  end
end
