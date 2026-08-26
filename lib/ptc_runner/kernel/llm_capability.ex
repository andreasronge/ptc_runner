defmodule PtcRunner.Kernel.LLMCapability do
  @moduledoc """
  Constructs the provider-neutral `llm-request` workflow capability.

  The supplied requester owns transport and credential handling.   Requests and
  normalized JSON-like responses are independently bounded. A request may
  include an optional `schema` object; success then returns a closed
  `structured_output` envelope rather than encoded `content`. Requesters may
  return a classified `PtcRunner.Kernel.ProviderError`; unclassified failures
  become retryable `:unavailable` errors. Invalid or oversized responses do not
  cross back into Lisp.

  Dispatcher and adapter boundaries use the same closed public `kind` and
  `reason` vocabulary. HTTP and transport failures become `ProviderError`
  values (`:timeout`, `:unavailable`, `:rate_limited`, `:transport_error`, and
  the permanent request classes). Routed `llm-request` failures that occur
  after alias resolution also carry the public `:model` installation alias.

  This adapter provides model access, not agent policy. Message construction,
  tool protocols, feedback, retries, and completion remain PTC-Lisp workflow
  concerns.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.LLMUsage
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Lisp.RetainedSize

  @default_max_bytes 1_000_000

  @spec new(keyword()) :: {:ok, Capability.t()} | {:error, :invalid_llm_capability}
  @doc """
  Constructs `llm-request` from a required one-argument `:requester` and
  optional positive `:max_request_bytes` and `:max_response_bytes` limits.
  """
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
             input_schema: %{
               "type" => "object",
               "properties" => %{
                 "system" => %{"type" => "string"},
                 "messages" => %{
                   "type" => "array",
                   "items" => %{"type" => "object", "additionalProperties" => true}
                 },
                 "tools" => %{
                   "type" => "array",
                   "items" => %{"type" => "object", "additionalProperties" => true}
                 },
                 "cache" => %{"type" => "boolean"},
                 "schema" => %{
                   "type" => "object",
                   "additionalProperties" => true,
                   "description" => "Request-authored JSON Schema for structured output"
                 }
               }
             },
             output_schema: %{"type" => "object", "additionalProperties" => true},
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

      # A requester that already classified its own failure keeps that
      # classification. Relabelling everything `:unavailable` and retryable is
      # right for a transport that may recover, but wrong for a provider whose
      # answer set is frozen: retrying a miss there can only burn turns.
      {:error, %ProviderError{} = error} ->
        {:error, error}

      {:error, _reason} ->
        {:error, ProviderError.new(:unavailable, "LLM provider unavailable", retryable?: true)}

      _other ->
        {:error, ProviderError.new(:internal, "LLM provider returned an invalid result")}
    end
  end

  defp normalize_response(response, limit) do
    case classify_success(response) do
      {:ok, classified} ->
        classified = stringify_json(classified)
        bytes = RetainedSize.bytes_with_cap(classified, limit)

        if JSONValue.map?(classified) and is_integer(bytes) and bytes <= limit do
          admit_tokens(classified)
        else
          {:error, ProviderError.new(:invalid_request, "LLM response exceeded its boundary")}
        end

      :error ->
        {:error, ProviderError.new(:invalid_result, "LLM provider returned an invalid result")}
    end
  end

  defp classify_success(response) when is_map(response) and not is_struct(response) do
    cond do
      structured_object?(response) ->
        closed_structured(:object, fetch_success(response, :object), response)

      structured_json?(response) ->
        closed_structured(:json, fetch_success(response, :json), response)

      public_structured?(response) ->
        closed_public_structured(fetch_success(response, "structured_output"), response)

      tool_calls?(response) ->
        {:ok,
         keep_success_keys(response, [
           :content,
           :tool_calls,
           :tokens,
           :finish_reason,
           :output_limit
         ])}

      content_response?(response) ->
        {:ok, keep_success_keys(response, [:content, :tokens, :finish_reason, :output_limit])}

      true ->
        :error
    end
  end

  defp classify_success(_response), do: :error

  defp structured_object?(response),
    do: match?(%{object: object} when is_map(object) and not is_struct(object), response)

  defp structured_json?(response),
    do: match?(%{json: json} when is_binary(json), response)

  defp public_structured?(response) do
    match?(
      %{"structured_output" => object} when is_map(object) and not is_struct(object),
      response
    )
  end

  defp tool_calls?(response) do
    calls = Map.get(response, :tool_calls, Map.get(response, "tool_calls"))
    is_list(calls) and calls != []
  end

  defp content_response?(response) do
    Map.has_key?(response, :content) or Map.has_key?(response, "content")
  end

  defp closed_structured(field, value, response) do
    {:ok, %{field => value} |> maybe_put_tokens(response)}
  end

  defp closed_public_structured(object, response) do
    {:ok, %{"structured_output" => object} |> maybe_put_tokens(response)}
  end

  defp maybe_put_tokens(envelope, response) do
    case fetch_success(response, :tokens) do
      :missing -> envelope
      tokens -> Map.put(envelope, :tokens, tokens)
    end
  end

  defp keep_success_keys(response, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case fetch_success(response, key) do
        :missing -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp fetch_success(response, key) when is_atom(key) do
    cond do
      Map.has_key?(response, key) -> Map.fetch!(response, key)
      Map.has_key?(response, Atom.to_string(key)) -> Map.fetch!(response, Atom.to_string(key))
      true -> :missing
    end
  end

  defp fetch_success(response, key) when is_binary(key) do
    if Map.has_key?(response, key), do: Map.fetch!(response, key), else: :missing
  end

  defp admit_tokens(response) do
    if Map.has_key?(response, "tokens") do
      case LLMUsage.normalize(response["tokens"]) do
        {:ok, usage} ->
          {:ok, response |> Map.put("tokens", usage) |> RetainedSize.detach_binaries()}

        {:error, :invalid_llm_usage} ->
          invalid_usage()
      end
    else
      {:ok, RetainedSize.detach_binaries(response)}
    end
  end

  defp invalid_usage,
    do:
      {:error, ProviderError.new(:invalid_request, "LLM response contained invalid token usage")}

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
