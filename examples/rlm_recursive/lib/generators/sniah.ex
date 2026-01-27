defmodule RlmRecursive.Generators.SNIAH do
  @moduledoc """
  Generator for S-NIAH (Single Needle in a Haystack) benchmark corpus.

  Creates a large corpus with a single hidden fact (the "needle") that must be found.
  Uses deterministic seeded randomness for reproducible benchmarks.

  ## Example

      iex> result = RlmRecursive.Generators.SNIAH.generate(lines: 1000, seed: 42)
      iex> String.contains?(result.corpus, result.ground_truth.code)
      true

  """

  @default_lines 10_000
  @default_seed 42

  @doc """
  Generate a S-NIAH corpus with a single hidden fact.

  ## Options

    * `:lines` - Number of lines in the corpus (default: #{@default_lines})
    * `:seed` - Random seed for reproducibility (default: #{@default_seed})
    * `:agent_id` - Agent ID to hide (default: generated from seed)
    * `:code` - Access code to hide (default: generated from seed)

  ## Returns

  A map with:
    * `:corpus` - The generated corpus as a string
    * `:ground_truth` - Map with `:agent`, `:code` keys
    * `:position` - Line number (1-indexed) where the needle is hidden
    * `:total_lines` - Total lines in the corpus
  """
  def generate(opts \\ []) do
    lines = Keyword.get(opts, :lines, @default_lines)
    seed = Keyword.get(opts, :seed, @default_seed)

    # Seed the random number generator for reproducibility
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    # Generate or use provided agent/code
    agent_id = Keyword.get_lazy(opts, :agent_id, fn -> generate_agent_id() end)
    code = Keyword.get_lazy(opts, :code, fn -> generate_code() end)

    # Generate the needle line
    needle = "The access code for #{agent_id} is #{code}"

    # Position the needle (avoid first/last 5% for realism)
    min_pos = max(1, div(lines, 20))
    max_pos = lines - min_pos
    position = :rand.uniform(max_pos - min_pos + 1) + min_pos - 1

    # Generate corpus lines
    corpus_lines =
      Enum.map(1..lines, fn line_num ->
        if line_num == position do
          needle
        else
          generate_haystack_line(line_num)
        end
      end)

    %{
      corpus: Enum.join(corpus_lines, "\n"),
      ground_truth: %{agent: agent_id, code: code},
      position: position,
      total_lines: lines
    }
  end

  @doc """
  Generate just a question for the S-NIAH task.
  """
  def question(%{ground_truth: %{agent: agent_id}}) do
    "What is the access code for #{agent_id}?"
  end

  # Generate a realistic agent ID like "agent_7291"
  defp generate_agent_id do
    "agent_#{:rand.uniform(9999)}"
  end

  # Generate a 6-character uppercase code like "XKQMTR"
  defp generate_code do
    for _ <- 1..6, into: "" do
      <<Enum.random(?A..?Z)>>
    end
  end

  # Generate a realistic-looking log/data line that doesn't contain the needle
  defp generate_haystack_line(line_num) do
    type = Enum.random([:log, :config, :data, :comment, :json])
    generate_line_by_type(type, line_num)
  end

  defp generate_line_by_type(:log, line_num) do
    timestamp = generate_timestamp()
    level = Enum.random(["INFO", "DEBUG", "TRACE", "WARN"])
    component = Enum.random(["system", "network", "cache", "auth", "db", "api"])
    message = generate_log_message()
    "[#{timestamp}] [#{level}] [#{component}] [line:#{line_num}] #{message}"
  end

  defp generate_line_by_type(:config, _line_num) do
    key = Enum.random(["timeout", "retry_count", "buffer_size", "max_connections", "poll_interval"])
    value = :rand.uniform(10000)
    "#{key} = #{value}"
  end

  defp generate_line_by_type(:data, _line_num) do
    id = :rand.uniform(999_999)
    status = Enum.random(["active", "pending", "completed", "archived"])
    "record_#{id}: status=#{status}, updated=#{generate_timestamp()}"
  end

  defp generate_line_by_type(:comment, _line_num) do
    comments = [
      "# Configuration section",
      "# TODO: Review this section",
      "# Last updated by system",
      "# Maintenance window entry",
      "# Scheduled job output"
    ]

    Enum.random(comments)
  end

  defp generate_line_by_type(:json, _line_num) do
    ~s|{"event_id": #{:rand.uniform(99999)}, "type": "#{Enum.random(["click", "view", "submit", "load"])}", "ts": #{System.system_time(:second)}}|
  end

  defp generate_timestamp do
    # Generate a random timestamp within the last month
    base = ~N[2024-01-01 00:00:00]

    NaiveDateTime.add(base, :rand.uniform(30 * 24 * 3600), :second)
    |> NaiveDateTime.to_string()
  end

  defp generate_log_message do
    messages = [
      "Processing request completed",
      "Connection established successfully",
      "Cache hit for key",
      "Background job scheduled",
      "Health check passed",
      "Metrics collected",
      "Session validated",
      "Rate limit check passed",
      "Query executed in #{:rand.uniform(500)}ms",
      "Batch processing started"
    ]

    Enum.random(messages)
  end
end
