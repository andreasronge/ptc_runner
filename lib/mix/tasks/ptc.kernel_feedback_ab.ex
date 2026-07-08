defmodule Mix.Tasks.Ptc.KernelFeedbackAb do
  @shortdoc "Run the S19 feedback-only A/B shakedown"
  @moduledoc """
  Runs the preregistered S19 feedback-only A/B shakedown.

      mix ptc.kernel_feedback_ab --mock --runs 1
      mix ptc.kernel_feedback_ab --live --model deepseek --runs 5 --allow-failures
      mix ptc.kernel_feedback_ab --live --model deepseek --runs 5 --allow-failures --report reports/kernel_eval/s19-feedback-ab-live.md
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
          model: :string,
          seed: :string,
          report: :string,
          live: :boolean,
          mock: :boolean,
          allow_failures: :boolean
        ]
      )

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    mode = if opts[:live], do: :live, else: :mock

    eval_opts =
      opts
      |> Keyword.take([:suite, :runs, :case, :model, :seed])
      |> Keyword.put(:mode, mode)

    case FeedbackAB.run(eval_opts) do
      {:ok, result} ->
        markdown = FeedbackAB.render_markdown(result)
        Mix.shell().info(markdown)
        maybe_write_report(opts[:report], markdown)

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
  end

  defp maybe_write_report(nil, _markdown), do: :ok

  defp maybe_write_report(path, markdown) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, markdown <> "\n")
    Mix.shell().info("Wrote #{path}")
  end
end
