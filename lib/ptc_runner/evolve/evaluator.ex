defmodule PtcRunner.Evolve.Evaluator do
  @moduledoc """
  Evaluates PTC-Lisp programs against problems with output matching.

  Runs programs in the sandbox, compares output to expected values,
  and computes fitness with LLM cost and program size penalties.
  """

  alias PtcRunner.Evolve.Individual
  alias PtcRunner.Lisp

  @type problem :: %{
          source: String.t(),
          expected_output: term(),
          output_type: :integer | :number | :string | :list | :map,
          context: map()
        }

  @type eval_result :: %{
          correct: boolean(),
          llm_tokens: non_neg_integer(),
          output: term(),
          error: term() | nil,
          duration_ms: non_neg_integer()
        }

  @type config :: %{
          lambda_llm: float(),
          lambda_size: float(),
          timeout: pos_integer(),
          max_heap: pos_integer()
        }

  @default_config %{
    lambda_llm: 0.01,
    lambda_size: 0.005,
    timeout: 1000,
    max_heap: 1_250_000
  }

  @doc """
  Evaluate an individual against a single problem.

  Runs the individual's source code in the sandbox with the problem's context,
  then compares the output to the expected value.
  """
  @spec evaluate(Individual.t(), problem(), config()) :: eval_result()
  def evaluate(%Individual{source: source}, problem, config \\ @default_config) do
    result =
      Lisp.run(source,
        context: problem.context,
        tools: Map.get(problem, :tools, %{}),
        timeout: config.timeout,
        max_heap: config.max_heap
      )

    case result do
      {:ok, step} ->
        correct = matches_output?(step.return, problem.expected_output, problem.output_type)
        llm_tokens = get_in(step.usage || %{}, [:total_tokens]) || 0

        %{
          correct: correct,
          llm_tokens: llm_tokens,
          output: step.return,
          error: nil,
          duration_ms: Map.get(step.usage || %{}, :duration_ms, 0)
        }

      {:error, step} ->
        llm_tokens = get_in(step.usage || %{}, [:total_tokens]) || 0

        %{
          correct: false,
          llm_tokens: llm_tokens,
          output: nil,
          error: step.fail,
          duration_ms: Map.get(step.usage || %{}, :duration_ms, 0)
        }
    end
  end

  @doc """
  Compute fitness for an individual given its evaluation result and problem.

  fitness = partial_score - lambda_llm * llm_tokens / 1000 - lambda_size * program_size / 100

  Uses graded partial credit instead of binary correctness to provide
  gradient signal when no program produces the exact answer.
  """
  @spec fitness(Individual.t(), eval_result(), Evaluator.problem(), config()) :: float()
  def fitness(%Individual{program_size: size}, eval_result, problem, config \\ @default_config) do
    score = partial_score(eval_result, problem)

    score -
      config.lambda_llm * eval_result.llm_tokens / 1000 -
      config.lambda_size * size / 100
  end

  @doc """
  Compute partial credit score for an evaluation result.

  Scoring ladder:
  - 1.0: exact match (within tolerance for numbers)
  - 0.5-0.9: right type, partially correct value
  - 0.1-0.3: right type but wrong value
  - 0.05: produced a value (wrong type, no crash)
  - 0.0: crash/timeout/nil
  """
  @spec partial_score(eval_result(), Evaluator.problem()) :: float()
  def partial_score(%{correct: true}, _problem), do: 1.0
  def partial_score(%{error: err}, _problem) when err != nil, do: 0.0
  def partial_score(%{output: nil}, _problem), do: 0.0

  def partial_score(%{output: actual}, %{expected_output: expected, output_type: type}) do
    if same_type?(actual, type) do
      type_score(actual, expected, type)
    else
      0.05
    end
  end

  defp same_type?(x, :integer) when is_integer(x), do: true
  defp same_type?(x, :number) when is_number(x), do: true
  defp same_type?(x, :string) when is_binary(x), do: true
  defp same_type?(x, :list) when is_list(x), do: true
  defp same_type?(x, :map) when is_map(x), do: true
  defp same_type?(_, _), do: false

  # Score for integer: closer = higher (log scale for large ranges)
  defp type_score(actual, expected, :integer) when is_integer(actual) and is_integer(expected) do
    if expected == 0 do
      if actual == 0, do: 1.0, else: 0.2
    else
      ratio = abs(actual - expected) / max(abs(expected), 1)
      # 0.2 base for right type, up to 0.9 for very close
      0.2 + 0.7 * max(0.0, 1.0 - ratio)
    end
  end

  # Score for number: relative closeness
  defp type_score(actual, expected, :number) when is_number(actual) and is_number(expected) do
    if expected == 0 do
      if abs(actual) < 1.0, do: 0.8, else: 0.2
    else
      ratio = abs(actual - expected) / abs(expected)
      0.2 + 0.7 * max(0.0, 1.0 - ratio)
    end
  end

  # Score for string: character-level similarity
  defp type_score(actual, expected, :string) when is_binary(actual) and is_binary(expected) do
    if actual == expected do
      1.0
    else
      # Simple: shared prefix ratio
      max_len = max(byte_size(actual), byte_size(expected))
      if max_len == 0, do: 1.0, else: 0.2 + 0.5 * (shared_prefix_len(actual, expected) / max_len)
    end
  end

  # Score for list: length match + element overlap
  defp type_score(actual, expected, :list) when is_list(actual) and is_list(expected) do
    if expected == [] do
      if actual == [], do: 1.0, else: 0.2
    else
      len_score = 1.0 - min(abs(length(actual) - length(expected)) / length(expected), 1.0)
      0.2 + 0.7 * len_score
    end
  end

  # Score for map: key overlap + value similarity
  defp type_score(actual, expected, :map) when is_map(actual) and is_map(expected) do
    if expected == %{} do
      if actual == %{}, do: 1.0, else: 0.2
    else
      expected_keys = Map.keys(expected) |> MapSet.new()
      actual_keys = Map.keys(actual) |> MapSet.new()
      common = MapSet.intersection(expected_keys, actual_keys) |> MapSet.size()
      total = MapSet.union(expected_keys, actual_keys) |> MapSet.size()
      key_overlap = if total == 0, do: 0.0, else: common / total

      # Value similarity for common keys
      value_score =
        if common == 0 do
          0.0
        else
          common_keys = MapSet.intersection(expected_keys, actual_keys) |> MapSet.to_list()

          scores =
            Enum.map(common_keys, fn k ->
              value_similarity(Map.get(actual, k), Map.get(expected, k))
            end)

          Enum.sum(scores) / length(scores)
        end

      # 0.2 base for right type, 0.4 for key structure, 0.3 for values
      0.2 + 0.4 * key_overlap + 0.3 * value_score
    end
  end

  defp type_score(_, _, _), do: 0.1

  defp value_similarity(a, b) when is_number(a) and is_number(b) do
    if b == 0,
      do: if(abs(a) < 1.0, do: 0.8, else: 0.2),
      else: max(0.0, 1.0 - abs(a - b) / max(abs(b), 1))
  end

  defp value_similarity(a, b) when a == b, do: 1.0
  defp value_similarity(_, _), do: 0.0

  defp shared_prefix_len(<<a, rest_a::binary>>, <<b, rest_b::binary>>) when a == b do
    1 + shared_prefix_len(rest_a, rest_b)
  end

  defp shared_prefix_len(_, _), do: 0

  @doc """
  Check if a program output matches the expected output.
  """
  @spec matches_output?(term(), term(), atom()) :: boolean()
  def matches_output?(actual, expected, :integer) when is_integer(actual) do
    actual == expected
  end

  def matches_output?(actual, expected, :number) when is_number(actual) and is_number(expected) do
    if expected == 0 do
      abs(actual) < 0.01
    else
      abs(actual - expected) / abs(expected) < 0.01
    end
  end

  def matches_output?(actual, expected, :string) when is_binary(actual) do
    actual == expected
  end

  def matches_output?(actual, expected, :list) when is_list(actual) and is_list(expected) do
    length(actual) == length(expected) and
      Enum.zip(actual, expected)
      |> Enum.all?(fn {a, e} -> values_match?(a, e) end)
  end

  def matches_output?(actual, expected, :map) when is_map(actual) and is_map(expected) do
    Map.keys(actual) |> Enum.sort() == Map.keys(expected) |> Enum.sort() and
      Enum.all?(expected, fn {k, v} ->
        Map.has_key?(actual, k) and values_match?(Map.get(actual, k), v)
      end)
  end

  def matches_output?(_actual, _expected, _type), do: false

  # Recursive value matching with numeric tolerance
  defp values_match?(a, b) when is_number(a) and is_number(b) do
    if b == 0, do: abs(a) < 0.01, else: abs(a - b) / abs(b) < 0.01
  end

  defp values_match?(a, b) when is_binary(a) and is_binary(b), do: a == b
  defp values_match?(a, b) when is_integer(a) and is_integer(b), do: a == b
  defp values_match?(a, b) when is_atom(a) and is_atom(b), do: a == b
  defp values_match?(a, b) when is_boolean(a) and is_boolean(b), do: a == b

  defp values_match?(a, b) when is_list(a) and is_list(b) do
    length(a) == length(b) and
      Enum.zip(a, b) |> Enum.all?(fn {x, y} -> values_match?(x, y) end)
  end

  defp values_match?(a, b) when is_map(a) and is_map(b) do
    Map.keys(a) |> Enum.sort() == Map.keys(b) |> Enum.sort() and
      Enum.all?(b, fn {k, v} -> Map.has_key?(a, k) and values_match?(Map.get(a, k), v) end)
  end

  defp values_match?(a, b), do: a == b
end
