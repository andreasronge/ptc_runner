if Code.ensure_loaded?(ReqLLM) do
  defmodule PtcRunner.LLM.ReqLLMAdapter do
    @moduledoc """
    Built-in LLM adapter using `req_llm`.

    Routes requests based on model prefix:
    - `ollama:model-name` → Local Ollama server
    - `openai-compat:base_url|model` → Any OpenAI-compatible API
    - `*` → ReqLLM (OpenRouter, Anthropic, Google, Bedrock, etc.)

    Requires `{:req_llm, "~> 1.8"}` as a dependency.

    ## Failure classification

    The adapter boundary converts expected provider, HTTP, and transport
    failures into bounded `PtcRunner.Kernel.ProviderError` values. HTTP status
    and the dependency's human-readable reason may reach private inspection;
    request bodies, response bodies, headers, causes, and arbitrary exception
    inspection do not cross the boundary.

    ## Prompt Caching

    When `cache: true` is set in the request, prompt caching is enabled for
    supported providers (Anthropic direct, OpenRouter Anthropic, Bedrock Claude).

    ## Bedrock Region

    For Bedrock models, the region is determined in this order:
    1. `AWS_REGION` environment variable
    2. `config :ptc_runner, :bedrock_region, "region-name"`
    3. Default: `"eu-north-1"`
    """

    @behaviour PtcRunner.LLM

    alias PtcRunner.Kernel.ProviderError
    alias PtcRunner.LLM.Invocation
    alias PtcRunner.LLM.OutputLimit
    alias PtcRunner.LLM.ReqLLMPreparedModel
    alias PtcRunner.LLM.Requirements
    alias ReqLLM.Message
    alias ReqLLM.Message.ContentPart
    alias ReqLLM.ModelHelpers
    alias ReqLLM.Provider.Options
    alias ReqLLM.Providers.XAI

    require Logger

    @default_timeout 120_000
    @default_max_tokens 4_096
    @request_token_headroom 256
    @ollama_base_url "http://localhost:11434"
    @default_bedrock_region "eu-north-1"
    @req_llm_generation_options [
      :api_key,
      :max_tokens,
      :max_retries,
      :on_unsupported,
      :provider_options,
      :seed,
      :temperature,
      :tool_choice
    ]
    @token_limit_options [:max_tokens, :max_completion_tokens, :max_output_tokens]
    # ReqLLM gives these providers richer uncataloged fallbacks than its
    # documented generic inline form. Keep only the dispatch list here and let
    # ReqLLM's public string resolver construct each target. Generic providers
    # use the documented inline form so the dependency warning never escapes.
    @req_llm_special_fallback_providers [:github_copilot, :minimax, :mistral, :openai_codex]
    # Consulted only for `{:req_llm, selector}` routes. Direct `ollama:` and
    # `openai-compat:` HTTP routes never reach this list and are refused for
    # both structured modes.
    @native_json_schema_providers [
      :anthropic,
      :fireworks_ai,
      :google,
      :openai,
      :openrouter,
      :xai
    ]
    @native_json_object_providers [
      :azure,
      :fireworks_ai,
      :groq,
      :openai,
      :openrouter,
      :xai
    ]

    # --- Behaviour Callbacks ---

    @impl true
    @doc """
    Loads the `llm_db` model catalog into its VM-global `:persistent_term`
    store so per-request provider workers read it copy-free instead of
    triggering a large one-time decode inside their bounded heap. Idempotent;
    called during provider-application admission and at capability build for
    direct embedding paths.
    """
    @spec ensure_ready() :: :ok
    def ensure_ready do
      if Code.ensure_loaded?(LLMDB.Catalog) and
           function_exported?(LLMDB.Catalog, :ensure_loaded, 0) do
        _ = LLMDB.Catalog.ensure_loaded()
      end

      :ok
    end

    # Only the ReqLLM route needs the :req_llm application; `ollama:` and
    # `openai-compat:` models are plain Req calls that work without it. Routing
    # through parse_provider/1 keeps this answer from drifting from generate_text/3.
    @impl true
    @spec provider_application(String.t()) :: :req_llm | nil
    def provider_application(model) do
      case parse_provider(model) do
        {:req_llm, _model_id} -> :req_llm
        _direct_http -> nil
      end
    end

    # ReqLLM model selectors are provider/model identifiers. Direct HTTP routes
    # can contain local names or operator endpoints, so they remain private.
    @impl true
    @spec public_model(String.t()) :: {:ok, String.t()} | :private
    def public_model(model) do
      case parse_provider(model) do
        {:req_llm, _model_id} -> {:ok, model}
        _direct_http -> :private
      end
    end

    @impl true
    @spec prepare_model(String.t(), Requirements.t()) ::
            {:ok, ReqLLMPreparedModel.t(), PtcRunner.LLM.catalog_status(), Requirements.t()}
            | {:error, term()}
    def prepare_model(model, requirements) when is_binary(model) do
      with {:ok, canonical} <- Requirements.canonical(requirements),
           :ok <- attest_structured_requirements(model, canonical) do
        case parse_provider(model) do
          {:req_llm, selector} ->
            prepare_req_llm_target(selector, canonical)

          _direct_http ->
            {:ok, direct_target(model, canonical), :unavailable, canonical}
        end
      else
        :error -> {:error, :unsupported_model_option}
        {:error, _reason} = error -> error
      end
    end

    def prepare_model(_model, _requirements), do: {:error, :invalid_model}

    # Catalog-free local preflight: refuse contracts this adapter already knows
    # it cannot honor, without loading llm_db inside the audited-local worker.
    @doc false
    @spec local_contract_attestation(String.t(), Requirements.t()) ::
            :ok | {:error, :unsupported_model_option}
    def local_contract_attestation(model, requirements) when is_binary(model) do
      with {:ok, canonical} <- Requirements.canonical(requirements),
           :ok <- attest_structured_requirements(model, canonical) do
        case parse_provider(model) do
          {:req_llm, selector} -> refuse_lossy_max_tokens(selector)
          _direct_http -> :ok
        end
      else
        :error -> {:error, :unsupported_model_option}
        {:error, :unsupported_model_option} = error -> error
      end
    end

    def local_contract_attestation(_model, _requirements), do: :ok

    @impl true
    @spec call(ReqLLMPreparedModel.t(), Invocation.t()) ::
            {:ok, map()} | {:error, ProviderError.t()}
    def call(%ReqLLMPreparedModel{} = target, %Invocation{} = invocation) do
      if Invocation.valid?(invocation) do
        dispatch_invocation(target, invocation)
      else
        {:error, ProviderError.new(:invalid_request, "invalid LLM invocation")}
      end
    end

    def call(_target, _invocation),
      do: {:error, ProviderError.new(:invalid_request, "invalid LLM invocation")}

    # --- Public API ---

    @doc """
    Generate text from an LLM.

    ## Options
    - `:receive_timeout` - Request timeout in ms (default: #{@default_timeout})
    - `:ollama_base_url` - Override Ollama server URL
    - `:cache` - Enable prompt caching for supported providers (default: false)
    - `:max_tokens` - Output budget. ReqLLM-backed models default to at most
      #{@default_max_tokens}, bounded by cataloged output and context limits.
    """
    @spec generate_text(String.t() | ReqLLMPreparedModel.t(), [map()], keyword()) ::
            {:ok, PtcRunner.LLM.response()} | {:error, term()}
    def generate_text(model, messages, opts \\ [])

    def generate_text(%ReqLLMPreparedModel{model: %LLMDB.Model{}} = model, messages, opts),
      do: call_req_llm(model, messages, merge_exact_options(model, opts))

    def generate_text(%ReqLLMPreparedModel{selector: selector} = target, messages, opts),
      do: generate_text(selector, messages, merge_exact_options(target, opts))

    def generate_text(model, messages, opts) do
      case parse_provider(model) do
        {:ollama, model_name} ->
          call_ollama(model_name, messages, opts)

        {:openai_compat, base_url, model_name} ->
          call_openai_compat(base_url, model_name, messages, opts)

        {:req_llm, model_id} ->
          with {:ok, prepared, _status} <- prepare_req_llm_model(model_id),
               do: call_req_llm(prepared, messages, opts)
      end
    end

    @doc """
    Generate text, raising on error.
    """
    @spec generate_text!(String.t(), [map()], keyword()) :: PtcRunner.LLM.response()
    def generate_text!(model, messages, opts \\ []) do
      case generate_text(model, messages, opts) do
        {:ok, response} -> response
        {:error, reason} -> raise "LLM error: #{inspect(reason)}"
      end
    end

    @doc """
    Generate a structured JSON object from an LLM.

    Only supported for ReqLLM providers whose sealed mode is attested.
    Direct `ollama:` and `openai-compat:` routes return
    `{:error, :structured_output_not_supported}`.
    """
    @spec generate_object(String.t() | ReqLLMPreparedModel.t(), [map()], map(), keyword()) ::
            {:ok, map()} | {:error, term()}
    def generate_object(model, messages, schema, opts \\ [])

    def generate_object(
          %ReqLLMPreparedModel{model: %LLMDB.Model{}} = model,
          messages,
          schema,
          opts
        ),
        do: call_req_llm_object(model, messages, schema, merge_exact_options(model, opts))

    def generate_object(
          %ReqLLMPreparedModel{selector: selector} = target,
          messages,
          schema,
          opts
        ),
        do: generate_object(selector, messages, schema, merge_exact_options(target, opts))

    def generate_object(model, messages, schema, opts) do
      case parse_provider(model) do
        {:ollama, _model_name} ->
          {:error, :structured_output_not_supported}

        {:openai_compat, _base_url, _model_name} ->
          {:error, :structured_output_not_supported}

        {:req_llm, model_id} ->
          with {:ok, prepared, _status} <- prepare_req_llm_model(model_id),
               do: call_req_llm_object(prepared, messages, schema, opts)
      end
    end

    @doc """
    Generate a structured JSON object, raising on error.
    """
    @spec generate_object!(String.t(), [map()], map(), keyword()) :: map()
    def generate_object!(model, messages, schema, opts \\ []) do
      case generate_object(model, messages, schema, opts) do
        {:ok, response} -> response
        {:error, reason} -> raise "LLM structured output error: #{inspect(reason)}"
      end
    end

    @doc """
    Generate text with tool definitions.

    Passes tools to the LLM provider. If the LLM returns tool calls,
    they are included in the response as `tool_calls`.
    """
    @spec generate_with_tools(String.t() | ReqLLMPreparedModel.t(), [map()], [map()], keyword()) ::
            {:ok, map()} | {:error, term()}
    def generate_with_tools(model, messages, tools, opts \\ [])

    def generate_with_tools(
          %ReqLLMPreparedModel{model: %LLMDB.Model{}} = model,
          messages,
          tools,
          opts
        ),
        do: call_req_llm_with_tools(model, messages, tools, merge_exact_options(model, opts))

    def generate_with_tools(
          %ReqLLMPreparedModel{selector: selector} = target,
          messages,
          tools,
          opts
        ),
        do: generate_with_tools(selector, messages, tools, merge_exact_options(target, opts))

    def generate_with_tools(model, messages, tools, opts) do
      case parse_provider(model) do
        {:ollama, _model_name} ->
          {:error, :tool_calling_not_supported}

        {:openai_compat, _base_url, _model_name} ->
          {:error, :tool_calling_not_supported}

        {:req_llm, model_id} ->
          with {:ok, prepared, _status} <- prepare_req_llm_model(model_id),
               do: call_req_llm_with_tools(prepared, messages, tools, opts)
      end
    end

    @doc """
    Generate embeddings for text input.

    ## Returns
    - `{:ok, [float()]}` for single input
    - `{:ok, [[float()]]}` for batch input
    """
    @spec embed(String.t(), String.t() | [String.t()], keyword()) ::
            {:ok, [float()] | [[float()]]} | {:error, term()}
    def embed(model, input, opts \\ []) do
      case parse_provider(model) do
        {:ollama, model_name} ->
          call_ollama_embed(model_name, input, opts)

        {:openai_compat, base_url, model_name} ->
          call_openai_compat_embed(base_url, model_name, input, opts)

        {:req_llm, model_id} ->
          ReqLLM.Embedding.embed(model_id, input, opts)
      end
    end

    @doc """
    Generate embeddings, raising on error.
    """
    @spec embed!(String.t(), String.t() | [String.t()], keyword()) :: [float()] | [[float()]]
    def embed!(model, input, opts \\ []) do
      case embed(model, input, opts) do
        {:ok, result} -> result
        {:error, reason} -> raise "Embedding error: #{inspect(reason)}"
      end
    end

    @doc """
    Check if a provider is available.

    For Ollama, checks if the server is reachable.
    For ReqLLM providers, checks if the required API key is set.
    """
    @spec available?(String.t()) :: boolean()
    def available?(model) do
      case parse_provider(model) do
        {:ollama, _} ->
          check_ollama_available()

        {:openai_compat, base_url, _} ->
          check_openai_compat_available(base_url)

        {:req_llm, model_id} ->
          check_req_llm_available(model_id)
      end
    end

    @doc """
    Check if the model requires an API key.
    """
    @spec requires_api_key?(String.t()) :: boolean()
    def requires_api_key?(model) do
      case parse_provider(model) do
        {:ollama, _} -> false
        {:openai_compat, _, _} -> false
        {:req_llm, _} -> true
      end
    end

    # --- Provider Implementations ---

    defp call_ollama(model, messages, opts) do
      base_url = Keyword.get(opts, :ollama_base_url, @ollama_base_url)
      timeout = Keyword.get(opts, :receive_timeout, @default_timeout)
      http_opts = Keyword.get(opts, :req_http_options, [])

      prompt = format_messages_as_prompt(messages)

      Logger.debug("Calling Ollama: #{model}")

      options =
        opts
        |> Keyword.take([:temperature, :seed])
        |> Enum.into(%{})
        |> maybe_put_ollama_max_tokens(opts)

      request_opts =
        [
          json: %{model: model, prompt: prompt, stream: false, options: options},
          receive_timeout: timeout
        ] ++ http_opts

      case Req.post("#{base_url}/api/generate", request_opts) do
        {:ok, %{status: 200, body: %{"response" => text} = body}} ->
          tokens = extract_ollama_tokens(body) |> add_cache_fields()
          {:ok, %{content: text, tokens: tokens}}

        {:ok, %{status: status, body: body}} ->
          {:error, %{status: status, body: body}}

        {:error, %{reason: :econnrefused}} ->
          {:error, "Ollama is unavailable. Start it with: ollama serve"}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp call_openai_compat(base_url, model, messages, opts) do
      timeout = Keyword.get(opts, :receive_timeout, @default_timeout)
      http_opts = Keyword.get(opts, :req_http_options, [])
      generation_opts = Keyword.take(opts, [:max_tokens, :seed, :temperature])

      formatted_messages =
        Enum.map(messages, fn msg ->
          %{"role" => to_string(msg.role), "content" => msg.content}
        end)

      request_opts =
        [
          json:
            Map.merge(%{model: model, messages: formatted_messages}, Map.new(generation_opts)),
          receive_timeout: timeout
        ] ++ http_opts

      case Req.post("#{base_url}/chat/completions", request_opts) do
        {:ok, %{status: 200, body: body}} ->
          text = get_in(body, ["choices", Access.at(0), "message", "content"]) || ""
          usage = body["usage"] || %{}

          tokens =
            %{
              input: usage["prompt_tokens"] || 0,
              output: usage["completion_tokens"] || 0
            }
            |> add_cache_fields()

          {:ok, %{content: text, tokens: tokens}}

        {:ok, %{status: status, body: body}} ->
          {:error, %{status: status, body: body}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp call_req_llm(%ReqLLMPreparedModel{selector: model, model: req_llm_model}, messages, opts) do
      timeout = Keyword.get(opts, :receive_timeout, @default_timeout)
      http_opts = Keyword.get(opts, :req_http_options, [])
      cache_enabled = Keyword.get(opts, :cache, false)

      generation_opts = req_llm_generation_opts(opts, req_llm_model, messages)

      {messages, extra_opts} = apply_caching(model, messages, cache_enabled)
      extra_opts = apply_bedrock_region(model, extra_opts)

      req_opts =
        [receive_timeout: timeout, req_http_options: http_opts]
        |> Keyword.merge(generation_opts)
        |> Keyword.merge(extra_opts)

      case ReqLLM.generate_text(req_llm_model, messages, req_opts) do
        {:ok, response} ->
          text = ReqLLM.Response.text(response) || ""
          usage = ReqLLM.Response.usage(response) || %{}
          tokens = build_tokens_from_req_llm_response(usage, response.provider_meta)

          {:ok, %{content: text, tokens: tokens}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp call_req_llm_object(
           %ReqLLMPreparedModel{selector: model, model: req_llm_model},
           messages,
           schema,
           opts
         ) do
      if native_json_schema_model?(req_llm_model) do
        timeout = Keyword.get(opts, :receive_timeout, @default_timeout)
        http_opts = Keyword.get(opts, :req_http_options, [])
        cache_enabled = Keyword.get(opts, :cache, false)

        generation_opts =
          opts
          |> req_llm_generation_opts(req_llm_model, {messages, schema})
          |> put_json_schema_native_mode(req_llm_model)

        {messages, extra_opts} = apply_caching(model, messages, cache_enabled)
        extra_opts = apply_bedrock_region(model, extra_opts)

        req_opts =
          [receive_timeout: timeout, req_http_options: http_opts]
          |> Keyword.merge(generation_opts)
          |> Keyword.merge(extra_opts)

        case ReqLLM.generate_object(req_llm_model, messages, schema, req_opts) do
          {:ok, response} ->
            usage = ReqLLM.Response.usage(response) || %{}
            tokens = build_tokens_from_req_llm_response(usage, response.provider_meta)

            {:ok, %{object: response.object, tokens: tokens}}

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:error, :unsupported_model_option}
      end
    end

    defp call_req_llm_with_tools(
           %ReqLLMPreparedModel{selector: model, model: req_llm_model},
           messages,
           tools,
           opts
         ) do
      timeout = Keyword.get(opts, :receive_timeout, @default_timeout)
      http_opts = Keyword.get(opts, :req_http_options, [])
      cache_enabled = Keyword.get(opts, :cache, false)

      request_payload = {messages, tools}
      generation_opts = req_llm_generation_opts(opts, req_llm_model, request_payload)

      {messages, extra_opts} = apply_caching(model, messages, cache_enabled)
      extra_opts = apply_bedrock_region(model, extra_opts)

      req_llm_tools = Enum.map(tools, &to_req_llm_tool/1)

      req_opts =
        [receive_timeout: timeout, req_http_options: http_opts, tools: req_llm_tools]
        |> Keyword.merge(generation_opts)
        |> Keyword.merge(extra_opts)

      output_limit =
        effective_output_limit_metadata(
          opts,
          req_llm_model,
          request_payload,
          messages,
          req_opts
        )

      case ReqLLM.generate_text(req_llm_model, messages, req_opts) do
        {:ok, response} ->
          text = ReqLLM.Response.text(response)
          usage = ReqLLM.Response.usage(response) || %{}
          tokens = build_tokens_from_req_llm_response(usage, response.provider_meta)
          raw_tool_calls = ReqLLM.Response.tool_calls(response)

          result =
            if raw_tool_calls != [] do
              %{tool_calls: normalize_tool_calls(raw_tool_calls), content: text, tokens: tokens}
            else
              %{content: text || "", tokens: tokens}
            end

          {:ok, put_finish_metadata(result, response, output_limit)}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp normalize_call_result(result, mode \\ :ordinary)

    defp normalize_call_result({:error, reason}, mode), do: provider_failure(reason, mode)
    defp normalize_call_result(result, _mode), do: result

    @doc false
    @spec normalize_provider_call(term(), atom()) :: {:ok, map()} | {:error, ProviderError.t()}
    def normalize_provider_call(result, mode \\ :ordinary),
      do: normalize_call_result(result, mode)

    defp provider_failure(reason, mode), do: {:error, normalize_provider_error(reason, mode)}

    defp normalize_provider_error(reason, :tools) do
      case tool_calling_unsupported_details(reason) do
        {:ok, details} -> ProviderError.new(:tool_calling_unsupported, details)
        :error -> normalize_provider_error(reason)
      end
    end

    defp normalize_provider_error(reason, _mode), do: normalize_provider_error(reason)

    defp normalize_provider_error(%ProviderError{} = error), do: error

    defp normalize_provider_error(%ReqLLM.Error.API.Request{status: status} = error)
         when is_integer(status) do
      ProviderError.new(
        http_error_kind(status),
        http_error_details(status, error.reason),
        retryable?: http_retryable?(status, error.retryable)
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
        retryable?: http_retryable?(status, nil)
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
        retryable?: http_retryable?(status, nil)
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
      do: ProviderError.new(:invalid_request, "LLM adapter route does not support tool calling")

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

    @doc false
    def normalize_tool_calls(raw_tool_calls) do
      Enum.map(raw_tool_calls, fn tc ->
        {args, args_error} =
          case Jason.decode(tc.function.arguments || "{}") do
            {:ok, parsed} -> {parsed, nil}
            {:error, _} -> {%{}, "Invalid JSON arguments: #{tc.function.arguments}"}
          end

        entry = %{id: tc.id, name: tc.function.name, args: args}
        if args_error, do: Map.put(entry, :args_error, args_error), else: entry
      end)
    end

    defp to_req_llm_tool(%{"type" => "function", "function" => func}) do
      tool_opts = [
        name: func["name"],
        description: func["description"] || "",
        parameter_schema: func["parameters"],
        callback: fn _args -> nil end
      ]

      {:ok, tool} = ReqLLM.Tool.new(tool_opts)
      tool
    end

    # --- Embeddings ---

    defp call_ollama_embed(model, input, opts) do
      base_url = Keyword.get(opts, :ollama_base_url, @ollama_base_url)
      timeout = Keyword.get(opts, :receive_timeout, @default_timeout)

      case Req.post("#{base_url}/api/embed",
             json: %{model: model, input: input},
             receive_timeout: timeout
           ) do
        {:ok, %{status: 200, body: %{"embeddings" => [embedding]}}} when is_binary(input) ->
          {:ok, embedding}

        {:ok, %{status: 200, body: %{"embeddings" => embeddings}}} ->
          {:ok, embeddings}

        {:ok, %{status: status, body: body}} ->
          {:error, %{status: status, body: body}}

        {:error, %{reason: :econnrefused}} ->
          {:error, "Ollama is unavailable. Start it with: ollama serve"}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp call_openai_compat_embed(base_url, model, input, opts) do
      timeout = Keyword.get(opts, :receive_timeout, @default_timeout)

      case Req.post("#{base_url}/embeddings",
             json: %{model: model, input: input},
             receive_timeout: timeout
           ) do
        {:ok, %{status: 200, body: %{"data" => [%{"embedding" => embedding}]}}}
        when is_binary(input) ->
          {:ok, embedding}

        {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
          embeddings =
            data
            |> Enum.sort_by(& &1["index"])
            |> Enum.map(& &1["embedding"])

          {:ok, embeddings}

        {:ok, %{status: status, body: body}} ->
          {:error, %{status: status, body: body}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    # --- Message Building ---

    @doc false
    def build_messages(req) do
      system_msgs =
        if sys = req[:system], do: [%{role: :system, content: sys}], else: []

      user_msgs =
        Enum.map(req.messages, fn
          %{role: :tool} = msg ->
            %Message{
              role: :tool,
              content: [ContentPart.text(msg.content)],
              tool_call_id: msg[:tool_call_id]
            }

          %{role: role, content: content, tool_calls: tool_calls}
          when is_list(tool_calls) ->
            req_llm_tool_calls =
              Enum.map(tool_calls, fn tc ->
                %ReqLLM.ToolCall{
                  id: tc[:id] || tc["id"],
                  type: "function",
                  function: tool_call_function(tc)
                }
              end)

            %Message{
              role: role,
              content: if(content, do: [ContentPart.text(content)], else: []),
              tool_calls: req_llm_tool_calls
            }

          %{role: role, content: content} when is_binary(content) ->
            %{role: role, content: content}

          msg ->
            msg
        end)

      system_msgs ++ user_msgs
    end

    defp tool_call_function(tc) do
      case tc[:function] || tc["function"] do
        function when is_map(function) ->
          function

        _function ->
          name = tc[:name] || tc["name"]
          args = tc[:args] || tc["args"]

          if is_binary(name) and is_map(args),
            do: %{name: name, arguments: Jason.encode!(args)},
            else: nil
      end
    end

    # --- Caching ---

    @doc false
    def apply_caching(model, messages, true = _cache_enabled) do
      cond do
        String.starts_with?(model, "anthropic:") ->
          extra_opts = [
            provider_options: [
              anthropic_prompt_cache: true,
              anthropic_prompt_cache_ttl: "5m"
            ]
          ]

          {messages, extra_opts}

        String.starts_with?(model, "openrouter:") and anthropic_model_on_openrouter?(model) ->
          extra_opts = [
            openrouter_provider: %{order: ["Anthropic"], allow_fallbacks: false}
          ]

          {add_cache_control_to_messages(messages), extra_opts}

        bedrock_model?(model) ->
          extra_opts = [
            provider_options: [
              anthropic_prompt_cache: true,
              anthropic_prompt_cache_ttl: "5m"
            ]
          ]

          {messages, extra_opts}

        true ->
          {messages, []}
      end
    end

    def apply_caching(_model, messages, false), do: {messages, []}

    defp apply_bedrock_region(model, opts) do
      if bedrock_model?(model) and System.get_env("AWS_REGION") == nil do
        region =
          Application.get_env(:ptc_runner, :bedrock_region) ||
            @default_bedrock_region

        System.put_env("AWS_REGION", region)
      end

      opts
    end

    defp bedrock_model?(model) when is_binary(model) do
      String.starts_with?(model, "amazon_bedrock:") or String.starts_with?(model, "bedrock:")
    end

    defp bedrock_model?(%{provider: :amazon_bedrock}), do: true
    defp bedrock_model?(_), do: false

    # --- Inference Profiles ---

    @bedrock_inference_required_families ["amazon."]

    defp bedrock_region_prefix do
      region =
        System.get_env("AWS_REGION") ||
          Application.get_env(:ptc_runner, :bedrock_region) ||
          @default_bedrock_region

      cond do
        String.starts_with?(region, "us-") -> "us"
        String.starts_with?(region, "eu-") -> "eu"
        String.starts_with?(region, "ap-") -> "ap"
        String.starts_with?(region, "ca-") -> "ca"
        true -> "us"
      end
    end

    defp anthropic_model_on_openrouter?(model) do
      String.contains?(model, "anthropic") or String.contains?(model, "claude")
    end

    defp add_cache_control_to_messages(messages) do
      last_system_idx =
        messages
        |> Enum.with_index()
        |> Enum.reverse()
        |> Enum.find_value(fn
          {%{role: :system}, idx} -> idx
          _ -> nil
        end)

      messages
      |> Enum.with_index()
      |> Enum.map(fn
        {%{role: :system, content: content}, idx}
        when is_binary(content) and idx == last_system_idx ->
          content_part =
            ContentPart.text(content, %{cache_control: %{type: "ephemeral"}})

          %Message{role: :system, content: [content_part]}

        {%{role: :system, content: content}, _idx} when is_binary(content) ->
          %Message{role: :system, content: [ContentPart.text(content)]}

        {%{role: role, content: content}, _idx} when is_atom(role) and is_binary(content) ->
          %Message{role: role, content: [ContentPart.text(content)]}

        {%Message{} = message, _idx} ->
          message

        {message, _idx} ->
          message
      end)
    end

    # --- Provider Parsing ---

    defp parse_provider("ollama:" <> model_name) do
      {:ollama, model_name}
    end

    defp parse_provider("openai-compat:" <> rest) do
      case String.split(rest, "|", parts: 2) do
        [base_url, model] -> {:openai_compat, base_url, model}
        [base_url] -> {:openai_compat, base_url, "default"}
      end
    end

    defp parse_provider(model) do
      {:req_llm, model}
    end

    # --- Helpers ---

    defp format_messages_as_prompt(messages) do
      messages
      |> Enum.map_join("\n\n", fn
        %{role: :system, content: content} -> "System: #{content}"
        %{role: :user, content: content} -> "User: #{content}"
        %{role: :assistant, content: content} -> "Assistant: #{content}"
      end)
      |> Kernel.<>("\n\nAssistant:")
    end

    defp extract_ollama_tokens(body) do
      %{
        input: body["prompt_eval_count"] || 0,
        output: body["eval_count"] || 0
      }
    end

    defp maybe_put_ollama_max_tokens(options, opts) do
      case Keyword.fetch(opts, :max_tokens) do
        {:ok, max_tokens} -> Map.put(options, :num_predict, max_tokens)
        :error -> options
      end
    end

    defp req_llm_generation_opts(
           opts,
           model,
           request_payload,
           allowed_options \\ @req_llm_generation_options
         ) do
      opts
      |> Keyword.take(allowed_options)
      |> maybe_put_bounded_max_tokens(model, request_payload)
    end

    @doc false
    @spec effective_output_limit(keyword(), term(), term()) ::
            {pos_integer(), [OutputLimit.binding()]} | :unknown
    def effective_output_limit(opts, model, request_payload) when is_list(opts) do
      if wire_output_limit_supported?(model_provider(model)) do
        case configured_output_limit_values(opts, model) |> Enum.uniq() do
          [value] ->
            {value, [:configured]}

          [] ->
            computed_output_limit(model, request_payload)

          _conflicting ->
            :unknown
        end
      else
        :unknown
      end
    end

    defp effective_output_limit_metadata(
           opts,
           model,
           request_payload,
           messages,
           request_opts
         ) do
      with {candidate, bindings} <- effective_output_limit(opts, model, request_payload),
           {:ok, ^candidate} <- normalized_request_output_limit(model, messages, request_opts),
           value = candidate,
           true <- value in 1..1_000_000 do
        %{
          name: :max_tokens,
          value: value,
          bindings: bindings
        }
      else
        _unknown_or_unbounded -> nil
      end
    end

    # The Codex transport deliberately removes token-limit fields while encoding
    # its final request body. A provider-reported length stop therefore cannot be
    # attributed to the cap PtcRunner supplied to ReqLLM.
    defp wire_output_limit_supported?(:openai_codex), do: false
    defp wire_output_limit_supported?(provider), do: is_atom(provider)

    defp configured_output_limit_values(opts, model) do
      ([Keyword.get(opts, :max_tokens)] ++
         provider_token_limit_values(
           Keyword.get(opts, :provider_options, []),
           model_provider(model)
         ))
      |> Enum.filter(&(is_integer(&1) and &1 in 1..1_000_000))
    end

    defp normalized_request_output_limit(model, messages, request_opts) do
      with provider when is_atom(provider) <- model_provider(model),
           {:ok, provider_module} <- ReqLLM.provider(provider),
           {:ok, context} <- ReqLLM.Context.normalize(messages, request_opts),
           {:ok, processed_opts} <-
             Options.process(
               provider_module,
               :chat,
               model,
               request_opts
               |> Keyword.put(:context, context)
               |> Keyword.put(:on_unsupported, :ignore)
             ),
           [value] <-
             processed_opts
             |> processed_output_limit_values(provider)
             |> Enum.uniq() do
        {:ok, value}
      else
        _unknown_or_ambiguous -> :error
      end
    end

    defp processed_output_limit_values(opts, provider) do
      ([
         Keyword.get(opts, :max_tokens),
         Keyword.get(opts, :max_completion_tokens),
         Keyword.get(opts, :max_output_tokens)
       ] ++
         provider_token_limit_values(Keyword.get(opts, :provider_options, []), provider))
      |> Enum.filter(&(is_integer(&1) and &1 > 0))
    end

    defp put_finish_metadata(result, response, output_limit) do
      reason = ReqLLM.Response.finish_reason(response)

      result
      |> Map.put(:finish_reason, reason)
      |> maybe_put_output_limit(reason, output_limit)
    end

    defp maybe_put_output_limit(result, :length, output_limit) when is_map(output_limit),
      do: Map.put(result, :output_limit, output_limit)

    defp maybe_put_output_limit(result, _reason, _output_limit), do: result

    defp maybe_put_bounded_max_tokens(opts, model, request_payload) do
      if token_limit_present?(opts, model) do
        opts
      else
        Keyword.put(opts, :max_tokens, bounded_max_tokens(model, request_payload))
      end
    end

    defp bounded_max_tokens(model, request_payload),
      do: model |> computed_output_limit(request_payload) |> elem(0)

    defp computed_output_limit(%LLMDB.Model{limits: limits}, request_payload) do
      OutputLimit.select([
        {:adapter_default, @default_max_tokens},
        {:model_output_limit, model_output_limit(limits)},
        {:remaining_context, remaining_context_tokens(limits, request_payload)}
      ])
    end

    defp computed_output_limit(_model, _request_payload),
      do: {@default_max_tokens, [:adapter_default]}

    defp model_output_limit(limits) when is_map(limits),
      do: limits[:output] || limits["output"]

    defp model_output_limit(_limits), do: nil

    defp remaining_context_tokens(limits, request_payload) when is_map(limits) do
      case limits[:context] || limits["context"] do
        context when is_integer(context) and context > 0 ->
          max(context - conservative_input_token_bound(request_payload), 1)

        _unknown ->
          nil
      end
    end

    defp remaining_context_tokens(_limits, _request_payload), do: nil

    # A token cannot encode less than one byte of the serialized request. Treating
    # every external-format byte as a token, plus fixed chat framing headroom,
    # intentionally overestimates input without depending on a provider tokenizer.
    defp conservative_input_token_bound(request_payload) do
      :erlang.external_size(request_payload) + @request_token_headroom
    end

    defp dispatch_invocation(target, invocation) do
      request = invocation.request
      opts = invocation_opts(target, invocation)
      messages = build_messages(request)

      cond do
        is_map(Map.get(request, :schema)) ->
          dispatch_structured(target, messages, request.schema, opts)

        is_list(Map.get(request, :tools)) and request.tools != [] ->
          target
          |> generate_with_tools(messages, request.tools, opts)
          |> normalize_call_result(:tools)

        true ->
          target
          |> generate_text(messages, opts)
          |> normalize_call_result()
      end
    end

    defp dispatch_structured(target, messages, schema, opts) do
      case target.structured_output_mode do
        :json_schema ->
          target
          |> generate_object(messages, schema, opts)
          |> case do
            {:ok, result} -> {:ok, result}
            error -> normalize_call_result(error)
          end

        :json_object ->
          case generate_json(target, messages, opts) do
            {:ok, result} -> {:ok, result}
            error -> normalize_call_result(error)
          end

        _unsupported ->
          {:error, ProviderError.new(:invalid_result, "LLM provider returned an invalid result")}
      end
    end

    defp generate_json(%ReqLLMPreparedModel{model: %LLMDB.Model{}} = model, messages, opts) do
      call_req_llm_json(model, messages, merge_exact_options(model, opts))
    end

    defp generate_json(%ReqLLMPreparedModel{selector: selector} = target, messages, opts) do
      generate_json(selector, messages, merge_exact_options(target, opts))
    end

    defp generate_json(model, messages, opts) when is_binary(model) do
      case parse_provider(model) do
        {:ollama, _model_name} ->
          {:error, :structured_output_not_supported}

        {:openai_compat, _base_url, _model_name} ->
          {:error, :structured_output_not_supported}

        {:req_llm, model_id} ->
          with {:ok, prepared, _status} <- prepare_req_llm_model(model_id),
               do: call_req_llm_json(prepared, messages, opts)
      end
    end

    defp call_req_llm_json(%ReqLLMPreparedModel{model: req_llm_model} = prepared, messages, opts) do
      if native_json_object_model?(req_llm_model) do
        json_opts = put_json_object_format(opts)

        case call_req_llm(prepared, messages, json_opts) do
          {:ok, %{content: content, tokens: tokens}} when is_binary(content) ->
            {:ok, %{json: content, tokens: tokens}}

          {:ok, result} ->
            {:ok, result}

          error ->
            normalize_call_result(error)
        end
      else
        {:error, :unsupported_model_option}
      end
    end

    defp put_json_object_format(opts) do
      put_provider_option(opts, :response_format, %{type: "json_object"})
    end

    defp put_json_schema_native_mode(opts, %LLMDB.Model{provider: provider}) do
      case json_schema_mode_key(provider) do
        nil ->
          opts

        key ->
          opts
          |> put_provider_option(key, :json_schema)
          |> Keyword.put_new(key, :json_schema)
      end
    end

    defp json_schema_mode_key(:openrouter), do: :openrouter_structured_output_mode
    defp json_schema_mode_key(:openai), do: :openai_structured_output_mode
    defp json_schema_mode_key(:anthropic), do: :anthropic_structured_output_mode
    defp json_schema_mode_key(:google_vertex), do: :anthropic_structured_output_mode
    defp json_schema_mode_key(:xai), do: :xai_structured_output_mode
    defp json_schema_mode_key(:fireworks_ai), do: :fireworks_structured_output_mode
    defp json_schema_mode_key(_provider), do: nil

    defp put_provider_option(opts, key, value) do
      provider_options =
        opts
        |> Keyword.get(:provider_options, [])
        |> store_provider_option(key, value)

      Keyword.put(opts, :provider_options, provider_options)
    end

    defp store_provider_option(options, key, value) when is_list(options),
      do: Keyword.put(options, key, value)

    defp store_provider_option(options, key, value) when is_map(options),
      do: Map.put(options, key, value)

    defp store_provider_option(_options, key, value), do: [{key, value}]

    defp invocation_opts(%ReqLLMPreparedModel{} = target, invocation) do
      opts =
        target
        |> merge_exact_options(on_unsupported: :error, cache: invocation.cache)

      if is_binary(invocation.credential),
        do: Keyword.put(opts, :api_key, invocation.credential),
        else: opts
    end

    defp merge_exact_options(%ReqLLMPreparedModel{exact_options: exact_options}, opts)
         when is_map(exact_options) do
      exact_options
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Keyword.new()
      |> Keyword.merge(opts)
    end

    defp attest_structured_requirements(model, %{
           structured_output_mode: mode,
           usage_guarantees: %{tokens: false, cost_currency: nil},
           reservation: %{total_tokens?: false, cost_tariff: nil}
         })
         when mode in [:json_schema, :json_object, :unsupported] do
      attest_structured_mode(model, mode)
    end

    defp attest_structured_requirements(_model, _requirements),
      do: {:error, :unsupported_model_option}

    defp attest_structured_mode(_model, :unsupported), do: :ok

    defp attest_structured_mode(model, :json_object) do
      case parse_provider(model) do
        {:req_llm, selector} ->
          if native_json_object_selector?(selector),
            do: :ok,
            else: {:error, :unsupported_model_option}

        _unsupported_route ->
          {:error, :unsupported_model_option}
      end
    end

    defp attest_structured_mode(model, :json_schema) do
      case parse_provider(model) do
        {:req_llm, selector} ->
          if native_json_schema_selector?(selector),
            do: :ok,
            else: {:error, :unsupported_model_option}

        _unsupported_route ->
          {:error, :unsupported_model_option}
      end
    end

    defp native_json_schema_selector?(selector) do
      case split_req_llm_selector(selector) do
        {:ok, :google_vertex, model_id} -> vertex_native_json_schema_id?(model_id)
        {:ok, provider, _model_id} -> provider in @native_json_schema_providers
        _invalid -> false
      end
    end

    defp native_json_object_selector?(selector) do
      case split_req_llm_selector(selector) do
        # Vertex Claude/Gemini strip `response_format`. Every other Vertex MaaS
        # family uses the OpenAI-compatible wire, so json_object is admitted
        # unless the id is one of those native families.
        {:ok, :google_vertex, model_id} -> not vertex_native_json_schema_id?(model_id)
        {:ok, :azure, model_id} -> azure_json_object_id?(model_id)
        {:ok, provider, _model_id} -> provider in @native_json_object_providers
        _invalid -> false
      end
    end

    defp direct_target(selector, canonical) do
      %ReqLLMPreparedModel{
        selector: selector,
        exact_options: canonical.exact_options,
        structured_output_mode: canonical.structured_output_mode,
        model: nil
      }
    end

    defp prepare_req_llm_target(selector, canonical) do
      with :ok <- refuse_lossy_max_tokens(selector),
           {:ok, prepared, status} <- prepare_req_llm_model(selector),
           :ok <- attest_prepared_json_schema(prepared, canonical.structured_output_mode) do
        {:ok,
         %{
           prepared
           | exact_options: canonical.exact_options,
             structured_output_mode: canonical.structured_output_mode
         }, status, canonical}
      end
    end

    defp attest_prepared_json_schema(%ReqLLMPreparedModel{model: model}, :json_schema) do
      if native_json_schema_model?(model),
        do: :ok,
        else: {:error, :unsupported_model_option}
    end

    defp attest_prepared_json_schema(%ReqLLMPreparedModel{model: model}, :json_object) do
      if native_json_object_model?(model),
        do: :ok,
        else: {:error, :unsupported_model_option}
    end

    defp attest_prepared_json_schema(_prepared, :unsupported), do: :ok

    defp native_json_schema_model?(%LLMDB.Model{provider: :openai} = model),
      do: ModelHelpers.json_schema?(model)

    defp native_json_schema_model?(%LLMDB.Model{provider: :xai} = model),
      do: XAI.supports_native_structured_outputs?(model)

    defp native_json_schema_model?(%LLMDB.Model{provider: :google_vertex} = model),
      do: vertex_native_json_schema_model?(model)

    defp native_json_schema_model?(%LLMDB.Model{provider: provider}),
      do: provider in @native_json_schema_providers

    defp native_json_schema_model?(_model), do: false

    defp native_json_object_model?(%LLMDB.Model{provider: :openai} = model),
      do: ModelHelpers.json_native?(model)

    defp native_json_object_model?(%LLMDB.Model{provider: :xai} = model),
      do: ModelHelpers.json_native?(model)

    defp native_json_object_model?(%LLMDB.Model{provider: :google_vertex} = model),
      do: not vertex_native_json_schema_model?(model)

    defp native_json_object_model?(%LLMDB.Model{provider: :azure} = model),
      do: azure_json_object_model?(model)

    defp native_json_object_model?(%LLMDB.Model{provider: provider}),
      do: provider in @native_json_object_providers

    defp native_json_object_model?(_model), do: false

    defp azure_json_object_model?(%LLMDB.Model{} = model) do
      id = model.provider_model_id || model.id
      azure_json_object_id?(id) and not azure_claude_family?(vertex_extra_family(model))
    end

    defp azure_json_object_id?(id) when is_binary(id), do: not String.starts_with?(id, "claude")
    defp azure_json_object_id?(_id), do: false

    defp azure_claude_family?(family) when is_binary(family),
      do: String.starts_with?(family, "claude")

    defp azure_claude_family?(_family), do: false

    defp vertex_native_json_schema_model?(%LLMDB.Model{} = model) do
      id = model.provider_model_id || model.id

      vertex_native_json_schema_id?(id) or
        vertex_native_json_schema_family?(vertex_extra_family(model))
    end

    defp vertex_native_json_schema_id?(id) when is_binary(id) do
      String.starts_with?(id, "claude-") or String.starts_with?(id, "gemini-")
    end

    defp vertex_native_json_schema_id?(_id), do: false

    defp vertex_native_json_schema_family?(family) when is_binary(family) do
      String.starts_with?(family, "claude") or String.starts_with?(family, "gemini")
    end

    defp vertex_native_json_schema_family?(_family), do: false

    defp vertex_extra_family(%LLMDB.Model{extra: extra}) when is_map(extra),
      do: Map.get(extra, :family) || Map.get(extra, "family")

    defp vertex_extra_family(_model), do: nil

    defp refuse_lossy_max_tokens("openai_codex:" <> _rest),
      do: {:error, :unsupported_model_option}

    defp refuse_lossy_max_tokens(_selector), do: :ok

    defp prepare_req_llm_model(selector) do
      {effective_selector, provider_model_id} = inference_profile_resolution(selector)
      catalog_status = catalog_status(effective_selector)

      case resolve_req_llm_model(effective_selector, catalog_status) do
        {:ok, %LLMDB.Model{} = model} ->
          model =
            if provider_model_id,
              do: %{model | provider_model_id: provider_model_id},
              else: model

          {:ok, %ReqLLMPreparedModel{selector: selector, exact_options: %{}, model: model},
           catalog_status}

        {:error, _reason} = error ->
          error
      end
    end

    defp inference_profile_resolution("amazon_bedrock:" <> model_id = selector) do
      if Enum.any?(@bedrock_inference_required_families, &String.starts_with?(model_id, &1)),
        do: {selector, "#{bedrock_region_prefix()}.#{model_id}"},
        else: {selector, nil}
    end

    defp inference_profile_resolution(selector), do: {selector, nil}

    defp catalog_status(selector) do
      case LLMDB.model(selector) do
        {:ok, %LLMDB.Model{}} -> :cataloged
        _missing -> :uncataloged
      end
    end

    defp resolve_req_llm_model(selector, :cataloged), do: ReqLLM.model(selector)

    defp resolve_req_llm_model(selector, :uncataloged) do
      with {:ok, provider, model_id} <- split_req_llm_selector(selector),
           {:ok, _provider_module} <- ReqLLM.provider(provider) do
        if provider in @req_llm_special_fallback_providers,
          do: ReqLLM.model(selector),
          else: ReqLLM.model(%{provider: provider, id: model_id})
      end
    end

    defp split_req_llm_selector(selector) do
      case String.split(selector, ":", parts: 2) do
        [provider_name, model_id] when model_id != "" ->
          {:ok, provider_atom(provider_name), model_id}

        _invalid ->
          {:error, :invalid_model}
      end
    rescue
      ArgumentError -> {:error, :invalid_model}
    end

    defp provider_atom(provider_name) do
      provider_name
      |> String.replace("-", "_")
      |> String.to_existing_atom()
    end

    defp token_limit_present?(opts, model) do
      Keyword.has_key?(opts, :max_tokens) or
        provider_token_limit_present?(
          Keyword.get(opts, :provider_options, []),
          model_provider(model)
        )
    end

    defp model_provider(%LLMDB.Model{provider: provider}), do: provider
    defp model_provider(_model), do: nil

    defp provider_token_limit_present?(provider_options, provider) do
      token_limit_in?(provider_options) or
        provider_options
        |> provider_namespace(provider)
        |> token_limit_in?()
    end

    defp provider_token_limit_values(provider_options, provider) do
      token_limit_values(provider_options) ++
        token_limit_values(provider_namespace(provider_options, provider))
    end

    defp token_limit_values(options) when is_list(options) do
      if Keyword.keyword?(options),
        do: Keyword.values(Keyword.take(options, @token_limit_options)),
        else: []
    end

    defp token_limit_values(options) when is_map(options),
      do:
        Enum.map(
          @token_limit_options,
          &(Map.get(options, &1) || Map.get(options, Atom.to_string(&1)))
        )

    defp token_limit_values(_options), do: []

    defp provider_namespace(provider_options, provider)
         when is_list(provider_options) and is_atom(provider) do
      if Keyword.keyword?(provider_options), do: Keyword.get(provider_options, provider, [])
    end

    defp provider_namespace(provider_options, provider)
         when is_map(provider_options) and is_atom(provider) do
      Map.get(provider_options, provider) || Map.get(provider_options, Atom.to_string(provider))
    end

    defp provider_namespace(_provider_options, _provider), do: nil

    defp token_limit_in?(options) when is_list(options) do
      Keyword.keyword?(options) and
        Enum.any?(@token_limit_options, &Keyword.has_key?(options, &1))
    end

    defp token_limit_in?(options) when is_map(options) do
      Enum.any?(@token_limit_options, fn key ->
        Map.has_key?(options, key) or Map.has_key?(options, Atom.to_string(key))
      end)
    end

    defp token_limit_in?(_options), do: false

    defp add_cache_fields(tokens) do
      Map.merge(tokens, %{cache_creation: 0, cache_read: 0})
    end

    @doc false
    def build_tokens_from_req_llm_response(usage, provider_meta) do
      cache_write_from_meta = extract_cache_write_tokens(provider_meta)

      cache_read =
        usage[:cache_read_input_tokens] || usage[:cached_tokens] ||
          usage["cache_read_input_tokens"] || usage["cached_tokens"] || 0

      cache_creation =
        usage[:cache_creation_input_tokens] || usage[:cache_creation_tokens] ||
          usage["cache_creation_input_tokens"] || usage["cache_creation_tokens"] ||
          cache_write_from_meta

      %{
        input: usage[:input_tokens] || usage["input_tokens"] || 0,
        output: usage[:output_tokens] || usage["output_tokens"] || 0,
        cache_creation: cache_creation,
        cache_read: cache_read
      }
      |> maybe_put_total_cost(usage)
    end

    @doc false
    def build_stream_done_chunk(usage) do
      %{done: true, tokens: build_tokens_from_req_llm_response(usage, %{})}
    end

    defp maybe_put_total_cost(tokens, usage) do
      case usage[:total_cost] || usage["total_cost"] do
        total_cost when is_number(total_cost) -> Map.put(tokens, :total_cost, total_cost)
        _unknown -> tokens
      end
    end

    defp extract_cache_write_tokens(%{} = meta) do
      get_in(meta, ["usage", "prompt_tokens_details", "cache_write_tokens"]) ||
        get_in(meta, [:usage, :prompt_tokens_details, :cache_write_tokens]) ||
        get_in(meta, ["prompt_tokens_details", "cache_write_tokens"]) ||
        0
    end

    # --- Availability Checks ---

    defp check_ollama_available do
      case Req.get("#{@ollama_base_url}/api/tags", receive_timeout: 2_000) do
        {:ok, %{status: 200}} -> true
        _ -> false
      end
    end

    defp check_openai_compat_available(base_url) do
      case Req.get("#{base_url}/models", receive_timeout: 2_000) do
        {:ok, %{status: 200}} -> true
        _ -> false
      end
    end

    defp check_req_llm_available(model) do
      cond do
        String.starts_with?(model, "openrouter:") ->
          System.get_env("OPENROUTER_API_KEY") != nil

        String.starts_with?(model, "anthropic:") ->
          System.get_env("ANTHROPIC_API_KEY") != nil

        String.starts_with?(model, "openai:") ->
          System.get_env("OPENAI_API_KEY") != nil

        String.starts_with?(model, "google:") ->
          System.get_env("GOOGLE_API_KEY") != nil

        String.starts_with?(model, "groq:") ->
          System.get_env("GROQ_API_KEY") != nil

        String.starts_with?(model, "bedrock:") or String.starts_with?(model, "amazon_bedrock:") ->
          System.get_env("AWS_ACCESS_KEY_ID") != nil or
            System.get_env("AWS_SESSION_TOKEN") != nil

        true ->
          true
      end
    end
  end
end
