defmodule RlmRecursive.Scorer do
  @moduledoc """
  Ground truth validation for RLM benchmarks.

  Scores agent results against known correct answers for reproducible evaluation.
  """

  @doc """
  Score a S-NIAH result against ground truth.

  ## Arguments

    * `result` - The agent's return value (map with "answer" or "code" key)
    * `ground_truth` - Map with `:code` key containing the expected answer

  ## Returns

  A map with:
    * `:correct` - Boolean indicating exact match
    * `:expected` - The expected answer
    * `:actual` - What the agent returned
    * `:partial` - Boolean if partial match (answer contains expected)
  """
  def score(:sniah, result, %{code: expected_code} = _ground_truth) do
    actual = extract_answer(result)

    # Check for exact match (case-insensitive for codes)
    exact_match = normalize(actual) == normalize(expected_code)

    # Check for partial match (the code appears somewhere in the answer)
    partial_match = actual != nil and String.contains?(to_string(actual), expected_code)

    %{
      correct: exact_match,
      expected: expected_code,
      actual: actual,
      partial: partial_match and not exact_match
    }
  end

  @doc """
  Score an OOLONG-Counting result against ground truth.

  ## Arguments

    * `result` - The agent's return value (map with "count" key)
    * `ground_truth` - Map with `:count` key containing the expected count

  ## Options

    * `:tolerance` - Allowed error margin as percentage (default: 0.0 for exact match)

  ## Returns

  A map with:
    * `:correct` - Boolean indicating match within tolerance
    * `:expected` - The expected count
    * `:actual` - What the agent returned
    * `:error` - Absolute error (actual - expected)
    * `:error_pct` - Error as percentage of expected
  """
  def score(:counting, result, %{count: expected_count} = _ground_truth, opts \\ []) do
    tolerance = Keyword.get(opts, :tolerance, 0.0)
    actual = extract_count(result)

    case actual do
      nil ->
        %{
          correct: false,
          expected: expected_count,
          actual: nil,
          error: nil,
          error_pct: nil
        }

      count when is_integer(count) ->
        error = count - expected_count
        error_pct = if expected_count > 0, do: abs(error) / expected_count * 100, else: 0.0

        %{
          correct: error_pct <= tolerance,
          expected: expected_count,
          actual: count,
          error: error,
          error_pct: Float.round(error_pct, 2)
        }
    end
  end

  @doc """
  Pretty print a score result.
  """
  def format_score(%{correct: correct, expected: expected, actual: actual} = score) do
    status = if correct, do: "PASS", else: "FAIL"
    base = "[#{status}] Expected: #{inspect(expected)}, Actual: #{inspect(actual)}"

    cond do
      Map.has_key?(score, :partial) and score.partial ->
        base <> " (partial match)"

      Map.has_key?(score, :error_pct) and score.error_pct != nil ->
        base <> " (error: #{score.error_pct}%)"

      true ->
        base
    end
  end

  # Extract the answer from various result formats
  defp extract_answer(nil), do: nil

  defp extract_answer(result) when is_map(result) do
    # Try common keys in order of preference
    cond do
      Map.has_key?(result, "code") -> result["code"]
      Map.has_key?(result, "answer") -> result["answer"]
      Map.has_key?(result, :code) -> result[:code]
      Map.has_key?(result, :answer) -> result[:answer]
      true -> nil
    end
  end

  defp extract_answer(result) when is_binary(result), do: result
  defp extract_answer(_), do: nil

  # Extract count from result
  defp extract_count(nil), do: nil

  defp extract_count(result) when is_map(result) do
    cond do
      Map.has_key?(result, "count") -> to_integer(result["count"])
      Map.has_key?(result, :count) -> to_integer(result[:count])
      Map.has_key?(result, "total") -> to_integer(result["total"])
      Map.has_key?(result, :total) -> to_integer(result[:total])
      true -> nil
    end
  end

  defp extract_count(result) when is_integer(result), do: result
  defp extract_count(_), do: nil

  defp to_integer(n) when is_integer(n), do: n
  defp to_integer(n) when is_float(n), do: round(n)
  defp to_integer(s) when is_binary(s), do: String.to_integer(s)
  defp to_integer(_), do: nil

  # Normalize strings for comparison (trim whitespace, uppercase)
  defp normalize(nil), do: nil

  defp normalize(s) when is_binary(s) do
    s |> String.trim() |> String.upcase()
  end

  defp normalize(other), do: to_string(other) |> normalize()
end
