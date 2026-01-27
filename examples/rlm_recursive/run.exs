# examples/rlm_recursive/run.exs
#
# Advanced RLM (Recursive Language Model) benchmarks with true recursive patterns.
#
# Key features:
# 1. Recursive self-calls via :self tool - LLM decides decomposition
# 2. Budget-aware decisions via (budget/remaining) introspection
# 3. Grep-based probing using stdlib grep and grep-n functions
# 4. Reproducible benchmarks with ground truth validation
#
# Usage:
#   mix run run.exs                          # Run S-NIAH benchmark (default)
#   mix run run.exs --trace                  # Run with hierarchical tracing
#   mix run run.exs --benchmark counting     # Run counting benchmark
#   mix run run.exs --lines 5000             # S-NIAH with 5000 lines
#   mix run run.exs --profiles 200           # Counting with 200 profiles
#   mix run run.exs --seed 123               # Custom random seed

defmodule RlmRecursive.Runner do
  @doc """
  Parse command line arguments.

  ## Supported Arguments

    * `--benchmark TYPE` - "sniah" or "counting" (default: sniah)
    * `--lines N` - Corpus size for S-NIAH (default: 1000)
    * `--profiles N` - Profile count for counting (default: 500)
    * `--seed N` - Random seed (default: 42)
    * `--trace` - Enable tracing
    * `--min-age N` - Min age for counting (default: 30)
    * `--hobby NAME` - Hobby for counting (default: "hiking")
    * `--help` - Show help message
  """
  def parse_args(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          benchmark: :string,
          lines: :integer,
          profiles: :integer,
          seed: :integer,
          trace: :boolean,
          min_age: :integer,
          hobby: :string,
          help: :boolean
        ],
        aliases: [
          b: :benchmark,
          l: :lines,
          p: :profiles,
          s: :seed,
          t: :trace,
          h: :help
        ]
      )

    opts
  end

  def run do
    args = System.argv()
    opts = parse_args(args)

    if Keyword.get(opts, :help, false) do
      print_help()
    else
      run_benchmark(opts)
    end
  end

  defp run_benchmark(opts) do
    benchmark =
      case Keyword.get(opts, :benchmark, "sniah") do
        "sniah" -> :sniah
        "counting" -> :counting
        "pairs" -> :pairs
        other -> raise "Unknown benchmark: #{other}. Use 'sniah', 'counting', or 'pairs'."
      end

    run_opts =
      opts
      |> Keyword.put(:benchmark, benchmark)
      |> Keyword.put_new(:lines, 1000)
      |> Keyword.put_new(:profiles, 500)
      |> Keyword.put_new(:seed, 42)
      |> Keyword.put_new(:trace, false)
      |> Keyword.put_new(:min_age, 30)
      |> Keyword.put_new(:hobby, "hiking")

    IO.puts("""

    ╔══════════════════════════════════════════════════════════════╗
    ║           RLM Recursive Benchmark Runner                     ║
    ╚══════════════════════════════════════════════════════════════╝

    Benchmark: #{benchmark}
    """)

    case benchmark do
      :sniah ->
        IO.puts("Lines: #{run_opts[:lines]}, Seed: #{run_opts[:seed]}")

      :counting ->
        IO.puts(
          "Profiles: #{run_opts[:profiles]}, Seed: #{run_opts[:seed]}, Age > #{run_opts[:min_age]}, Hobby: #{run_opts[:hobby]}"
        )

      :pairs ->
        IO.puts(
          "Profiles: #{run_opts[:profiles]}, Seed: #{run_opts[:seed]} (O(n^2) task - recursion essential!)"
        )
    end

    if run_opts[:trace], do: IO.puts("Tracing: enabled")

    IO.puts("")

    # Run the benchmark
    result = RlmRecursive.run(run_opts)

    # Summary
    IO.puts("""

    ════════════════════════════════════════════════════════════════
    Summary
    ════════════════════════════════════════════════════════════════
    Correct: #{result.score.correct}
    Expected: #{inspect(result.score.expected)}
    Actual: #{inspect(result.score.actual)}
    """)

    if result.trace_path do
      IO.puts("Trace: #{result.trace_path}")
      IO.puts("View: Open trace_viewer.html in browser and load the trace file")
    end
  end

  defp print_help do
    IO.puts("""

    RLM Recursive Benchmark Runner
    ==============================

    Usage:
      mix run run.exs [OPTIONS]

    Benchmarks:
      sniah     - Single Needle in a Haystack (find hidden fact) - O(1) with grep
      counting  - OOLONG-Counting (aggregate matching profiles) - O(n), direct filtering
      pairs     - OOLONG-Pairs (find matching pairs) - O(n^2), recursion essential!

    Options:
      --benchmark, -b TYPE    Benchmark type: sniah, counting, or pairs (default: sniah)
      --lines, -l N           Corpus lines for S-NIAH (default: 1000)
      --profiles, -p N        Profile count for counting/pairs (default: 500)
      --seed, -s N            Random seed for reproducibility (default: 42)
      --trace, -t             Enable hierarchical tracing
      --min-age N             Minimum age for counting (default: 30)
      --hobby NAME            Hobby to match for counting (default: hiking)
      --help, -h              Show this help message

    Examples:
      # Run S-NIAH with default settings
      mix run run.exs

      # Run with tracing
      mix run run.exs --trace

      # Run counting benchmark with 200 profiles
      mix run run.exs --benchmark counting --profiles 200

      # Run pairs benchmark (demonstrates essential recursion)
      mix run run.exs --benchmark pairs --profiles 100 --trace

      # Run S-NIAH with larger corpus
      mix run run.exs --lines 10000 --seed 123

    Environment:
      AWS_PROFILE=sandbox    Use AWS credentials from sandbox profile
      OPENROUTER_API_KEY     Use OpenRouter instead of AWS Bedrock

    Trace Viewer:
      After running with --trace, open trace_viewer.html in your browser
      and load the generated trace file from traces/

    """)
  end
end

RlmRecursive.Runner.run()
