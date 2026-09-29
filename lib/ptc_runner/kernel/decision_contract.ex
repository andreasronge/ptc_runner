defmodule PtcRunner.Kernel.DecisionContract do
  @moduledoc false
  @rounding_tolerance 0.01
  @float_epsilon 1.0e-12
  @spec validate_request(term()) :: :ok | {:error, String.t()}
  def validate_request(%{"state" => state, "questions" => questions})
      when is_map(questions) and map_size(questions) > 0 and is_map(state) do
    if Enum.all?(questions, &valid_question?/1),
      do: :ok,
      else: {:error, "questions must be named choice, score, or boolean definitions"}
  end

  def validate_request(_request), do: {:error, "questions must not be empty"}

  defp valid_question?({name, %{"type" => type, "instructions" => instructions} = question})
       when is_binary(name) and type in ["choice", "score", "boolean"] and
              is_binary(instructions) do
    byte_size(name) > 0 and byte_size(instructions) > 0 and
      Map.keys(question) -- ["type", "instructions", "criteria"] == [] and
      valid_criteria?(type, Map.get(question, "criteria"))
  end

  defp valid_question?(_question), do: false

  defp valid_criteria?("boolean", nil), do: true

  defp valid_criteria?("boolean", %{"true" => yes, "false" => no} = criteria),
    do: map_size(criteria) == 2 and is_binary(yes) and is_binary(no)

  defp valid_criteria?("choice", criteria) when is_map(criteria),
    do:
      map_size(criteria) in 1..255 and
        Enum.all?(criteria, fn {key, value} -> is_binary(key) and is_binary(value) end)

  defp valid_criteria?("score", criteria) when is_list(criteria),
    do: length(criteria) in 2..10 and Enum.all?(criteria, &is_binary/1)

  defp valid_criteria?(_type, _criteria), do: false

  @spec valid_response?(term(), map()) :: boolean()
  def valid_response?(%{"model" => model, "answers" => answers, "usage" => usage}, questions)
      when is_binary(model) and byte_size(model) > 0 and is_map(answers) do
    valid_usage?(usage) and MapSet.new(Map.keys(answers)) == MapSet.new(Map.keys(questions)) and
      Enum.all?(questions, fn {id, question} -> valid_answer?(answers[id], question) end)
  end

  def valid_response?(_, _), do: false
  defp nullable_probability?(nil), do: true
  defp nullable_probability?(value), do: probability?(value)

  defp valid_answer?(
         %{"type" => "boolean", "probability" => probability, "confidence" => confidence},
         %{"type" => "boolean"}
       ),
       do: nullable_probability?(probability) and nullable_probability?(confidence)

  defp valid_answer?(
         %{
           "type" => "choice",
           "choice" => choice,
           "probabilities" => probabilities,
           "confidence" => confidence
         },
         %{"type" => "choice", "criteria" => criteria}
       ) do
    valid_distribution?(probabilities, Map.keys(criteria)) and nullable_probability?(confidence) and
      Map.has_key?(criteria, choice) and
      (is_nil(probabilities) or
         within_rounding_tolerance?(Enum.max(Map.values(probabilities)) - probabilities[choice]))
  end

  defp valid_answer?(
         %{
           "type" => "score",
           "score" => score,
           "legend" => legend,
           "probabilities" => probabilities,
           "confidence" => confidence
         },
         %{"type" => "score", "criteria" => criteria}
       ) do
    levels = Enum.map(0..(length(criteria) - 1), &Integer.to_string/1)
    expected_legend = levels |> Enum.zip(criteria) |> Map.new()

    valid_distribution?(probabilities, levels) and legend == expected_legend and
      nullable_probability?(confidence) and finite_number?(score) and score >= 0 and
      score <= length(criteria) - 1 and
      (is_nil(probabilities) or
         within_rounding_tolerance?(
           score -
             Enum.reduce(0..(length(criteria) - 1), 0.0, fn level, sum ->
               sum + level * probabilities[Integer.to_string(level)]
             end)
         ))
  end

  defp valid_answer?(_, _), do: false

  defp valid_distribution?(nil, _keys), do: true

  defp valid_distribution?(values, keys) when is_map(values) do
    MapSet.new(Map.keys(values)) == MapSet.new(keys) and
      Enum.all?(Map.values(values), &probability?/1) and
      within_rounding_tolerance?(Enum.sum(Map.values(values)) - 1.0)
  end

  defp valid_distribution?(_, _), do: false

  defp probability?(value), do: finite_number?(value) and value >= 0 and value <= 1

  defp within_rounding_tolerance?(difference),
    do: abs(difference) <= @rounding_tolerance + @float_epsilon

  defp finite_number?(value) when is_integer(value), do: true
  defp finite_number?(value) when is_float(value), do: value == value and abs(value) < 1.0e308
  defp finite_number?(_), do: false

  defp valid_usage?(%{"input_tokens" => input, "output_tokens" => output} = usage) do
    valid_token_usage?(input, output) and
      (not Map.has_key?(usage, "cost") or
         (finite_number?(usage["cost"]) and usage["cost"] >= 0))
  end

  defp valid_usage?(_), do: false

  defp valid_token_usage?(input, output),
    do: is_integer(input) and input >= 0 and is_integer(output) and output >= 0
end
