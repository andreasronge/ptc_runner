# examples/rlm/run.exs

# RLM (Recursive Language Model) pattern using real LLMs.
#
# Key features in this example:
# 1. Token-based chunking with overlap - handles variable line lengths and boundary incidents
# 2. Simple worker agent - just analyzes a chunk, no recursive subdivision
# 3. Operator-level budget control via token_limit
#
# The planner (Sonnet) orchestrates, workers (Haiku) process chunks in parallel.

defmodule RLM.Runner do
  alias PtcRunner.SubAgent
  alias PtcRunner.Chunker

  # Token-based chunking is safer than line-based for LLM context limits.
  # Log lines vary wildly in length - a JSON blob could be 10KB on one line.
  @tokens_per_chunk 4000
  # Overlap ensures incidents spanning chunk boundaries aren't missed (e.g., stack traces).
  # The final `distinct` handles any duplicates from the overlap.
  @overlap_tokens 200

  def run do
    load_aws_credentials_if_needed()

    # 1. Load and pre-chunk the corpus in Elixir
    corpus = load_corpus()
    chunks = Chunker.by_tokens(corpus, @tokens_per_chunk, overlap: @overlap_tokens)

    IO.puts(
      "Corpus: #{count_lines(corpus)} lines -> #{length(chunks)} chunks of ~#{@tokens_per_chunk} tokens (#{@overlap_tokens} overlap)"
    )

    # 2. Define a simple Worker Agent
    # No recursion needed - chunks are pre-sized in Elixir
    worker_agent =
      SubAgent.new(
        prompt: """
        Analyze the log chunk in data/chunk for CRITICAL or ERROR incidents.
        Extract and return a list of incident descriptions found.
        If no incidents are found, return an empty list.
        """,
        signature: "(chunk :string) -> {incidents [:string]}",
        description: "Analyze a log chunk for CRITICAL/ERROR incidents.",
        max_turns: 5,
        llm: LLMClient.callback("bedrock:haiku")
      )

    worker_tool = SubAgent.as_tool(worker_agent)

    # 3. Run the Planner with pre-chunked data
    IO.puts("\n=== Starting RLM Orchestration (Sonnet -> Haiku) ===\n")

    planner_prompt = """
    Audit the system logs for incidents.

    The corpus has been pre-chunked into data/chunks (a list of #{length(chunks)} chunks).
    Use 'pmap' with the 'worker' tool to analyze all chunks in parallel.
    Aggregate results: return total incident count and first 10 unique incidents.
    """

    run_opts = [
      context: %{"chunks" => chunks},
      tools: %{"worker" => worker_tool},
      llm: LLMClient.callback("bedrock:sonnet"),
      max_turns: 5,
      max_heap: 20_000_000,
      # LLM-backed tool calls need longer timeout (each Haiku call ~5-15s)
      # pmap runs in parallel, so timeout needs to cover the slowest worker
      timeout: 120_000,
      # pmap_timeout: per-task timeout for parallel tool calls (default: 5s)
      # LLM-backed workers need 30-60s each
      pmap_timeout: 60_000,
      # Operator-level budget control
      token_limit: 200_000,
      on_budget_exceeded: :return_partial
    ]

    case SubAgent.run(planner_prompt, run_opts) do
      {:ok, step} ->
        print_success(step)

      {:error, step} ->
        print_failure(step)
    end
  end

  defp load_corpus do
    corpus_path = "examples/rlm/test_corpus.log"

    unless File.exists?(corpus_path) do
      IO.puts("Generating 10,000 line corpus...")
      System.put_env("N_LINES", "10000")
      Code.require_file("examples/rlm/gen_data.exs")
    end

    File.read!(corpus_path)
  end

  defp count_lines(text), do: length(String.split(text, "\n"))

  defp print_success(step) do
    IO.puts("\n=== RLM Audit Complete ===")
    IO.inspect(step.return, pretty: true)

    # Show detailed execution trace with usage and tool call stats
    SubAgent.Debug.print_trace(step, usage: true)

    if step.prints != [], do: IO.puts("\nLogs:\n#{Enum.join(step.prints, "")}")
  end

  defp print_failure(step) do
    IO.puts("\n=== RLM Audit Failed ===")
    IO.inspect(step.fail)

    # Show trace even on failure - helps debug what went wrong
    SubAgent.Debug.print_trace(step, usage: true, raw: true)
  end

  defp load_aws_credentials_if_needed do
    if System.get_env("AWS_PROFILE") == "sandbox" and is_nil(System.get_env("AWS_ACCESS_KEY_ID")) do
      IO.puts("Loading AWS credentials from profile 'sandbox'...")

      {output, 0} =
        System.cmd("aws", [
          "configure",
          "export-credentials",
          "--profile",
          "sandbox",
          "--format",
          "env"
        ])

      output
      |> String.split("\n")
      |> Enum.each(fn line ->
        case Regex.run(
               ~r/export (AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN)=(.+)/,
               line
             ) do
          [_, key, value] -> System.put_env(key, value)
          _ -> :ok
        end
      end)

      System.put_env("AWS_REGION", "eu-west-1")
    end
  end
end

RLM.Runner.run()
