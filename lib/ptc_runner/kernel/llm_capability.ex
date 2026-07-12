defmodule PtcRunner.Kernel.LLMCapability do
  @moduledoc "Constructs the provider-neutral, bounded `llm-request` workflow capability."

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Lisp.RetainedSize

  @default_max_bytes 1_000_000

  @spec new(keyword()) :: {:ok, Capability.t()} | {:error, :invalid_llm_capability}
  def new(opts) when is_list(opts) do
    with true <- Keyword.keys(opts) -- [:requester, :max_request_bytes, :max_response_bytes] == [],
         requester when is_function(requester, 1) <- Keyword.get(opts, :requester),
         request_limit when is_integer(request_limit) and request_limit > 0 <-
           Keyword.get(opts, :max_request_bytes, @default_max_bytes),
         response_limit when is_integer(response_limit) and response_limit > 0 <-
           Keyword.get(opts, :max_response_bytes, @default_max_bytes),
         {:ok, capability} <-
           Capability.new(
             name: "llm-request",
             description: "Submit one provider-neutral bounded language-model request",
             validate: fn request -> validate_request(request, request_limit) end,
             callback: fn request -> invoke(requester, request, response_limit) end
           ) do
      {:ok, capability}
    else
      _ -> {:error, :invalid_llm_capability}
    end
  end

  def new(_opts), do: {:error, :invalid_llm_capability}

  defp validate_request(request, limit) do
    bytes = RetainedSize.bytes_with_cap(request, limit)

    if JSONValue.map?(request) and is_integer(bytes) and bytes <= limit,
      do: :ok,
      else: {:error, "invalid or oversized LLM request"}
  end

  defp invoke(requester, request, response_limit) do
    case requester.(request) do
      {:ok, response} ->
        normalize_response(response, response_limit)

      {:error, _reason} ->
        {:error, ProviderError.new(:unavailable, "LLM provider unavailable", retryable?: true)}

      _other ->
        {:error, ProviderError.new(:internal, "LLM provider returned an invalid result")}
    end
  end

  defp normalize_response(response, limit) do
    response = stringify_json(response)
    bytes = RetainedSize.bytes_with_cap(response, limit)

    if JSONValue.map?(response) and is_integer(bytes) and bytes <= limit,
      do: {:ok, response},
      else: {:error, ProviderError.new(:invalid_request, "LLM response exceeded its boundary")}
  end

  defp stringify_json(nil), do: nil

  defp stringify_json(value) when is_boolean(value) or is_number(value) or is_binary(value),
    do: value

  defp stringify_json(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_json(value) when is_list(value), do: Enum.map(value, &stringify_json/1)

  defp stringify_json(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, item} -> {stringify_key(key), stringify_json(item)} end)
  end

  defp stringify_json(value), do: value
  defp stringify_key(key) when is_binary(key), do: key
  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key), do: key
end
