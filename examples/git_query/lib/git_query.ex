defmodule GitQuery do
  @moduledoc """
  Query git repositories with natural language questions.

  Demonstrates PtcRunner's two-agent composition pattern:
  1. Explorer (PTC-Lisp) - Decides tool strategy, combines/filters results
  2. Synthesizer (JSON) - Converts findings to natural language

  ## Example

      {:ok, answer} = GitQuery.query("Who contributed most this month?", repo: ".")
  """

  alias GitQuery.SubAgents
  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Debug

  @doc """
  Query a git repository with a natural language question.

  ## Options

  - `:repo` - Path to the git repository (default: current directory)
  - `:debug` - Enable debug output (default: false)
  - `:model` - LLM model to use

  ## Returns

  - `{:ok, answer}` - The natural language answer
  - `{:error, reason}` - Error description

  ## Examples

      {:ok, answer} = GitQuery.query("Who contributed most last month?")
      {:ok, answer} = GitQuery.query("What files changed the most?", repo: "/path/to/repo")
  """
  def query(question, opts \\ []) do
    repo_path = opts[:repo] || File.cwd!()
    repo_path = Path.expand(repo_path)
    debug = Keyword.get(opts, :debug, false)

    with :ok <- validate_repo(repo_path),
         llm <- build_llm(opts),
         {:ok, findings, summary} <- run_explorer(question, repo_path, llm, debug),
         {:ok, answer} <- run_synthesizer(question, findings, summary, llm, debug) do
      {:ok, answer}
    end
  end

  # --- Private functions ---

  defp validate_repo(repo_path) do
    git_dir = Path.join(repo_path, ".git")

    cond do
      !File.exists?(repo_path) ->
        {:error, "Repository path does not exist: #{repo_path}"}

      !File.exists?(git_dir) && !File.dir?(git_dir) ->
        {:error, "Not a git repository: #{repo_path}"}

      true ->
        :ok
    end
  end

  defp build_llm(opts) do
    model = opts[:model] || LLMClient.default_model()

    fn input ->
      messages = [%{role: :system, content: input.system} | input.messages]

      case LLMClient.generate_text(model, messages) do
        {:ok, response} ->
          {:ok, %{content: response.content, tokens: response.tokens}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp run_explorer(question, repo_path, llm, debug) do
    agent = SubAgents.explorer(repo_path)

    if debug, do: IO.puts("\n=== Explorer Agent ===")

    case SubAgent.run(agent, llm: llm, context: %{question: question}, debug: debug) do
      {:ok, step} ->
        if debug do
          Debug.print_trace(step, raw: true)
        end

        findings = step.return["findings"] || []
        summary = step.return["summary"]
        {:ok, findings, summary}

      {:error, step} ->
        if debug do
          IO.puts("Explorer failed: #{inspect(step.fail)}")
          Debug.print_trace(step, raw: true)
        end

        {:error, step.fail}
    end
  end

  defp run_synthesizer(question, findings, summary, llm, debug) do
    agent = SubAgents.synthesizer()

    if debug, do: IO.puts("\n=== Synthesizer Agent ===")

    # Convert findings to have string keys for Mustache template rendering
    # (findings from explorer already have string keys, but nested maps may need conversion)
    findings_for_template =
      Enum.map(findings, fn finding ->
        %{
          "type" => finding["type"],
          "data" => inspect(finding["data"])
        }
      end)

    context = %{
      question: question,
      findings: findings_for_template,
      summary: summary
    }

    case SubAgent.run(agent, llm: llm, context: context, debug: debug) do
      {:ok, step} ->
        if debug do
          Debug.print_trace(step, raw: true)
        end

        {:ok, step.return["answer"]}

      {:error, step} ->
        if debug do
          IO.puts("Synthesizer failed: #{inspect(step.fail)}")
          Debug.print_trace(step, raw: true)
        end

        {:error, step.fail}
    end
  end
end
