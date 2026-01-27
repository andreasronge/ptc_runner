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
  Score an OOLONG-Counting or OOLONG-Pairs result against ground truth.

  ## Counting (`:counting`)

  Expects `result` with `"count"` key and `ground_truth` with `:count`.
  Default tolerance: 0.0 (exact match).

  ## Pairs (`:pairs`)

  Expects `result` with `"count"` and optional `"pairs"` keys.
  Expects `ground_truth` with `:count` and `:pairs`.
  Default tolerance: 5.0% (some pairs may be missed at recursion boundaries).

  ## Options

    * `:tolerance` - Allowed error margin as percentage

  ## Returns

  A map with `:correct`, `:expected`, `:actual`, `:error`, `:error_pct`.
  Pairs also includes `:sample_match` and `:sample_pairs`.
  """
  def score(type, result, ground_truth, opts \\ [])

  def score(:counting, result, %{count: expected_count} = _ground_truth, opts) do
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

  def score(
        :pairs,
        result,
        %{count: expected_count, pairs: expected_pairs} = _ground_truth,
        opts
      ) do
    # Allow 5% tolerance for pairs (some may be missed due to recursion boundaries)
    tolerance = Keyword.get(opts, :tolerance, 5.0)
    actual_count = extract_count(result)
    actual_pairs = extract_pairs(result)

    case actual_count do
      nil ->
        %{
          correct: false,
          expected: expected_count,
          actual: nil,
          error: nil,
          error_pct: nil,
          sample_match: false
        }

      count when is_integer(count) ->
        error = count - expected_count
        error_pct = if expected_count > 0, do: abs(error) / expected_count * 100, else: 0.0

        # Check if returned pairs are valid (subset of ground truth)
        expected_set = MapSet.new(Enum.map(expected_pairs, fn {a, b} -> "#{a}-#{b}" end))
        actual_set = MapSet.new(actual_pairs || [])
        sample_match = MapSet.subset?(actual_set, expected_set) or MapSet.size(actual_set) == 0

        %{
          correct: error_pct <= tolerance,
          expected: expected_count,
          actual: count,
          error: error,
          error_pct: Float.round(error_pct, 2),
          sample_match: sample_match,
          sample_pairs: Enum.take(actual_pairs || [], 5)
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

  # Extract pairs from result
  defp extract_pairs(nil), do: nil

  defp extract_pairs(result) when is_map(result) do
    cond do
      Map.has_key?(result, "pairs") -> result["pairs"]
      Map.has_key?(result, :pairs) -> result[:pairs]
      true -> nil
    end
  end

  defp extract_pairs(_), do: nil
end
