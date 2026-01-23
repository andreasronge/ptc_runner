defmodule Mix.Tasks.Git.Query do
  @moduledoc """
  Query a git repository with natural language.

  Usage:
      mix git.query "question" [OPTIONS]

  Options:
      --repo, -r    Path to the git repository (default: current directory)
      --debug, -d   Show debug output
      --model, -m   LLM model to use

  Examples:
      mix git.query "Who contributed most this month?"
      mix git.query "What files changed the most recently?" --debug
      mix git.query "Show Alice's recent commits" --repo /path/to/repo
  """
  use Mix.Task

  @shortdoc "Query a git repository with natural language"

  def run(args) do
    Application.ensure_all_started(:git_query)
    GitQuery.Env.load()

    {opts, remaining, _} =
      OptionParser.parse(args,
        switches: [
          repo: :string,
          debug: :boolean,
          model: :string
        ],
        aliases: [
          r: :repo,
          d: :debug,
          m: :model
        ]
      )

    question = Enum.join(remaining, " ")

    if question == "" do
      Mix.shell().error("Usage: mix git.query \"question\" [--repo PATH] [--debug]")
      Mix.shell().error("\nExample: mix git.query \"Who contributed most this month?\"")
      System.halt(1)
    end

    repo_path = opts[:repo] || File.cwd!()
    repo_path = Path.expand(repo_path)

    Mix.shell().info("")
    Mix.shell().info("Git Query")
    Mix.shell().info("=========")
    Mix.shell().info("Question: #{question}")
    Mix.shell().info("Repository: #{repo_path}")

    # Show LLM info
    model = opts[:model] || LLMClient.default_model()
    Mix.shell().info("LLM: #{model}")

    # Quick LLM test
    case LLMClient.generate_text(model, [%{role: :user, content: "Say OK"}]) do
      {:ok, _} ->
        Mix.shell().info("LLM connection: OK\n")

      {:error, reason} ->
        Mix.shell().error("LLM connection failed: #{inspect(reason)}")
        System.halt(1)
    end

    query_opts = [
      repo: repo_path,
      debug: opts[:debug] || false,
      model: opts[:model]
    ]

    case GitQuery.query(question, query_opts) do
      {:ok, answer} ->
        Mix.shell().info("\nAnswer:")
        Mix.shell().info("-------")
        Mix.shell().info(answer)
        Mix.shell().info("")

      {:error, reason} ->
        Mix.shell().error("\nQuery failed!")
        Mix.shell().error(inspect(reason, pretty: true))
        System.halt(1)
    end
  end
end
