defmodule PtcRunner.Labs.HttpAdapter do
  @moduledoc false
  @behaviour PtcRunner.LLM

  alias PtcLlmHttp.{
    Credential,
    Deadline,
    Error,
    ProcessBudget,
    Request,
    Response,
    Target,
    ToolCall,
    Usage
  }

  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.LLM.{Invocation, ReqLLMAdapter, Requirements}

  @impl true
  def ensure_ready, do: ReqLLMAdapter.ensure_ready()
  @impl true
  def provider_application(model), do: ReqLLMAdapter.provider_application(model)
  @impl true
  def public_model("openrouter:" <> _ = model), do: {:ok, model}
  def public_model(_), do: :private

  @impl true
  def prepare_model("openrouter:" <> model = selector, requirements) do
    with {:ok, canonical} <- Requirements.canonical(requirements),
         true <-
           is_integer(canonical.exact_options[:max_tokens]) and
             canonical.exact_options.max_tokens > 0,
         true <- Map.keys(canonical.exact_options) -- [:max_tokens, :temperature, :seed] == [],
         {:ok, metadata, status, ^canonical} <- ReqLLMAdapter.prepare_model(selector, canonical),
         {:ok, transport} <- target(model, canonical) do
      {:ok, %{metadata: metadata, transport: transport, requirements: canonical}, status,
       canonical}
    else
      _ -> {:error, :unsupported_model_option}
    end
  end

  def prepare_model(_, _), do: {:error, :unsupported_model_option}

  @impl true
  def reservation_bound(target, request, tariff),
    do: ReqLLMAdapter.reservation_bound(target.metadata, request, tariff)

  # Fresh lab VM only: the host owns one named runtime, shared by every caller.
  # Nothing is started or captured during model preparation.
  def start_runtime(options) do
    {:ok, runtime} = PtcLlmHttp.Runtime.start_link(options)
    true = Process.register(runtime, __MODULE__)
    {:ok, runtime}
  end

  @impl true
  def call(target, %Invocation{cache: false} = invocation) do
    with runtime when is_pid(runtime) <- Process.whereis(__MODULE__),
         {:ok, request} <- encode_request(target, invocation.request),
         {:ok, credential} <- credential(invocation.credential),
         {:ok, deadline} <- Deadline.new(invocation.llm_request_deadline_ms || now() + 120_000),
         {:ok, budget} <- ProcessBudget.new(total_heap_words: 4_000_000),
         {:ok, response} <-
           PtcLlmHttp.call(runtime, target.transport, request,
             credential: credential,
             deadline: deadline,
             process_budget: budget
           ) do
      normalize(response, target, invocation.request)
    else
      {:error, %Error{} = error} ->
        failure(error)

      _ ->
        {:error,
         ProviderError.new(:unavailable, "pilot runtime unavailable",
           dispatch_provenance: :not_dispatched
         )}
    end
  end

  def call(_, _),
    do:
      {:error,
       ProviderError.new(:invalid_request, "unsupported pilot invocation",
         dispatch_provenance: :not_dispatched
       )}

  defp target(model, requirements) do
    {url, policy} =
      Application.get_env(
        :ptc_runner,
        :pilot_http_endpoint,
        {"https://openrouter.ai/api/v1", :public}
      )

    Target.new(
      kind: :openai_compat,
      base_url: url,
      model: model,
      capacity_group: "openrouter",
      connect_policy: policy,
      max_encoded_request_bytes: 1_048_576,
      max_wire_response_bytes: 1_048_576,
      tools: true,
      streaming: false,
      structured_output: requirements.structured_output_mode,
      cache_mode: :unsupported,
      upstream_routing: :opaque,
      usage_guarantees: %{
        tokens: requirements.usage_guarantees.tokens,
        cost: requirements.usage_guarantees.cost_currency == "USD"
      }
    )
  end

  defp encode_request(target, request) do
    tools =
      Enum.map(Map.get(request, :tools, []), fn tool ->
        function = tool[:function] || tool["function"]

        %{
          name: function[:name] || function["name"],
          description: function[:description] || function["description"],
          parameters: function[:parameters] || function["parameters"]
        }
      end)

    options =
      Map.to_list(target.requirements.exact_options) ++
        [
          system: request[:system],
          messages: request.messages,
          tools: tools,
          response_schema: response_schema(target, request[:schema])
        ]

    Request.new(options)
  end

  defp response_schema(_, nil), do: nil

  defp response_schema(%{requirements: %{structured_output_mode: :json_object}}, _),
    do: :json_object

  defp response_schema(_, schema), do: %{name: "result", schema: schema}

  defp normalize(response, target, request) do
    result = %{
      content: Response.content(response),
      tokens: usage(Response.usage(response)),
      tool_calls:
        Enum.map(Response.tool_calls(response), fn call ->
          %{id: ToolCall.id(call), name: ToolCall.name(call), args: ToolCall.arguments(call)}
        end)
    }

    result =
      case Response.finish_reason(response) do
        "length" ->
          Map.merge(result, %{
            finish_reason: :length,
            output_limit: %{
              name: :max_tokens,
              value: target.requirements.exact_options.max_tokens,
              bindings: target.requirements.output_limit_bindings
            }
          })

        "stop" ->
          Map.put(result, :finish_reason, :stop)

        "tool_calls" ->
          Map.put(result, :finish_reason, :tool_calls)

        nil ->
          result
      end

    if is_map(request[:schema]) do
      case Jason.decode(result.content) do
        {:ok, object} when is_map(object) -> {:ok, %{object: object, tokens: result.tokens}}
        _ -> {:error, ProviderError.new(:invalid_result, "invalid pilot structured response")}
      end
    else
      {:ok, result}
    end
  end

  defp usage(nil), do: %{}

  defp usage(usage) do
    facts = Usage.facts(usage)

    [
      input: facts.prompt_tokens,
      output: facts.completion_tokens,
      cache_read: facts.cached_tokens,
      cache_creation: facts.cache_write_tokens,
      total_cost: facts.cost
    ]
    |> Enum.reject(fn {_, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp failure(error) do
    facts = Error.facts(error)
    :telemetry.execute([:ptc_runner, :pilot_http, :failure], %{}, facts)

    kind =
      case facts.kind do
        :deadline_exceeded -> :timeout
        :capacity_exhausted -> :unavailable
        :model_refusal -> :invalid_request
        :invalid_tool_arguments -> :invalid_result
        :malformed_provider_response -> :invalid_result
        :provider_result_too_large -> :invalid_result
        :http_status -> http_kind(facts.http_status)
        :invalid_request -> :invalid_request
        :unsupported_capability -> :invalid_request
        _ -> :transport_error
      end

    provenance =
      case facts.dispatch do
        :not_sent -> :not_dispatched
        :completed -> :dispatched
        _ -> :possibly_dispatched
      end

    {:error,
     ProviderError.new(kind, "pilot transport request failed",
       retryable?: kind in [:timeout, :unavailable, :transport_error, :rate_limited],
       dispatch_provenance: provenance
     )}
  end

  defp http_kind(429), do: :rate_limited
  defp http_kind(status) when status in [401, 403], do: :authentication_failed
  defp http_kind(status) when status >= 500, do: :unavailable
  defp http_kind(_), do: :invalid_request
  defp credential(nil), do: {:ok, Credential.none()}
  defp credential(secret), do: Credential.bearer(secret)
  defp now, do: System.monotonic_time(:millisecond)
end
