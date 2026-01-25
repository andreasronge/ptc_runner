defmodule GitQuery.Benchmark do
  @moduledoc """
  Benchmarking module for testing different pipeline configurations.

  Runs a set of test questions against all presets and reports results.
  """

  alias GitQuery.Config

  @questions [
    {"commits from last week", :simple},
    {"most active contributor this month", :simple},
    {"files changed by the top contributor", :complex},
    {"interesting commits from the most active contributor last week", :complex},
    {"commits from inactive contributor zzz_nonexistent_user", :empty_expected}
  ]

  @doc """
  Run benchmark with all presets and questions.

  ## Options

  - `:repo` - Repository path (default: current directory)
  - `:model` - LLM model to use
  - `:presets` - List of presets to test (default: all)
  - `:questions` - List of questions to test (default: all)

  ## Returns

  List of result maps with timing and status information.
  """
  @spec run(keyword()) :: [map()]
  def run(opts \\ []) do
    presets = opts[:presets] || Config.preset_names()
    questions = opts[:questions] || @questions

    for {question, expected_complexity} <- questions,
        preset <- presets do
      run_single(question, expected_complexity, preset, opts)
    end
  end

  @doc """
  Run benchmark with specific presets.

  ## Parameters

  - `presets` - List of preset names to test
  - `opts` - Options passed to GitQuery.query
  """
  @spec run([atom()], keyword()) :: [map()]
  def run(presets, opts) when is_list(presets) do
    run(Keyword.put(opts, :presets, presets))
  end

  @doc """
  Run benchmark with specific questions and presets.

  ## Parameters

  - `questions` - List of `{question, complexity}` tuples
  - `presets` - List of preset names to test
  - `opts` - Options passed to GitQuery.query
  """
  @spec run([{String.t(), atom()}], [atom()], keyword()) :: [map()]
  def run(questions, presets, opts) do
    opts
    |> Keyword.put(:presets, presets)
    |> Keyword.put(:questions, questions)
    |> run()
  end

  @doc """
  Format benchmark results as a readable table.
  """
  @spec format_results([map()]) :: String.t()
  def format_results(results) do
    # Group by question
    by_question = Enum.group_by(results, & &1.question)

    header = """
    Benchmark Results
    =================

    """

    rows =
      for {question, question_results} <- by_question do
        question_header = "Q: #{truncate(question, 60)}\n"

        preset_rows =
          for result <- Enum.sort_by(question_results, & &1.preset) do
            status_icon = status_icon(result.success, result.status)
            time_str = "#{result.time_ms}ms"

            "  #{pad(to_string(result.preset), 12)} #{status_icon} #{pad(time_str, 8)} #{result.summary || ""}\n"
          end

        question_header <> Enum.join(preset_rows) <> "\n"
      end

    header <> Enum.join(rows)
  end

  # Run a single question with a specific preset
  defp run_single(question, expected_complexity, preset, opts) do
    query_opts = [
      repo: opts[:repo] || File.cwd!(),
      preset: preset,
      model: opts[:model],
      debug: false
    ]

    IO.write(".")

    {time_us, result} =
      :timer.tc(fn ->
        try do
          GitQuery.query(question, query_opts)
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)

    %{
      question: question,
      expected: expected_complexity,
      preset: preset,
      time_ms: div(time_us, 1000),
      success: match?({:ok, _}, result),
      status: get_status(result),
      summary: get_summary(result)
    }
  end

  defp get_status({:ok, %{status: status}}), do: status
  defp get_status({:ok, _}), do: :ok
  defp get_status({:error, _}), do: :error

  defp get_summary({:ok, %{summary: summary}}) when is_binary(summary), do: truncate(summary, 40)
  defp get_summary(_), do: nil

  defp status_icon(true, :ok), do: "✓"
  defp status_icon(true, :empty), do: "∅"
  defp status_icon(true, _), do: "?"
  defp status_icon(false, _), do: "✗"

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max - 3) <> "..."

  defp pad(str, width) do
    padding = max(0, width - String.length(str))
    str <> String.duplicate(" ", padding)
  end
end
