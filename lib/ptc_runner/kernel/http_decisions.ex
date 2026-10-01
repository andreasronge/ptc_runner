defmodule PtcRunner.Kernel.HTTPDecisions do
  @moduledoc """
  Sends decision requests to a fixed host-owned HTTP endpoint.

  Credentials are optional and supplied by host acquisition. Automatic retries
  and redirects are disabled so request state stays at the configured destination.
  The shared transport retains cancellation and dispatch evidence.
  """
  alias PtcRunner.Kernel.AdapterCancellationWitness
  alias PtcRunner.Kernel.ProviderError

  @doc "Builds a requester with a receive timeout clamped to the remaining deadline."
  @spec requester(binary(), binary(), binary() | nil, pos_integer(), function()) :: function()
  def requester(endpoint, model, credential, timeout_ms, http_request \\ &Req.post/2) do
    fn request, context ->
      deadline = Map.get(context, :llm_request_deadline_ms)

      timeout =
        if is_integer(deadline),
          do: min(timeout_ms, max(deadline - System.monotonic_time(:millisecond), 1)),
          else: timeout_ms

      options = [
        json: Map.put(request, "model", model),
        retry: false,
        redirect: false,
        receive_timeout: timeout
      ]

      options =
        if is_nil(credential),
          do: options,
          else: Keyword.put(options, :auth, {:bearer, credential})

      result = AdapterCancellationWitness.run(fn -> http_request.(endpoint, options) end)

      case result do
        {:ok, %{status: status, body: response}} when status in 200..299 and is_map(response) ->
          {:ok, Map.take(response, ["model", "answers", "usage"])}

        {:ok, %{status: status}} when status in 200..299 ->
          {:ok, %{}}

        {:ok, %{status: status}} ->
          {:error,
           ProviderError.new(http_error_kind(status), "Decision HTTP request failed",
             retryable?: status in [408, 429, 500, 502, 503, 504, 529],
             dispatch_provenance: :dispatched
           )}

        {:error, _} ->
          {:error,
           ProviderError.new(:transport_error, "Decision HTTP transport failed",
             retryable?: true,
             dispatch_provenance: :possibly_dispatched
           )}
      end
    end
  end

  defp http_error_kind(status) when status in 300..399, do: :invalid_request
  defp http_error_kind(401), do: :authentication_failed
  defp http_error_kind(402), do: :payment_required
  defp http_error_kind(429), do: :rate_limited
  defp http_error_kind(status) when status in 400..499, do: :invalid_request
  defp http_error_kind(_status), do: :unavailable
end
