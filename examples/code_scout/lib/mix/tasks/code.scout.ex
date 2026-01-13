defmodule Mix.Tasks.Code.Scout do
  @moduledoc """
  Mix task to query your codebase using Code Scout.

  Usage:
      mix code.scout "Your query here"
  """
  use Mix.Task
  alias CodeScout

  @shortdoc "Scout your codebase with an LLM agent"

  def run(args) do
    # Load application and deps
    Application.ensure_all_started(:code_scout)

    # Load root .env file
    CodeScout.Env.load()

    {opts, remaining_args, _} =
      OptionParser.parse(args,
        switches: [
          trace: :boolean,
          verbose: :boolean,
          raw: :boolean,
          system_prompt: :boolean,
          compression: :boolean,
          max_turns: :integer
        ],
        aliases: [
          t: :trace,
          v: :verbose,
          r: :raw,
          s: :system_prompt,
          c: :compression,
          m: :max_turns
        ]
      )

    query_string = Enum.join(remaining_args, " ")

    if query_string == "" do
      Mix.shell().error("Error: Please provide a query.")

      Mix.shell().info(
        "Usage: mix code.scout \"query\" [--trace] [--verbose] [--raw] [--compression] [--max-turns N] [--system-prompt]"
      )
    else
      if opts[:system_prompt] do
        print_system_prompt(query_string)
      else
        Mix.shell().info("Code Scout is investigating: \"#{query_string}\"...")

        query_opts = [
          debug: opts[:trace] || false,
          compression: opts[:compression] || false,
          max_turns: opts[:max_turns] || 10
        ]

        case CodeScout.query(query_string, query_opts) do
          {:ok, step} ->
            if opts[:trace] do
              PtcRunner.SubAgent.Debug.print_trace(step,
                messages: opts[:verbose],
                raw: opts[:raw],
                usage: true
              )
            end

            print_result(step.return)

          {:error, step} ->
            if opts[:trace] do
              PtcRunner.SubAgent.Debug.print_trace(step,
                messages: opts[:verbose],
                raw: opts[:raw],
                usage: true
              )
            end

            Mix.shell().error("Code Scout failed!")
            Mix.shell().error(inspect(step.fail))
        end
      end
    end
  end

  defp print_result(%{answer: answer, relevant_files: files, confidence: confidence}) do
    Mix.shell().info("\n" <> String.duplicate("=", 40))
    Mix.shell().info("ANSWER (Confidence: #{Float.round(confidence * 100, 1)}%)")
    Mix.shell().info(String.duplicate("=", 40))
    Mix.shell().info(answer)
    Mix.shell().info("\nRelevant Files:")
    Enum.each(files, fn file -> Mix.shell().info("- #{file}") end)
  end

  defp print_result(other) do
    Mix.shell().info("\nReceived non-standard result:")
    IO.inspect(other)
  end

  defp print_system_prompt(query_string) do
    alias CodeScout.Agent
    alias PtcRunner.SubAgent.SystemPrompt

    agent = Agent.new()
    context = %{"query" => query_string}
    system_prompt = SystemPrompt.generate(agent, context: context)

    Mix.shell().info("\n" <> String.duplicate("=", 60))
    Mix.shell().info("SYSTEM PROMPT")
    Mix.shell().info(String.duplicate("=", 60))
    Mix.shell().info(system_prompt)
    Mix.shell().info(String.duplicate("=", 60))
  end
end
