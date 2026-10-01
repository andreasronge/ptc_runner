defmodule PtcRunner.Kernel.OpenRouterDecisions do
  @moduledoc """
  Adapts the alpha OpenRouter Decisions endpoint to the decision contract.

  Credentials are supplied by host acquisition, never read from the environment.
  The closed host routing object passes through as OpenRouter's `provider`.
  Vendor wire types remain inside this adapter. HTTP retries are disabled.
  """
  alias PtcRunner.Kernel.HTTPDecisions
  @endpoint "https://openrouter.ai/api/alpha/decisions"

  @doc "Builds a deadline-aware requester from a host-bound credential and routing policy."
  @spec requester(binary(), binary(), map(), pos_integer(), function()) :: function()
  def requester(model, credential, routing, timeout_ms, http_request \\ &Req.post/2) do
    transport = HTTPDecisions.requester(@endpoint, model, credential, timeout_ms, http_request)

    fn request, context ->
      body = Map.update!(request, "questions", &encode_questions/1)
      body = if map_size(routing) == 0, do: body, else: Map.put(body, "provider", routing)

      case transport.(body, context) do
        {:ok, response} -> {:ok, normalize_response(response)}
        error -> error
      end
    end
  end

  defp normalize_response(%{"answers" => answers} = response) when is_map(answers),
    do: Map.put(response, "answers", normalize_answers(answers))

  defp normalize_response(response), do: response

  defp encode_questions(questions) do
    Map.new(questions, fn
      {name, %{"type" => "boolean"} = question} ->
        {name, question |> Map.delete("type") |> Map.put("type", "noul")}

      question ->
        question
    end)
  end

  defp normalize_answers(answers) do
    Map.new(answers, fn
      {name, %{"type" => "noul", "noul" => probability} = answer} ->
        {name,
         answer
         |> Map.delete("noul")
         |> Map.put("type", "boolean")
         |> Map.put("probability", probability)
         |> Map.put("confidence", nil)}

      answer ->
        answer
    end)
  end
end
