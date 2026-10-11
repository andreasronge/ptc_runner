if Code.ensure_loaded?(ReqLLM) do
  defmodule PtcRunner.LLM.ReqLLMErrors do
    @moduledoc false

    alias PtcRunner.Kernel.ProviderError

    def normalize_call_result(result, mode \\ :ordinary)

    def normalize_call_result({:error, reason}, mode), do: provider_failure(reason, mode)
    def normalize_call_result(result, _mode), do: result

    defp provider_failure(reason, mode), do: {:error, normalize_provider_error(reason, mode)}

    defp normalize_provider_error(reason, :tools) do
      case tool_calling_unsupported_details(reason) do
        {:ok, details} -> ProviderError.new(:tool_calling_unsupported, details)
        :error -> normalize_provider_error(reason)
      end
    end

    defp normalize_provider_error(reason, _mode), do: normalize_provider_error(reason)

    defp normalize_provider_error(%ProviderError{} = error), do: error

    defp normalize_provider_error(%ReqLLM.Error.API.Timeout{} = error) do
      ProviderError.new(:timeout, Exception.message(error), retryable?: true)
    end

    defp normalize_provider_error(%ReqLLM.Error.API.Request{status: status} = error)
         when is_integer(status) do
      ProviderError.new(
        http_error_kind(status),
        http_error_details(status, error.reason),
        retryable?: http_retryable?(status, error.retryable),
        dispatch_provenance: :dispatched
      )
    end

    defp normalize_provider_error(%ReqLLM.Error.API.Request{} = error) do
      ProviderError.new(
        transport_error_kind(error.cause),
        safe_error_details(error.reason, "LLM transport unavailable"),
        retryable?: transport_retryable?(error.cause, error.retryable)
      )
    end

    defp normalize_provider_error(%ReqLLM.Error.API.Response{status: status} = error)
         when is_integer(status) do
      ProviderError.new(
        http_error_kind(status),
        http_error_details(status, error.reason),
        retryable?: http_retryable?(status, nil),
        dispatch_provenance: :dispatched
      )
    end

    defp normalize_provider_error(%ReqLLM.Error.API.Response{} = error) do
      ProviderError.new(
        :invalid_result,
        safe_error_details(error.reason, "LLM provider returned an invalid response")
      )
    end

    defp normalize_provider_error(%{status: status} = error) when is_integer(status) do
      ProviderError.new(
        http_error_kind(status),
        direct_http_error_details(status, Map.get(error, :body)),
        retryable?: http_retryable?(status, nil),
        dispatch_provenance: :dispatched
      )
    end

    defp normalize_provider_error(%Req.TransportError{reason: reason}) do
      ProviderError.new(
        transport_error_kind(reason),
        transport_error_details(reason),
        retryable?: retryable_transport_reason?(reason)
      )
    end

    defp normalize_provider_error(:structured_output_not_supported),
      do: ProviderError.new(:invalid_request, "LLM provider does not support structured output")

    defp normalize_provider_error(:tool_calling_not_supported),
      do:
        ProviderError.new(:invalid_request, "LLM adapter route does not support tool calling",
          dispatch_provenance: :not_dispatched
        )

    defp normalize_provider_error(_reason),
      do: ProviderError.new(:unavailable, "LLM provider unavailable", retryable?: true)

    defp http_error_kind(401), do: :authentication_failed
    defp http_error_kind(402), do: :payment_required
    defp http_error_kind(403), do: :denied
    defp http_error_kind(404), do: :not_found
    defp http_error_kind(408), do: :timeout
    defp http_error_kind(429), do: :rate_limited
    defp http_error_kind(status) when status in 400..499, do: :invalid_request
    defp http_error_kind(status) when status in 500..599, do: :unavailable
    defp http_error_kind(_status), do: :unavailable

    defp http_retryable?(_status, retryable?) when is_boolean(retryable?), do: retryable?
    defp http_retryable?(status, _retryable?) when status in [408, 409, 425, 429], do: true
    defp http_retryable?(status, _retryable?) when status in 500..599, do: true
    defp http_retryable?(_status, _retryable?), do: false

    defp http_error_details(status, reason) when is_binary(reason),
      do: safe_error_details("HTTP #{status}: #{reason}", "HTTP #{status}")

    defp http_error_details(status, _reason), do: "HTTP #{status}"

    defp direct_http_error_details(status, body) do
      case provider_message(body) do
        message when is_binary(message) -> http_error_details(status, message)
        _missing -> "HTTP #{status}"
      end
    end

    defp provider_message(%{"error" => %{"message" => message}}) when is_binary(message),
      do: message

    defp provider_message(%{"error" => message}) when is_binary(message), do: message
    defp provider_message(%{"message" => message}) when is_binary(message), do: message
    defp provider_message(_body), do: nil

    defp tool_calling_unsupported_details(%ReqLLM.Error.API.Request{
           status: 404,
           reason: reason
         })
         when is_binary(reason),
         do: known_tool_calling_rejection(reason, http_error_details(404, reason))

    defp tool_calling_unsupported_details(%ReqLLM.Error.API.Response{
           status: 404,
           reason: reason
         })
         when is_binary(reason),
         do: known_tool_calling_rejection(reason, http_error_details(404, reason))

    defp tool_calling_unsupported_details(%{status: 404, body: body}) do
      case provider_message(body) do
        message when is_binary(message) ->
          known_tool_calling_rejection(message, http_error_details(404, message))

        _missing ->
          :error
      end
    end

    defp tool_calling_unsupported_details(_reason), do: :error

    defp known_tool_calling_rejection(message, details) do
      if message
         |> String.downcase()
         |> String.contains?("no endpoints found that support tool use") do
        {:ok, details}
      else
        :error
      end
    end

    defp safe_error_details(details, fallback) when is_binary(details) do
      if String.valid?(details) and details != "", do: details, else: fallback
    end

    defp safe_error_details(_details, fallback), do: fallback

    defp transport_error_kind(%Req.TransportError{reason: reason}),
      do: transport_error_kind(reason)

    defp transport_error_kind(%Finch.TransportError{reason: reason}),
      do: transport_error_kind(reason)

    defp transport_error_kind(%Mint.TransportError{reason: reason}),
      do: transport_error_kind(reason)

    defp transport_error_kind(:timeout), do: :timeout
    defp transport_error_kind(_reason), do: :transport_error

    defp transport_retryable?(_cause, retryable?) when is_boolean(retryable?), do: retryable?

    defp transport_retryable?(cause, _retryable?),
      do: cause |> transport_reason() |> retryable_transport_reason?()

    defp transport_reason(%Req.TransportError{reason: reason}), do: reason
    defp transport_reason(%Finch.TransportError{reason: reason}), do: reason
    defp transport_reason(%Mint.TransportError{reason: reason}), do: reason
    defp transport_reason(_cause), do: nil

    defp retryable_transport_reason?(reason),
      do: reason in [:closed, :timeout, :econnrefused, :pool_not_available]

    defp transport_error_details(reason) when is_atom(reason),
      do: "LLM transport error: #{reason}"

    defp transport_error_details(_reason), do: "LLM transport unavailable"
  end
end
