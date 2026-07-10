defmodule Mix.Tasks.Ptc.KernelFeedbackAb do
  @shortdoc "Run the M2 feedback-only A/B shakedown"
  @moduledoc """
  Runs the preregistered M2 feedback-only A/B shakedown.

      mix ptc.kernel_feedback_ab --mock --runs 1
      mix ptc.kernel_feedback_ab --live --model deepseek --runs 5 --allow-failures
      mix ptc.kernel_feedback_ab --live --model deepseek --runs 5 --allow-failures --report reports/kernel_eval/m2-feedback-ab-live.md
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
      |> Keyword.put(:report, opts[:report])
      |> maybe_put_debug_agent(debug_agent)

    try do
      case run_feedback(eval_opts) do
        {:ok, result} ->
          handle_result!(result, opts)

        {:error, {:missing_api_key, key, model}} ->
          Mix.raise("#{key} is required for live model #{model}")

        {:error, reason} ->
          Mix.raise("feedback A/B shakedown failed: #{inspect(reason)}")
      end
    after
      cleanup_debug.()
    end
  end

  # Keep the Mix task boundary typed to the public contract. Dialyzer narrows
  # FeedbackAB.run/1 to its live preflight error path when analysing this task,
  # even though the mock path and injected-live path return successful results.
  @spec run_feedback(keyword()) :: {:ok, FeedbackAB.result()} | {:error, term()}
  defp run_feedback(opts), do: (&FeedbackAB.run/1).(opts)

  @doc false
  @spec handle_result!(FeedbackAB.result(), keyword()) :: :ok | no_return()
  def handle_result!(result, opts) do
    markdown = FeedbackAB.render_markdown(result)
    Mix.shell().info(markdown)

    try do
      maybe_write_report(opts[:report], markdown, not is_nil(Map.get(result, :run_context)))
      maybe_write_unsafe_debug(opts[:unsafe_debug_report], result)
      FeedbackAB.finalize_run_context(result)
    rescue
      exception ->
        FeedbackAB.abort_run_context(result, exception)
        reraise exception, __STACKTRACE__
    end

    cond do
      result.aborted ->
        Mix.raise("feedback A/B shakedown aborted: #{inspect(result.abort_reason)}")

      opts[:allow_failures] != true and not FeedbackAB.passed?(result) ->
        Mix.raise(
          "feedback A/B shakedown failed: #{FeedbackAB.failure_count(result)} case(s) failed"
        )

      true ->
        :ok
    end
  end

  defp maybe_write_report(nil, _markdown, _exclusive?), do: :ok

  defp maybe_write_report(path, markdown, exclusive?) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, markdown <> "\n", if(exclusive?, do: [:exclusive], else: []))
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
    ensure_private_file!(path)
    File.write!(path, FeedbackAB.render_unsafe_debug(result) <> "\n")
    File.chmod!(path, 0o600)
    Mix.shell().info("Wrote unsafe debug report #{path}")
  end

  defp ensure_private_file!(path) do
    unless File.exists?(path), do: File.write!(path, "", [:exclusive])
    File.chmod!(path, 0o600)
  end
end
