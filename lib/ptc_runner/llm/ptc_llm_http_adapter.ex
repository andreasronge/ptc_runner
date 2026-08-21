if Code.ensure_loaded?(PtcLlmHttp) do
  defmodule PtcRunner.LLM.PtcLlmHttpAdapter do
    @moduledoc """
    Opt-in LLM adapter using `ptc_llm_http` `0.1.0`.

    `PtcRunner.LLM.ReqLLMAdapter` remains the shipped default. A downstream host
    selects this adapter with ordinary application configuration after adding the
    exact optional dependency:

        {:ptc_llm_http, "== 0.1.0"}

        config :ptc_runner,
               :llm_adapter,
               PtcRunner.LLM.PtcLlmHttpAdapter

    Then run an existing model-backed project through the host Mix command:

        mix ptc run examples/kernel-tutorial/02-deepseek-extract.ptc-project.json

    ## Supported selectors

    Preparation accepts `openrouter:model` and `openai-compat:base_url|model`.
    OpenRouter targets use `https://openrouter.ai/api/v1` with the public connect
    policy. Direct OpenAI-compatible URLs must be a credential-free HTTP loopback
    IP or an HTTPS hostname; other shapes are rejected rather than forwarded to
    ReqLLM.

    ## Ownership

    PtcRunner owns selector parsing, target construction, credential wrapping,
    request and response limits, the absolute deadline, the attempt process
    budget, retry refusal, usage projection, tracing redaction, and error
    classification. `PtcRunner.LLM.PtcLlmHttpRuntime` supervises the PtcLlmHttp
    Runtime. This adapter never starts unowned global processes per request and
    never exposes PtcLlmHttp types to callers.
    """

    @behaviour PtcRunner.LLM

    alias PtcLlmHttp.{
      Credential,
      Deadline,
      Error,
      ProcessBudget,
      Request,
      Response,
      StreamComplete
    }

    alias PtcLlmHttp.{Target, ToolCall, Usage}
    alias PtcRunner.Kernel.ProviderError
    alias PtcRunner.LLM.PtcLlmHttpPreparedModel
    alias PtcRunner.LLM.PtcLlmHttpRuntime

    @openrouter_base_url "https://openrouter.ai/api/v1"
    @default_timeout_ms 120_000
    @default_process_budget_words 4_000_000
    @max_encoded_request_bytes 1_048_576
    @max_wire_response_bytes 1_048_576

    @impl true
    @spec ensure_ready() :: :ok
    def ensure_ready, do: :ok

    @impl true
    @spec provider_application(String.t()) :: nil
    def provider_application(_model), do: nil

    @impl true
    @spec public_model(String.t()) :: {:ok, String.t()} | :private
    def public_model("openrouter:" <> rest = model) when rest != "", do: {:ok, model}
    def public_model(_model), do: :private

    @impl true
    @spec prepare_model(String.t()) ::
            {:ok, PtcLlmHttpPreparedModel.t(), PtcRunner.LLM.catalog_status()}
            | {:error, ProviderError.t()}
    def prepare_model(model) when is_binary(model) do
      with {:ok, spec} <- selector(model),
           {:ok, target} <- target(spec) do
        prepared = %PtcLlmHttpPreparedModel{selector: model, target: target}
        {:ok, prepared, catalog_status(spec)}
      end
    end

    def prepare_model(_model), do: {:error, unsupported_selector_error()}

    @impl true
    @spec call(PtcLlmHttpPreparedModel.t() | String.t(), map()) ::
            {:ok, map()} | {:error, ProviderError.t()}
    def call(%PtcLlmHttpPreparedModel{} = prepared, req) when is_map(req) do
      invoke(prepared, req, :call)
    end

    def call(model, req) when is_binary(model) and is_map(req) do
      with {:ok, prepared, _status} <- prepare_model(model) do
        call(prepared, req)
      end
    end

    def call(_model, _req), do: {:error, invalid_request_error("LLM request is invalid")}

    @impl true
    @spec stream(PtcLlmHttpPreparedModel.t() | String.t(), map(), (map() -> term())) ::
            {:ok, map()} | {:error, ProviderError.t()}
    def stream(%PtcLlmHttpPreparedModel{} = prepared, req, on_delta)
        when is_map(req) and is_function(on_delta, 1) do
      invoke(prepared, req, {:stream, on_delta})
    end

    def stream(model, req, on_delta) when is_binary(model) and is_function(on_delta, 1) do
      with {:ok, prepared, _status} <- prepare_model(model) do
        stream(prepared, req, on_delta)
      end
    end

    def stream(_model, _req, _on_delta),
      do: {:error, invalid_request_error("LLM stream request is invalid")}

    defp invoke(prepared, req, mode) do
      with {:ok, runtime} <- owned_runtime(),
           {:ok, request} <- request(req),
           {:ok, credential} <- credential(req),
           {:ok, deadline} <- deadline(req),
           {:ok, budget} <- process_budget(req) do
        dispatch(mode, runtime, prepared.target, request, credential, deadline, budget)
      end
    end

    defp dispatch(:call, runtime, target, request, credential, deadline, budget) do
      runtime
      |> PtcLlmHttp.call(target, request,
        credential: credential,
        deadline: deadline,
        process_budget: budget
      )
      |> normalize_call()
    end

    defp dispatch({:stream, on_delta}, runtime, target, request, credential, deadline, budget) do
      acc = :ets.new(__MODULE__, [:set, :public])
      :ets.insert(acc, {:content, ""})

      try do
        runtime
        |> PtcLlmHttp.stream(
          target,
          request,
          &stream_delta(&1, on_delta, acc),
          credential: credential,
          deadline: deadline,
          process_budget: budget
        )
        |> normalize_stream(acc)
      after
        :ets.delete(acc)
      end
    end

    defp stream_delta(%{delta: text} = chunk, on_delta, acc) when is_binary(text) do
      [{_key, content}] = :ets.lookup(acc, :content)
      :ets.insert(acc, {:content, content <> text})
      on_delta.(%{delta: text})
      :cont
    end

    defp stream_delta(_chunk, _on_delta, _acc), do: :cont

    defp normalize_call({:ok, %Response{} = response}) do
      {:ok,
       normalize_response(
         Response.content(response),
         Response.tool_calls(response),
         Response.usage(response)
       )}
    end

    defp normalize_call({:error, %Error{} = error}), do: {:error, classify(error)}

    defp normalize_call(_invalid),
      do: {:error, invalid_request_error("LLM provider returned an invalid result")}

    defp normalize_stream({:ok, %StreamComplete{} = complete}, acc) do
      content = accumulated_content(acc)

      {:ok,
       %{
         content: content,
         tokens: normalize_usage(StreamComplete.usage(complete))
       }}
    end

    defp normalize_stream({:error, %Error{} = error}, _acc), do: {:error, classify(error)}

    defp normalize_stream({:halted, _halt}, _acc),
      do: {:error, invalid_request_error("LLM stream halted before completion")}

    defp normalize_stream(_invalid, _acc),
      do: {:error, invalid_request_error("LLM provider returned an invalid stream result")}

    defp accumulated_content(acc) do
      case :ets.lookup(acc, :content) do
        [{:content, content}] when is_binary(content) -> content
        _missing -> ""
      end
    end

    defp normalize_response(content, [], usage) do
      %{content: content || "", tokens: normalize_usage(usage)}
    end

    defp normalize_response(content, tool_calls, usage) do
      %{
        content: content,
        tool_calls: Enum.map(tool_calls, &normalize_tool_call/1),
        tokens: normalize_usage(usage)
      }
    end

    defp normalize_tool_call(tool_call) do
      %{
        id: ToolCall.id(tool_call),
        name: ToolCall.name(tool_call),
        args: ToolCall.arguments(tool_call)
      }
    end

    defp normalize_usage(nil), do: %{}

    defp normalize_usage(%Usage{} = usage) do
      facts = Usage.facts(usage)

      [
        input: facts.prompt_tokens,
        output: facts.completion_tokens,
        cache_read: facts.cached_tokens,
        total_cost: facts.cost
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end

    defp owned_runtime do
      case PtcLlmHttpRuntime.runtime() do
        {:ok, pid} -> {:ok, pid}
        {:error, :runtime_unavailable} -> {:error, runtime_unavailable_error()}
      end
    end

    defp selector("openrouter:" <> model) when model != "" do
      if valid_identifier?(model),
        do: {:ok, {:openrouter, model}},
        else: {:error, unsupported_selector_error()}
    end

    defp selector("openai-compat:" <> rest) do
      case String.split(rest, "|", parts: 2) do
        [base_url, model] -> compat_selector(base_url, model)
        _other -> {:error, unsupported_selector_error()}
      end
    end

    defp selector(_model), do: {:error, unsupported_selector_error()}

    defp compat_selector(base_url, model) do
      if valid_identifier?(model) and is_binary(base_url) and base_url != "",
        do: {:ok, {:openai_compat, base_url, model}},
        else: {:error, unsupported_selector_error()}
    end

    defp valid_identifier?(value) when is_binary(value) do
      byte_size(value) in 1..256 and String.valid?(value) and
        Enum.all?(:binary.bin_to_list(value), &(&1 > 31 and &1 != 127))
    end

    defp valid_identifier?(_value), do: false

    defp target({:openrouter, model}) do
      build_target(
        model,
        @openrouter_base_url,
        :public,
        %{tokens: true, cost: false}
      )
    end

    defp target({:openai_compat, base_url, model}) do
      with {:ok, policy, usage} <- compat_policy(base_url) do
        build_target(model, base_url, policy, usage)
      end
    end

    defp compat_policy(base_url) do
      case URI.parse(base_url) do
        %URI{scheme: "http", host: host} = uri ->
          loopback_http_policy(host, uri)

        %URI{scheme: "https", host: host} when is_binary(host) ->
          https_policy(host)

        _invalid ->
          {:error, unsupported_selector_error()}
      end
    end

    defp loopback_http_policy(host, %URI{userinfo: nil, query: nil, fragment: nil})
         when is_binary(host) do
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, {127, _b, _c, _d}} ->
          {:ok, :literal_loopback, %{tokens: false, cost: false}}

        {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} ->
          {:ok, :literal_loopback, %{tokens: false, cost: false}}

        _other ->
          {:error, unsupported_selector_error()}
      end
    end

    defp loopback_http_policy(_host, _uri), do: {:error, unsupported_selector_error()}

    defp https_policy(host) do
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, _literal} -> {:error, unsupported_selector_error()}
        {:error, :einval} -> {:ok, :public, %{tokens: false, cost: false}}
      end
    end

    defp build_target(model, base_url, connect_policy, usage_guarantees) do
      case Target.new(
             kind: :openai_compat,
             base_url: base_url,
             model: model,
             capacity_group: PtcLlmHttpRuntime.capacity_group(),
             connect_policy: connect_policy,
             max_encoded_request_bytes: @max_encoded_request_bytes,
             max_wire_response_bytes: @max_wire_response_bytes,
             tools: true,
             streaming: true,
             structured_output: :json_schema,
             cache_mode: :unsupported,
             upstream_routing: :opaque,
             usage_guarantees: usage_guarantees
           ) do
        {:ok, target} -> {:ok, target}
        {:error, %Error{} = error} -> {:error, classify(error)}
      end
    end

    defp catalog_status({:openrouter, _model}), do: :unavailable
    defp catalog_status({:openai_compat, _base_url, _model}), do: :unavailable

    defp request(req) when is_map(req) do
      with {:ok, messages} <- messages(req),
           {:ok, tools} <- tools(req),
           {:ok, schema} <- response_schema(req) do
        opts =
          [messages: messages]
          |> maybe_put(:system, req[:system])
          |> maybe_put(:tools, tools)
          |> maybe_put(:response_schema, schema)
          |> maybe_put(:max_tokens, req[:max_tokens])
          |> maybe_put(:temperature, req[:temperature])
          |> maybe_put(:seed, req[:seed])
          |> maybe_put(:cache, req[:cache])

        case Request.new(opts) do
          {:ok, request} -> {:ok, request}
          {:error, %Error{} = error} -> {:error, classify(error)}
        end
      end
    end

    defp request(_req), do: {:error, invalid_request_error("LLM request is invalid")}

    defp maybe_put(opts, _key, nil), do: opts
    defp maybe_put(opts, :tools, []), do: opts
    defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

    defp messages(%{messages: messages}) when is_list(messages) and messages != [] do
      Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, acc} ->
        case message(message) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        error -> error
      end
    end

    defp messages(_req), do: {:error, invalid_request_error("LLM request messages are invalid")}

    defp message(%{role: role, content: content} = message)
         when map_size(message) == 2 and role in [:system, :user, :assistant] do
      {:ok, %{role: role, content: content}}
    end

    defp message(%{role: :assistant, content: content, tool_calls: calls} = message)
         when map_size(message) == 3 and is_list(calls) do
      with {:ok, calls} <- assistant_calls(calls) do
        {:ok, %{role: :assistant, content: content, tool_calls: calls}}
      end
    end

    defp message(%{role: :tool, tool_call_id: id, content: content} = message)
         when map_size(message) == 3 do
      {:ok, %{role: :tool, tool_call_id: id, content: content}}
    end

    defp message(_message), do: {:error, invalid_request_error("LLM request message is invalid")}

    defp assistant_calls(calls) do
      Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
        case assistant_call(call) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        error -> error
      end
    end

    defp assistant_call(%{id: id, name: name, args: args})
         when is_binary(id) and is_binary(name) and is_map(args) do
      {:ok, %{id: id, name: name, args: args}}
    end

    defp assistant_call(_call), do: {:error, invalid_request_error("LLM tool call is invalid")}

    defp tools(%{tools: tools}) when is_list(tools) do
      Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, acc} ->
        case tool(tool) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        error -> error
      end
    end

    defp tools(_req), do: {:ok, []}

    defp tool(%{"type" => "function", "function" => function}) when is_map(function) do
      name = function["name"]
      parameters = function["parameters"]
      description = function["description"]

      cond do
        not is_binary(name) or not is_map(parameters) ->
          {:error, invalid_request_error("LLM tool is invalid")}

        is_binary(description) and description != "" ->
          {:ok, %{name: name, description: description, parameters: parameters}}

        true ->
          {:ok, %{name: name, description: nil, parameters: parameters}}
      end
    end

    defp tool(_tool), do: {:error, invalid_request_error("LLM tool is invalid")}

    defp response_schema(%{schema: schema}) when is_map(schema) do
      {:ok, %{name: "response", schema: schema}}
    end

    defp response_schema(_req), do: {:ok, nil}

    defp credential(req) when is_map(req) do
      case Map.get(req, :api_key) do
        nil -> {:ok, Credential.none()}
        key when is_binary(key) and key != "" -> wrap_bearer(key)
        _invalid -> {:error, invalid_credential_error()}
      end
    end

    defp wrap_bearer(key) do
      case Credential.bearer(key) do
        {:ok, credential} -> {:ok, credential}
        {:error, %Error{} = error} -> {:error, classify(error)}
      end
    end

    defp deadline(req) when is_map(req) do
      timeout = Map.get(req, :receive_timeout, @default_timeout_ms)

      if is_integer(timeout) and timeout > 0 do
        case Deadline.new(System.monotonic_time(:millisecond) + timeout) do
          {:ok, deadline} -> {:ok, deadline}
          {:error, %Error{} = error} -> {:error, classify(error)}
        end
      else
        {:error, invalid_request_error("LLM request deadline is invalid")}
      end
    end

    defp process_budget(_req) do
      case ProcessBudget.new(total_heap_words: @default_process_budget_words) do
        {:ok, budget} -> {:ok, budget}
        {:error, %Error{} = error} -> {:error, classify(error)}
      end
    end

    defp classify(%Error{} = error) do
      kind = error.kind
      status = error.http_status
      {error_kind, retryable?} = error_class(kind, status, error.provider_code)

      opts =
        [dispatch_provenance: provenance(error.dispatch)]
        |> maybe_indeterminate(error.dispatch)

      ProviderError.new(
        error_kind,
        details(kind, status),
        Keyword.put(opts, :retryable?, retryable?)
      )
    end

    defp maybe_indeterminate(opts, :possibly_sent),
      do: Keyword.put(opts, :mutation_state, :indeterminate)

    defp maybe_indeterminate(opts, _dispatch), do: opts

    defp provenance(:not_sent), do: :not_dispatched
    defp provenance(:completed), do: :dispatched
    defp provenance(:possibly_sent), do: :possibly_dispatched

    @error_classes %{
      deadline_exceeded: {:timeout, true},
      capacity_exhausted: {:unavailable, true},
      runtime_unavailable: {:internal, false},
      internal_failure: {:internal, false},
      resource_limit_exceeded: {:invalid_result, false},
      connection_closed: {:transport_error, true},
      connect_failure: {:transport_error, true},
      dns_failure: {:transport_error, true},
      malformed_http: {:transport_error, true},
      tls_failure: {:transport_error, false},
      address_rejected: {:transport_error, false},
      unsupported_redirect: {:transport_error, false},
      unsupported_content_encoding: {:transport_error, false},
      unsupported_transfer_encoding: {:transport_error, false},
      unsupported_framing: {:transport_error, false},
      callback_failed: {:internal, false},
      invalid_request: {:invalid_request, false},
      invalid_target: {:invalid_request, false},
      invalid_credential: {:authentication_failed, false},
      unsupported_capability: {:invalid_request, false},
      invalid_tool_arguments: {:invalid_request, false},
      malformed_provider_response: {:invalid_result, false},
      malformed_stream: {:invalid_result, false},
      response_too_large: {:invalid_result, false},
      stream_too_large: {:invalid_result, false},
      provider_result_too_large: {:invalid_result, false},
      model_refusal: {:denied, false}
    }

    defp error_class(:http_status, status, _code) when is_integer(status),
      do: {http_error_kind(status), http_retryable?(status)}

    defp error_class(kind, _status, _code),
      do: Map.get(@error_classes, kind, {:unavailable, true})

    defp http_error_kind(401), do: :authentication_failed
    defp http_error_kind(402), do: :payment_required
    defp http_error_kind(403), do: :denied
    defp http_error_kind(404), do: :not_found
    defp http_error_kind(408), do: :timeout
    defp http_error_kind(429), do: :rate_limited
    defp http_error_kind(status) when status in 400..499, do: :invalid_request
    defp http_error_kind(status) when status in 500..599, do: :unavailable
    defp http_error_kind(_status), do: :unavailable

    defp http_retryable?(status) when status in [408, 409, 425, 429], do: true
    defp http_retryable?(status) when status in 500..599, do: true
    defp http_retryable?(_status), do: false

    defp details(:http_status, status) when is_integer(status), do: "HTTP #{status}"
    defp details(:deadline_exceeded, _status), do: "LLM request exceeded its deadline"
    defp details(:connection_closed, _status), do: "LLM transport connection closed"
    defp details(:callback_failed, _status), do: "LLM stream callback failed"
    defp details(:capacity_exhausted, _status), do: "LLM adapter capacity is exhausted"
    defp details(:runtime_unavailable, _status), do: "LLM adapter runtime is unavailable"
    defp details(:invalid_credential, _status), do: "LLM credential is invalid"

    defp details(:unsupported_capability, _status),
      do: "LLM request is not supported by this adapter"

    defp details(:invalid_target, _status), do: "LLM model selector is not supported"
    defp details(_kind, _status), do: "LLM provider unavailable"

    defp unsupported_selector_error do
      ProviderError.new(
        :invalid_request,
        "LLM model selector is not supported by PtcLlmHttpAdapter",
        retryable?: false,
        dispatch_provenance: :not_dispatched
      )
    end

    defp invalid_request_error(details) do
      ProviderError.new(:invalid_request, details,
        retryable?: false,
        dispatch_provenance: :not_dispatched
      )
    end

    defp invalid_credential_error,
      do:
        ProviderError.new(:authentication_failed, "LLM credential is invalid",
          retryable?: false,
          dispatch_provenance: :not_dispatched
        )

    defp runtime_unavailable_error,
      do:
        ProviderError.new(:internal, "LLM adapter runtime is unavailable",
          retryable?: false,
          dispatch_provenance: :not_dispatched
        )
  end
else
  defmodule PtcRunner.LLM.PtcLlmHttpAdapter do
    @moduledoc """
    Opt-in LLM adapter using `ptc_llm_http` `0.1.0`.

    This module is present so hosts can name it in application configuration.
    Requests fail during preparation until the exact optional dependency is
    installed; they never fall back to ReqLLM.
    """

    @behaviour PtcRunner.LLM

    alias PtcRunner.Kernel.ProviderError

    @impl true
    def call(_model, _request), do: {:error, missing_dependency()}

    @impl true
    def stream(_model, _request, _on_delta), do: {:error, missing_dependency()}

    @impl true
    def prepare_model(_model), do: {:error, missing_dependency()}

    @impl true
    def provider_application(_model), do: nil

    @impl true
    def public_model(_model), do: :private

    @impl true
    def ensure_ready, do: :ok

    defp missing_dependency do
      ProviderError.new(
        :internal,
        "PtcLlmHttpAdapter requires {:ptc_llm_http, \"== 0.1.0\"} as an optional dependency",
        retryable?: false,
        dispatch_provenance: :not_dispatched
      )
    end
  end
end
