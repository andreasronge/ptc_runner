defmodule Mix.Tasks.Ptc.KernelEval do
  @shortdoc "Run the kernel evaluation suites"
  @moduledoc """
  Runs the experimental kernel eval suites.

      mix ptc.kernel_eval --suite mini
      mix ptc.kernel_eval --suite mini --live --model deepseek
      mix ptc.kernel_eval --suite mini --live --model deepseek --allow-failures
      mix ptc.kernel_eval --suite mini --runs 3 --case eval_retry
      mix ptc.kernel_eval --suite tier2 --seed 17 --variant incumbent \
        --report reports/kernel_eval/m2-incumbent.md
      mix ptc.kernel_eval --suite tier2 --seed 17 --paired --live --model deepseek \
        --report reports/kernel_eval/m2-tier2.md
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
          seed: :integer,
          case: :string,
          model: :string,
          live: :boolean,
          mock: :boolean,
          allow_failures: :boolean,
          variant: :string,
          report: :string,
          trace_dir: :string,
          paired: :boolean,
          return_contracts: :boolean,
          unsafe_debug_report: :string
        ]
      )

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    mode = if opts[:live], do: :live, else: :mock
    {debug_agent, cleanup_debug} = unsafe_debug_agent(opts[:unsafe_debug_report])

    eval_opts =
      opts
      |> Keyword.take([
        :suite,
        :runs,
        :seed,
        :case,
        :model,
        :variant,
        :report,
        :trace_dir,
        :return_contracts
      ])
      |> Keyword.put(:mode, mode)
      |> maybe_put_debug_agent(debug_agent)

    runner = if opts[:paired], do: &Eval.run_pair/1, else: &Eval.run/1

    try do
      case runner.(eval_opts) do
        {:ok, report} ->
          Mix.shell().info(Eval.render_markdown(report))
          validate_report!(report, opts[:allow_failures] == true)

        {:error, {:missing_api_key, key, model}} ->
          Mix.raise("#{key} is required for live model #{model}")

        {:error, reason} ->
          Mix.raise("kernel eval failed: #{inspect(reason)}")
      end
    after
      maybe_write_unsafe_debug(opts[:unsafe_debug_report], debug_agent)
      cleanup_debug.()
    end
  end

  defp unsafe_debug_agent(nil), do: {nil, fn -> :ok end}

  defp unsafe_debug_agent(_path) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    {agent, fn -> if Process.alive?(agent), do: Agent.stop(agent) end}
  end

  defp maybe_put_debug_agent(opts, nil), do: opts
  defp maybe_put_debug_agent(opts, agent), do: Keyword.put(opts, :unsafe_debug_agent, agent)

  defp maybe_write_unsafe_debug(nil, _agent), do: :ok

  defp maybe_write_unsafe_debug(path, agent) do
    write_unsafe_debug_report(path, Agent.get(agent, &Enum.reverse/1))
  end

  @doc false
  def write_unsafe_debug_report(path, events) do
    File.mkdir_p!(Path.dirname(path))
    unless File.exists?(path), do: File.write!(path, "", [:exclusive])
    File.chmod!(path, 0o600)

    File.write!(
      path,
      """
      # UNSAFE Kernel Eval Diagnostic Report

      This file contains raw model-visible prompts/messages, model responses,
      generated programs, and evaluation results. It is not benchmark evidence.
      Do not publish or commit it.

      ```elixir
      #{inspect(events, pretty: true, limit: :infinity, printable_limit: :infinity)}
      ```
      """
    )

    File.chmod!(path, 0o600)
    Mix.shell().info("Wrote unsafe debug report #{path}")
  end

  @doc false
  @spec validate_report!(map(), boolean()) :: :ok
  def validate_report!(%{aborted: true, abort_reason: reason}, _allow_failures?) do
    Mix.raise("kernel eval aborted: #{reason}")
  end

  def validate_report!(%{variant: "paired", reports: reports}, false) do
    failures = Enum.sum(Enum.map(reports, &Eval.failure_count/1))

    if failures == 0 do
      :ok
    else
      Mix.raise("kernel eval failed: #{failures} paired case(s) failed")
    end
  end

  def validate_report!(report, false) do
    if Eval.passed?(report) do
      :ok
    else
      Mix.raise("kernel eval failed: #{Eval.failure_count(report)} case(s) failed")
    end
  end

  def validate_report!(_report, true), do: :ok
end
