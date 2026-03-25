defmodule Mix.Tasks.TraceAnalyze do
  @moduledoc """
  Ask the trace analyzer agent a question about execution traces.

  ## Usage

      mix trace_analyze "Why did this run take so many turns?"
      mix trace_analyze "Compare the planned and direct traces" --trace-dir demo/traces
      mix trace_analyze "Which traces failed and why?"

  ## Options

    * `--trace-dir` - Directory containing .jsonl traces (default: traces)
    * `--max-turns` - Maximum agent turns (default: 8)
    * `--verbose` - Show debug output
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, positional, _} =
      OptionParser.parse(args,
        strict: [
          trace_dir: :string,
          max_turns: :integer,
          verbose: :boolean
        ],
        aliases: [d: :trace_dir, v: :verbose]
      )

    question =
      case positional do
        [] -> Mix.raise("Usage: mix trace_analyze \"your question here\"")
        parts -> Enum.join(parts, " ")
      end

    trace_dir = Keyword.get(parsed, :trace_dir, "traces")
    max_turns = Keyword.get(parsed, :max_turns, 8)
    verbose = Keyword.get(parsed, :verbose, false)

    # Ensure API key
    PtcDemo.CLIBase.load_dotenv()
    PtcDemo.CLIBase.ensure_api_key!()

    # Start agent for model resolution
    case Process.whereis(PtcDemo.Agent) do
      nil -> PtcDemo.Agent.start_link()
      _pid -> :ok
    end

    IO.puts("Analyzing traces in #{trace_dir}...")
    IO.puts("Question: #{question}\n")

    case PtcDemo.TraceAnalyzer.Agent.ask(question,
           trace_dir: trace_dir,
           max_turns: max_turns,
           verbose: verbose
         ) do
      {:ok, step} ->
        answer =
          if is_binary(step.return), do: step.return, else: inspect(step.return, pretty: true)

        IO.puts(answer)
        IO.puts("\n[#{step.usage[:turns]} turns, #{step.usage[:total_tokens]} tokens]")

      {:error, step} ->
        IO.puts("Error: #{inspect(step.fail)}")
    end
  end
end
