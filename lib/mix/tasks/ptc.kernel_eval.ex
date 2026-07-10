defmodule Mix.Tasks.Ptc.KernelEval do
  @shortdoc "Run the tiny kernel eval suite"
  @moduledoc """
  Runs the experimental kernel eval suites.

      mix ptc.kernel_eval --suite mini
      mix ptc.kernel_eval --suite mini --live --model deepseek
      mix ptc.kernel_eval --suite mini --live --model deepseek --allow-failures
      mix ptc.kernel_eval --suite mini --runs 3 --case eval_retry
      mix ptc.kernel_eval --suite smoke --live --runs 5 --variant kernel \
        --model deepseek --report reports/kernel_eval/m1-kernel-smoke.md \
        --trace-dir reports/kernel_eval/m1-kernel-smoke-traces
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
          allow_failures: :boolean,
          variant: :string,
          report: :string,
          trace_dir: :string
        ]
      )

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    mode = if opts[:live], do: :live, else: :mock

    eval_opts =
      opts
      |> Keyword.take([:suite, :runs, :case, :model, :variant, :report, :trace_dir])
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
