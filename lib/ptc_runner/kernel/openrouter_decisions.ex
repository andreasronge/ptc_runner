defmodule PtcRunner.Kernel.OpenRouterDecisions do
  @moduledoc """
  Adapts the alpha OpenRouter Decisions endpoint to the decision contract.

  Credentials are supplied by host acquisition, never read from the environment.
  The closed host routing object passes through as OpenRouter's `provider`.
  Vendor wire types remain inside this adapter. HTTP retries are disabled.
  """
  alias PtcRunner.Kernel.AdapterCancellationWitness
  alias PtcRunner.Kernel.ProviderError
  @endpoint "https://openrouter.ai/api/alpha/decisions"

  @doc "Builds a deadline-aware requester from a host-bound credential and routing policy."
  @spec requester(binary(), binary(), map(), pos_integer(), function()) :: function()
  def requester(model, credential, routing, timeout_ms, http_request \\ &Req.post/2) do
    fn request, context ->
      body = request |> Map.put("model", model) |> Map.update!("questions", &encode_questions/1)
      body = if map_size(routing) == 0, do: body, else: Map.put(body, "provider", routing)
      deadline = Map.get(context, :llm_request_deadline_ms)

      timeout =
        if is_integer(deadline),
          do: min(timeout_ms, max(deadline - System.monotonic_time(:millisecond), 1)),
          else: timeout_ms

      result =
        AdapterCancellationWitness.run(fn ->
          http_request.(@endpoint,
            json: body,
            auth: {:bearer, credential},
            retry: false,
            receive_timeout: timeout
          )
        end)

      case result do
        {:ok, %{status: status, body: response}} when status in 200..299 and is_map(response) ->
          {:ok, response |> Map.take(["model", "answers", "usage"]) |> normalize_response()}

        {:ok, %{status: status}} when status in 200..299 ->
          {:ok, %{}}

        {:ok, %{status: status}} ->
          {:error,
           ProviderError.new(http_error_kind(status), "OpenRouter Decisions request failed",
             retryable?: status in [408, 429, 500, 502, 503, 504, 529],
             dispatch_provenance: :dispatched
           )}

        {:error, _} ->
          {:error,
           ProviderError.new(:transport_error, "OpenRouter Decisions transport failed",
             retryable?: true,
             dispatch_provenance: :possibly_dispatched
           )}
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

  defp http_error_kind(401), do: :authentication_failed
  defp http_error_kind(402), do: :payment_required
  defp http_error_kind(429), do: :rate_limited
  defp http_error_kind(status) when status in 400..499, do: :invalid_request
  defp http_error_kind(_status), do: :unavailable
end
