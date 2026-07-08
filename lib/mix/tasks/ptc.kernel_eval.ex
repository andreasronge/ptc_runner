defmodule Mix.Tasks.Ptc.KernelEval do
  @shortdoc "Run the tiny kernel eval suite"
  @moduledoc """
  Runs the experimental kernel mini eval suite.

      mix ptc.kernel_eval --suite mini
      mix ptc.kernel_eval --suite mini --live --model deepseek
      mix ptc.kernel_eval --suite mini --live --model deepseek --allow-failures
      mix ptc.kernel_eval --suite mini --runs 3 --case eval_retry
  """

  use Mix.Task

  alias PtcRunner.Kernel.Eval

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
      |> Keyword.take([:suite, :runs, :case, :model])
      |> Keyword.put(:mode, mode)

    case Eval.run(eval_opts) do
      {:ok, report} ->
        Mix.shell().info(Eval.render_markdown(report))

        if opts[:allow_failures] != true and not Eval.passed?(report) do
          Mix.raise("kernel eval failed: #{Eval.failure_count(report)} case(s) failed")
        end

      {:error, {:missing_api_key, key, model}} ->
        Mix.raise("#{key} is required for live model #{model}")

      {:error, reason} ->
        Mix.raise("kernel eval failed: #{inspect(reason)}")
    end
  end
end
