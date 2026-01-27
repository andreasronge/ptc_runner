defmodule RlmRecursive do
  @moduledoc """
  Advanced RLM (Recursive Language Model) benchmarks demonstrating true recursive patterns.

  This example showcases:
  - Recursive self-calls via `:self` tool
  - LLM-decided chunking (not pre-chunked)
  - Budget-aware decisions using `(budget/remaining)`
  - Grep-based probing using stdlib `grep` and `grep-n` functions
  - Reproducible benchmarks with ground truth validation

  ## Benchmarks

  ### S-NIAH (Single Needle in a Haystack)
  Find one hidden fact in a large corpus. The LLM uses grep-based probing
  to efficiently locate the needle without scanning the entire haystack.

  ### OOLONG-Counting
  Count entities matching criteria using recursive map-reduce aggregation.

  ## Usage

      # Run S-NIAH benchmark
      RlmRecursive.run(benchmark: :sniah, lines: 1000)

      # Run counting benchmark
      RlmRecursive.run(benchmark: :counting, profiles: 500)

  ## See Also

  - `examples/rlm/` - Simpler RLM example with pre-chunking
  - `docs/guides/subagent-rlm-patterns.md` - RLM pattern documentation
  """

  alias PtcRunner.SubAgent
  alias PtcRunner.TraceLog
  alias RlmRecursive.{Agent, Scorer}
  alias RlmRecursive.Generators.{SNIAH, Counting, Pairs, SemanticPairs}

  @doc """
  Run a benchmark with the specified options.

  ## Options

    * `:benchmark` - `:sniah`, `:counting`, `:pairs`, or `:semantic_pairs` (default: `:sniah`)
    * `:lines` - Corpus size for S-NIAH (default: 1000)
    * `:profiles` - Number of profiles for counting/pairs (default: 500)
    * `:seed` - Random seed for reproducibility (default: 42)
    * `:trace` - Enable tracing (default: false)
    * `:llm` - LLM callback (default: bedrock:sonnet)
    * `:verbose` - Print detailed output (default: true)

  ## Returns

  A map with:
    * `:result` - The SubAgent step result
    * `:score` - Ground truth validation score
    * `:trace_path` - Path to trace file (if tracing enabled)
  """
  def run(opts \\ []) do
    benchmark = Keyword.get(opts, :benchmark, :sniah)
    run_benchmark(benchmark, opts)
  end

  @doc """
  Run a specific benchmark type.

  ## Arguments

    * `type` - `:sniah` or `:counting`
    * `opts` - Options (see `run/1` for available options)
  """
  def run_benchmark(:sniah, opts) do
    lines = Keyword.get(opts, :lines, 1000)
    seed = Keyword.get(opts, :seed, 42)
    trace? = Keyword.get(opts, :trace, false)
    verbose? = Keyword.get(opts, :verbose, true)

    llm =
      Keyword.get_lazy(opts, :llm, fn ->
        load_aws_credentials_if_needed()
        LLMClient.callback("bedrock:sonnet")
      end)

    # Generate corpus with ground truth
    if verbose?, do: IO.puts("Generating S-NIAH corpus (#{lines} lines, seed #{seed})...")
    data = SNIAH.generate(lines: lines, seed: seed)
    query = SNIAH.question(data)

    if verbose? do
      IO.puts("Needle hidden at line #{data.position} of #{data.total_lines}")
      IO.puts("Query: #{query}")
      IO.puts("\n=== Starting S-NIAH Benchmark ===\n")
    end

    # Create recursive agent
    agent = Agent.new(:sniah, llm: llm)

    # Run with tracing if requested
    # pmap_timeout must be long enough for recursive LLM calls (30-60s each)
    run_opts = [
      context: %{"corpus" => data.corpus, "query" => query},
      llm: llm,
      max_turns: 15,
      timeout: 120_000,
      pmap_timeout: 60_000,
      token_limit: 100_000,
      on_budget_exceeded: :return_partial
    ]

    {result, trace_path} = execute_with_tracing(agent, run_opts, trace?)

    # Score the result
    score =
      case result do
        {:ok, step} -> Scorer.score(:sniah, step.return, data.ground_truth)
        {:error, _} -> %{correct: false, expected: data.ground_truth.code, actual: nil}
      end

    if verbose?, do: print_result(result, score, trace_path)

    %{result: result, score: score, trace_path: trace_path, data: data}
  end

  def run_benchmark(:counting, opts) do
    profiles = Keyword.get(opts, :profiles, 500)
    seed = Keyword.get(opts, :seed, 42)
    trace? = Keyword.get(opts, :trace, false)
    verbose? = Keyword.get(opts, :verbose, true)
    min_age = Keyword.get(opts, :min_age, 30)
    hobby = Keyword.get(opts, :hobby, "hiking")

    llm =
      Keyword.get_lazy(opts, :llm, fn ->
        load_aws_credentials_if_needed()
        LLMClient.callback("bedrock:sonnet")
      end)

    # Generate corpus with ground truth
    if verbose?,
      do: IO.puts("Generating counting corpus (#{profiles} profiles, seed #{seed})...")

    data = Counting.generate(profiles: profiles, seed: seed, min_age: min_age, hobby: hobby)

    if verbose? do
      IO.puts("Expected count: #{data.ground_truth.count}")
      IO.puts("Query: #{data.query}")
      IO.puts("\n=== Starting Counting Benchmark ===\n")
    end

    # Create recursive agent
    agent = Agent.new(:counting, llm: llm)

    # Run with tracing if requested
    # Large heap: RLM keeps bulk data in memory, not LLM context
    # The computer can filter 100K+ items easily - that's the point!
    run_opts = [
      context: %{"corpus" => data.corpus, "min_age" => min_age, "hobby" => hobby},
      llm: llm,
      max_turns: 20,
      timeout: 180_000,
      pmap_timeout: 60_000,
      max_heap: 200_000_000,
      token_limit: 150_000,
      on_budget_exceeded: :return_partial
    ]

    {result, trace_path} = execute_with_tracing(agent, run_opts, trace?)

    # Score the result
    score =
      case result do
        {:ok, step} -> Scorer.score(:counting, step.return, data.ground_truth)
        {:error, _} -> %{correct: false, expected: data.ground_truth.count, actual: nil}
      end

    if verbose?, do: print_result(result, score, trace_path)

    %{result: result, score: score, trace_path: trace_path, data: data}
  end

  def run_benchmark(:pairs, opts) do
    profiles = Keyword.get(opts, :profiles, 100)
    seed = Keyword.get(opts, :seed, 42)
    trace? = Keyword.get(opts, :trace, false)
    verbose? = Keyword.get(opts, :verbose, true)

    llm =
      Keyword.get_lazy(opts, :llm, fn ->
        load_aws_credentials_if_needed()
        LLMClient.callback("bedrock:sonnet")
      end)

    # Generate corpus with ground truth
    if verbose?,
      do: IO.puts("Generating pairs corpus (#{profiles} profiles, seed #{seed})...")

    data = Pairs.generate(profiles: profiles, seed: seed)

    if verbose? do
      IO.puts("Expected pairs: #{data.ground_truth.count}")
      IO.puts("Query: #{data.query}")
      IO.puts("\n=== Starting Pairs Benchmark (O(n²) - recursion essential!) ===\n")
    end

    # Create recursive agent
    agent = Agent.new(:pairs, llm: llm)

    # Run with tracing if requested
    # O(n²) task needs more resources
    run_opts = [
      context: %{"corpus" => data.corpus},
      llm: llm,
      max_turns: 25,
      timeout: 300_000,
      pmap_timeout: 90_000,
      max_heap: 200_000_000,
      token_limit: 200_000,
      on_budget_exceeded: :return_partial
    ]

    {result, trace_path} = execute_with_tracing(agent, run_opts, trace?)

    # Score the result
    score =
      case result do
        {:ok, step} -> Scorer.score(:pairs, step.return, data.ground_truth)
        {:error, _} -> %{correct: false, expected: data.ground_truth.count, actual: nil}
      end

    if verbose?, do: print_result(result, score, trace_path)

    %{result: result, score: score, trace_path: trace_path, data: data}
  end

  def run_benchmark(:semantic_pairs, opts) do
    profiles = Keyword.get(opts, :profiles, 40)
    seed = Keyword.get(opts, :seed, 42)
    trace? = Keyword.get(opts, :trace, false)
    verbose? = Keyword.get(opts, :verbose, true)

    llm =
      Keyword.get_lazy(opts, :llm, fn ->
        load_aws_credentials_if_needed()
        LLMClient.callback("bedrock:sonnet")
      end)

    if verbose?,
      do: IO.puts("Generating semantic pairs corpus (#{profiles} profiles, seed #{seed})...")

    data = SemanticPairs.generate(profiles: profiles, seed: seed)

    if verbose? do
      IO.puts("Expected pairs: #{data.ground_truth.count}")
      IO.puts("Query: #{String.slice(data.query, 0, 100)}...")
      IO.puts("\n=== Starting Semantic Pairs Benchmark (LLM judgment per pair!) ===\n")
    end

    agent = Agent.new(:semantic_pairs, llm: llm)

    # Semantic evaluation needs more resources
    run_opts = [
      context: %{"corpus" => data.corpus},
      llm: llm,
      max_turns: 30,
      timeout: 600_000,
      pmap_timeout: 120_000,
      max_heap: 200_000_000,
      token_limit: 300_000,
      on_budget_exceeded: :return_partial
    ]

    {result, trace_path} = execute_with_tracing(agent, run_opts, trace?)

    score =
      case result do
        {:ok, step} -> Scorer.score(:pairs, step.return, data.ground_truth)
        {:error, _} -> %{correct: false, expected: data.ground_truth.count, actual: nil}
      end

    if verbose?, do: print_result(result, score, trace_path)

    %{result: result, score: score, trace_path: trace_path, data: data}
  end

  # Execute with optional tracing
  defp execute_with_tracing(agent, opts, false) do
    {SubAgent.run(agent, opts), nil}
  end

  defp execute_with_tracing(agent, opts, true) do
    trace_path = Path.join(base_dir(), "traces/recursive_trace.jsonl")
    File.mkdir_p!(Path.dirname(trace_path))

    {:ok, result, path} =
      TraceLog.with_trace(
        fn -> SubAgent.run(agent, opts) end,
        path: trace_path
      )

    {result, path}
  end

  defp print_result({:ok, step}, score, trace_path) do
    IO.puts("\n=== Benchmark Complete ===")
    IO.puts(Scorer.format_score(score))
    IO.puts("\nReturn value:")
    IO.inspect(step.return, pretty: true)

    # Show execution trace
    SubAgent.Debug.print_trace(step, usage: true)

    if trace_path do
      IO.puts("\nTrace file: #{trace_path}")
      print_trace_tree(trace_path, step)
    end

    if step.prints != [], do: IO.puts("\nLogs:\n#{Enum.join(step.prints, "")}")
  end

  defp print_result({:error, step}, score, trace_path) do
    IO.puts("\n=== Benchmark Failed ===")
    IO.puts(Scorer.format_score(score))
    IO.puts("\nError:")
    IO.inspect(step.fail, pretty: true)

    SubAgent.Debug.print_trace(step, usage: true, raw: true)

    if trace_path, do: IO.puts("\nTrace file: #{trace_path}")
  end

  defp print_trace_tree(trace_path, step) do
    alias PtcRunner.TraceLog.Analyzer

    IO.puts("\nChild traces: #{length(step.child_traces)}")

    case Analyzer.load_tree(trace_path) do
      {:ok, tree} ->
        IO.puts("\nExecution tree:")
        Analyzer.print_tree(tree)

      {:error, reason} ->
        IO.puts("Could not load trace tree: #{inspect(reason)}")
    end
  end

  defp base_dir do
    cwd = File.cwd!()

    if String.ends_with?(cwd, "examples/rlm_recursive") do
      "."
    else
      "examples/rlm_recursive"
    end
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
