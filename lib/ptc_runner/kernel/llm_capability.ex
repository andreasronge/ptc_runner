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
  Constructs `llm-request` from a required `:requester` and optional positive
  `:max_request_bytes` and `:max_response_bytes` limits.

  The requester is arity two: a provider-neutral request plus
  `%{llm_request_deadline_ms: integer() | nil}`. Arity one is accepted for
  callers that ignore the deadline context.
  """
  def new(opts) when is_list(opts) do
    with true <- Keyword.keys(opts) -- [:requester, :max_request_bytes, :max_response_bytes] == [],
         requester when is_function(requester, 1) or is_function(requester, 2) <-
           Keyword.get(opts, :requester),
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
             callback: requester_callback(requester, response_limit)
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

  defp requester_callback(requester, response_limit) when is_function(requester, 2) do
    fn request, context ->
      invoke(requester, request, requester_context(context), response_limit)
    end
  end

  defp requester_callback(requester, response_limit) when is_function(requester, 1) do
    fn request -> invoke(requester, request, %{llm_request_deadline_ms: nil}, response_limit) end
  end

  defp requester_context(%{llm_request_deadline_ms: deadline})
       when is_integer(deadline) or is_nil(deadline),
       do: %{llm_request_deadline_ms: deadline}

  defp requester_context(_context), do: %{llm_request_deadline_ms: nil}

  defp invoke(requester, request, context, response_limit) when is_function(requester, 2) do
    schema_request? = schema_request?(request)

    classify_requester_result(
      requester.(request, context),
      request,
      response_limit,
      schema_request?
    )
  end

  defp invoke(requester, request, _context, response_limit) when is_function(requester, 1) do
    schema_request? = schema_request?(request)
    classify_requester_result(requester.(request), request, response_limit, schema_request?)
  end

  defp classify_requester_result(result, _request, response_limit, schema_request?) do
    case result do
      {:ok, response} ->
        normalize_response(response, response_limit, schema_request?)

      # Adapter-branch and Kernel-side structured rejections are invalid
      # results, not provider errors. Admit an empty candidate so Dispatcher
      # publishes `invalid_result` / `output_schema_mismatch`.
      {:error, %ProviderError{kind: :invalid_result}} when schema_request? ->
        {:ok, %{}}

      # A requester that already classified its own failure keeps that
      # classification. Relabelling everything `:unavailable` and retryable is
      # right for a transport that may recover, but wrong for a provider whose
      # answer set is frozen: retrying a miss there can only burn turns.
      {:error, %ProviderError{} = error} ->
        {:error, error}

      {:error, _reason} ->
        {:error, ProviderError.new(:unavailable, "LLM provider unavailable", retryable?: true)}

      _other ->
        if schema_request? do
          {:ok, %{}}
        else
          {:error, ProviderError.new(:internal, "LLM provider returned an invalid result")}
        end
    end
  end

  defp schema_request?(request) when is_map(request) do
    Map.has_key?(request, "schema") or Map.has_key?(request, :schema)
  end

  defp normalize_response(response, limit, schema_request?) do
    case classify_success(response, schema_request?) do
      {:ok, classified} ->
        classified = stringify_json(classified)
        bytes = RetainedSize.bytes_with_cap(classified, limit)

        if JSONValue.map?(classified) and is_integer(bytes) and bytes <= limit do
          admit_tokens(classified, schema_request?)
        else
          schema_output_mismatch(schema_request?, :invalid_request)
        end

      :error ->
        schema_output_mismatch(schema_request?, :invalid_result)
    end
  end

  defp schema_output_mismatch(true, _kind), do: {:ok, %{}}

  defp schema_output_mismatch(false, :invalid_request),
    do: {:error, ProviderError.new(:invalid_request, "LLM response exceeded its boundary")}

  defp schema_output_mismatch(false, :invalid_result),
    do: {:error, ProviderError.new(:invalid_result, "LLM provider returned an invalid result")}

  defp classify_success(response, schema_request?)
       when is_map(response) and not is_struct(response) do
    cond do
      schema_candidate?(response) ->
        close_schema_candidate(response)

      schema_request? ->
        {:ok, keep_success_keys(response, [:tokens])}

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

  defp classify_success(_response, _schema_request?), do: :error

  defp schema_candidate?(response) do
    success_key?(response, :object) or success_key?(response, :json) or
      success_key?(response, :structured_output)
  end

  defp close_schema_candidate(response) do
    cond do
      success_key?(response, :object) ->
        closed_structured(:object, fetch_success(response, :object), response)

      success_key?(response, :json) ->
        closed_structured(:json, fetch_success(response, :json), response)

      true ->
        closed_public_structured(fetch_success(response, :structured_output), response)
    end
  end

  defp success_key?(response, key) when is_atom(key) do
    Map.has_key?(response, key) or Map.has_key?(response, Atom.to_string(key))
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

  defp admit_tokens(response, schema_request?) do
    if Map.has_key?(response, "tokens") do
      case LLMUsage.normalize(response["tokens"]) do
        {:ok, usage} ->
          {:ok, response |> Map.put("tokens", usage) |> RetainedSize.detach_binaries()}

        {:error, :invalid_llm_usage} ->
          if schema_request? do
            # Slice 3 chooses this taxonomy deliberately: usage guarantees are
            # interim-disabled, so malformed tokens on a schema response are
            # provider output that failed the closed structured envelope
            # (`output_schema_mismatch`), not promised-usage settlement
            # (`promised_usage_missing`).
            schema_output_mismatch(true, :invalid_result)
          else
            invalid_usage()
          end
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
