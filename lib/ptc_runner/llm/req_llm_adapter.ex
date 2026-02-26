if Code.ensure_loaded?(ReqLLM) do
  defmodule PtcRunner.LLM.ReqLLMAdapter do
    @moduledoc """
    Built-in LLM adapter using `req_llm`.

    Routes requests based on model prefix:
    - `ollama:model-name` → Local Ollama server
    - `openai-compat:base_url|model` → Any OpenAI-compatible API
    - `*` → ReqLLM (OpenRouter, Anthropic, Google, Bedrock, etc.)

    Requires `{:req_llm, "~> 1.2"}` as a dependency.

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

    alias ReqLLM.Message
    alias ReqLLM.Message.ContentPart

    require Logger

    @default_timeout 120_000
    @ollama_base_url "http://localhost:11434"
    @default_bedrock_region "eu-north-1"

    # --- Behaviour Callbacks ---

    @impl true
    @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
    def call(model, %{schema: schema} = req) when is_map(schema) do
      messages = build_messages(req)

      case generate_object(model, messages, schema, cache: req[:cache] || false) do
        {:ok, %{object: object, tokens: tokens}} ->
          {:ok, %{content: Jason.encode!(object), tokens: tokens}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def call(model, %{tools: tools} = req) when is_list(tools) and tools != [] do
      messages = build_messages(req)
      generate_with_tools(model, messages, tools, cache: req[:cache] || false)
    end

    def call(model, req) do
      messages = build_messages(req)
      generate_text(model, messages, cache: req[:cache] || false)
    end

    @impl true
    @spec stream(String.t(), map()) :: {:ok, Enumerable.t()} | {:error, term()}
    def stream(model, req) do
      case parse_provider(model) do
        {:ollama, _} ->
          {:error, :streaming_not_supported}

        {:openai_compat, _, _} ->
          {:error, :streaming_not_supported}

        {:req_llm, model_id} ->
          stream_req_llm(model_id, req)
      end
    end

    # --- Public API ---

    @doc """
    Generate text from an LLM.

    ## Options
    - `:receive_timeout` - Request timeout in ms (default: #{@default_timeout})
    - `:ollama_base_url` - Override Ollama server URL
    - `:cache` - Enable prompt caching for supported providers (default: false)
    """
    @spec generate_text(String.t(), [map()], keyword()) ::
            {:ok, PtcRunner.LLM.response()} | {:error, term()}
    def generate_text(model, messages, opts \\ []) do
      case parse_provider(model) do
        {:ollama, model_name} ->
          call_ollama(model_name, messages, opts)

        {:openai_compat, base_url, model_name} ->
          call_openai_compat(base_url, model_name, messages, opts)

        {:req_llm, model_id} ->
          call_req_llm(model_id, messages, opts)
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

    Only supported for ReqLLM providers. Local providers return
    `{:error, :structured_output_not_supported}`.
    """
    @spec generate_object(String.t(), [map()], map(), keyword()) ::
            {:ok, map()} | {:error, term()}
    def generate_object(model, messages, schema, opts \\ []) do
      case parse_provider(model) do
        {:ollama, _model_name} ->
          {:error, :structured_output_not_supported}

        {:openai_compat, _base_url, _model_name} ->
          {:error, :structured_output_not_supported}

        {:req_llm, model_id} ->
          call_req_llm_object(model_id, messages, schema, opts)
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
    @spec generate_with_tools(String.t(), [map()], [map()], keyword()) ::
            {:ok, map()} | {:error, term()}
    def generate_with_tools(model, messages, tools, opts \\ []) do
      case parse_provider(model) do
        {:ollama, _model_name} ->
          {:error, :tool_calling_not_supported}

        {:openai_compat, _base_url, _model_name} ->
          {:error, :tool_calling_not_supported}

        {:req_llm, model_id} ->
          call_req_llm_with_tools(model_id, messages, tools, opts)
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

    # --- Streaming ---

    defp stream_req_llm(model_id, req) do
      model_id = maybe_resolve_inference_profile(model_id)
      messages = build_messages(req)
      cache_enabled = req[:cache] || false

      {messages, extra_opts} = apply_caching(model_id, messages, cache_enabled)
      extra_opts = apply_bedrock_region(model_id, extra_opts)

      req_opts =
        [receive_timeout: @default_timeout]
        |> Keyword.merge(extra_opts)

      case ReqLLM.Generation.stream_text(model_id, messages, req_opts) do
        {:ok, stream_response} ->
          # Map ReqLLM.StreamChunk structs to %{delta: text} chunks
          content_stream =
            stream_response.stream
            |> Stream.flat_map(fn
              %{type: :content, text: text} when is_binary(text) and text != "" ->
                [%{delta: text}]

              _ ->
                []
            end)

          # Lazy stream that fetches real usage after content stream is consumed.
          # ReqLLM.StreamResponse.usage/1 blocks until metadata is available,
          # which happens after the content stream completes.
          done_stream =
            Stream.resource(
              fn -> :pending end,
              fn
                :pending ->
                  usage = ReqLLM.StreamResponse.usage(stream_response) || %{}

                  tokens = %{
                    input: usage[:input_tokens] || 0,
                    output: usage[:output_tokens] || 0
                  }

                  {[%{done: true, tokens: tokens}], :emitted}

                :emitted ->
                  {:halt, :emitted}
              end,
              fn _ -> :ok end
            )

          {:ok, Stream.concat(content_stream, done_stream)}

        {:error, reason} ->
          {:error, reason}
      end
    end

    # --- Provider Implementations ---

    defp call_ollama(model, messages, opts) do
      base_url = Keyword.get(opts, :ollama_base_url, @ollama_base_url)
      timeout = Keyword.get(opts, :receive_timeout, @default_timeout)

      prompt = format_messages_as_prompt(messages)

      Logger.debug("Calling Ollama: #{model}")

      case Req.post("#{base_url}/api/generate",
             json: %{model: model, prompt: prompt, stream: false},
             receive_timeout: timeout
           ) do
        {:ok, %{status: 200, body: %{"response" => text} = body}} ->
          tokens = extract_ollama_tokens(body) |> add_cache_fields()
          {:ok, %{content: text, tokens: tokens}}

        {:ok, %{status: status, body: body}} ->
          {:error, %{status: status, body: body}}

        {:error, %{reason: :econnrefused}} ->
          {:error, "Ollama not running at #{base_url}. Start with: ollama serve"}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp call_openai_compat(base_url, model, messages, opts) do
      timeout = Keyword.get(opts, :receive_timeout, @default_timeout)

      formatted_messages =
        Enum.map(messages, fn msg ->
          %{"role" => to_string(msg.role), "content" => msg.content}
        end)

      Logger.debug("Calling OpenAI-compatible API: #{base_url} with #{model}")

      case Req.post("#{base_url}/chat/completions",
             json: %{model: model, messages: formatted_messages},
             receive_timeout: timeout
           ) do
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

    defp call_req_llm(model, messages, opts) do
      model = maybe_resolve_inference_profile(model)
      timeout = Keyword.get(opts, :receive_timeout, @default_timeout)
      http_opts = Keyword.get(opts, :req_http_options, [])
      cache_enabled = Keyword.get(opts, :cache, false)

      {messages, extra_opts} = apply_caching(model, messages, cache_enabled)
      extra_opts = apply_bedrock_region(model, extra_opts)

      req_opts =
        [receive_timeout: timeout, req_http_options: http_opts]
        |> Keyword.merge(extra_opts)

      case ReqLLM.generate_text(model, messages, req_opts) do
        {:ok, response} ->
          text = ReqLLM.Response.text(response) || ""
          usage = ReqLLM.Response.usage(response) || %{}
          tokens = build_tokens_from_req_llm_response(usage, response.provider_meta)

          {:ok, %{content: text, tokens: tokens}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp call_req_llm_object(model, messages, schema, opts) do
      model = maybe_resolve_inference_profile(model)
      timeout = Keyword.get(opts, :receive_timeout, @default_timeout)
      http_opts = Keyword.get(opts, :req_http_options, [])
      cache_enabled = Keyword.get(opts, :cache, false)

      {messages, extra_opts} = apply_caching(model, messages, cache_enabled)
      extra_opts = apply_bedrock_region(model, extra_opts)

      req_opts =
        [receive_timeout: timeout, req_http_options: http_opts]
        |> Keyword.merge(extra_opts)

      case ReqLLM.generate_object(model, messages, schema, req_opts) do
        {:ok, response} ->
          usage = ReqLLM.Response.usage(response) || %{}
          tokens = build_tokens_from_req_llm_response(usage, response.provider_meta)

          {:ok, %{object: response.object, tokens: tokens}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp call_req_llm_with_tools(model, messages, tools, opts) do
      model = maybe_resolve_inference_profile(model)
      timeout = Keyword.get(opts, :receive_timeout, @default_timeout)
      http_opts = Keyword.get(opts, :req_http_options, [])
      cache_enabled = Keyword.get(opts, :cache, false)

      {messages, extra_opts} = apply_caching(model, messages, cache_enabled)
      extra_opts = apply_bedrock_region(model, extra_opts)

      req_llm_tools = Enum.map(tools, &to_req_llm_tool/1)

      req_opts =
        [receive_timeout: timeout, req_http_options: http_opts, tools: req_llm_tools]
        |> Keyword.merge(extra_opts)

      case ReqLLM.generate_text(model, messages, req_opts) do
        {:ok, response} ->
          text = ReqLLM.Response.text(response)
          usage = ReqLLM.Response.usage(response) || %{}
          tokens = build_tokens_from_req_llm_response(usage, response.provider_meta)
          raw_tool_calls = ReqLLM.Response.tool_calls(response)

          if raw_tool_calls != [] do
            {:ok,
             %{tool_calls: normalize_tool_calls(raw_tool_calls), content: text, tokens: tokens}}
          else
            {:ok, %{content: text || "", tokens: tokens}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp normalize_tool_calls(raw_tool_calls) do
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
          {:error, "Ollama not running at #{base_url}. Start with: ollama serve"}

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

    defp build_messages(req) do
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
                  function: tc[:function] || tc["function"]
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

    # --- Caching ---

    defp apply_caching(model, messages, true = _cache_enabled) do
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

    defp apply_caching(_model, messages, false), do: {messages, []}

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

    @bedrock_inference_prefixes ["us.", "eu.", "ap.", "ca.", "global."]
    @bedrock_inference_required_families ["amazon."]

    defp maybe_resolve_inference_profile("amazon_bedrock:" <> model_id = full) do
      cond do
        String.starts_with?(model_id, @bedrock_inference_prefixes) ->
          [_region, base_id] = String.split(model_id, ".", parts: 2)

          case ReqLLM.model("amazon_bedrock:#{base_id}") do
            {:ok, model} -> %{model | provider_model_id: model_id}
            {:error, _} -> full
          end

        Enum.any?(@bedrock_inference_required_families, &String.starts_with?(model_id, &1)) ->
          region_prefix = bedrock_region_prefix()

          case ReqLLM.model("amazon_bedrock:#{model_id}") do
            {:ok, model} -> %{model | provider_model_id: "#{region_prefix}.#{model_id}"}
            {:error, _} -> full
          end

        true ->
          full
      end
    end

    defp maybe_resolve_inference_profile(model), do: model

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

    defp add_cache_fields(tokens) do
      Map.merge(tokens, %{cache_creation: 0, cache_read: 0})
    end

    defp build_tokens_from_req_llm_response(usage, provider_meta) do
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
        cache_read: cache_read,
        total_cost: usage[:total_cost] || 0.0
      }
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
