defmodule PtcRunner.Kernel.ChatDecisions do
  @moduledoc false

  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.LLMUsage
  alias PtcRunner.Kernel.ProviderError

  @spec requester(function(), binary()) :: function()
  def requester(chat, model) do
    fn request, context ->
      schema = schema(request["questions"])

      chat_request = %{
        system:
          "Answer every named question using the supplied state, instructions and criteria.",
        messages: [%{role: :user, content: Jason.encode!(request)}],
        schema: schema
      }

      with {:ok, _, compiled} <- JSONSchema.compile(schema),
           {:ok, response} <- chat.(chat_request, Map.take(context, [:llm_request_deadline_ms])) do
        normalize(response, request["questions"], compiled, model)
      else
        {:error, {:invalid_schema, _}} ->
          {:error,
           ProviderError.new(
             :invalid_request,
             "Decision questions exceed the structured schema boundary",
             dispatch_provenance: :not_dispatched
           )}

        error ->
          error
      end
    end
  end

  @spec schema(map()) :: map()
  def schema(questions) do
    %{
      "type" => "object",
      "properties" => Map.new(questions, fn {id, question} -> {id, value_schema(question)} end),
      "required" => questions |> Map.keys() |> Enum.sort(),
      "additionalProperties" => false
    }
  end

  defp value_schema(%{"type" => "boolean"}), do: %{"type" => "boolean"}

  defp value_schema(%{"type" => "choice", "criteria" => criteria}),
    do: %{"type" => "string", "enum" => criteria |> Map.keys() |> Enum.sort()}

  defp value_schema(%{"type" => "score", "criteria" => criteria}),
    do: %{"type" => "integer", "enum" => Enum.to_list(0..(length(criteria) - 1))}

  defp normalize(response, questions, schema, model) when is_map(response) do
    # The adapter returns atom keys; replay and other trusted callbacks may use JSON keys.
    object = field(response, :object)
    {usage, valid_usage?} = usage(field(response, :tokens))
    base = %{"model" => model, "usage" => usage}

    if valid_usage? and JSONSchema.valid?(schema, object) do
      {:ok,
       Map.put(
         base,
         "answers",
         Map.new(questions, fn {id, question} ->
           {id, answer(question, object[id])}
         end)
       )}
    else
      # Preserve independently reported usage so malformed responses still settle.
      {:ok, base}
    end
  end

  defp normalize(_, _, _, _), do: {:ok, %{}}

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp usage(tokens) when is_map(tokens) do
    result = %{"input_tokens" => field(tokens, :input), "output_tokens" => field(tokens, :output)}

    result =
      if Map.has_key?(tokens, :total_cost) or Map.has_key?(tokens, "total_cost") do
        cost = field(tokens, :total_cost)

        normalized_cost =
          case LLMUsage.normalize(%{"total_cost" => cost}) do
            {:ok, normalized} -> normalized["total_cost"]
            _ -> cost
          end

        Map.put(result, "cost", normalized_cost)
      else
        result
      end

    {result, match?({:ok, _}, LLMUsage.normalize(tokens))}
  end

  defp usage(_), do: {nil, false}

  defp answer(%{"type" => "boolean"}, value),
    do: %{"type" => "boolean", "value" => value, "probability" => nil, "confidence" => nil}

  defp answer(%{"type" => "choice"}, value),
    do: %{"type" => "choice", "choice" => value, "probabilities" => nil, "confidence" => nil}

  defp answer(%{"type" => "score", "criteria" => criteria}, value) do
    legend =
      criteria |> Enum.with_index() |> Map.new(fn {label, i} -> {Integer.to_string(i), label} end)

    %{
      "type" => "score",
      "score" => value,
      "legend" => legend,
      "probabilities" => nil,
      "confidence" => nil
    }
  end
end
