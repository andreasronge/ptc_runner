defmodule LLMClient.Providers do
  @moduledoc """
  Unified LLM client supporting multiple providers.

  Routes requests based on model prefix:
  - `ollama:model-name` → Local Ollama server
  - `openai-compat:base_url|model` → Any OpenAI-compatible API
  - `*` → ReqLLM (OpenRouter, Anthropic, Google, etc.)

  ## Examples

      # Local Ollama
      LLMClient.Providers.generate_text("ollama:deepseek-coder:6.7b", messages)

      # OpenAI-compatible endpoint (e.g., LMStudio, vLLM)
      LLMClient.Providers.generate_text("openai-compat:http://localhost:1234/v1|local-model", messages)

      # ReqLLM providers (default)
      LLMClient.Providers.generate_text("openrouter:anthropic/claude-haiku-4.5", messages)
  """

  require Logger

  @default_timeout 120_000
  @ollama_base_url "http://localhost:11434"
  @default_bedrock_region "eu-north-1"

  @type message :: %{role: :system | :user | :assistant, content: String.t()}
  @type response :: %{
          content: String.t(),
          tokens: %{
            input: non_neg_integer(),
            output: non_neg_integer(),
            cache_creation: non_neg_integer(),
            cache_read: non_neg_integer()
          }
        }

  @type object_response :: %{
          object: map(),
          tokens: %{
            input: non_neg_integer(),
            output: non_neg_integer(),
            cache_creation: non_neg_integer(),
            cache_read: non_neg_integer()
          }
        }

  @doc """
  Generate text from an LLM.

  ## Arguments
    - model: Provider-prefixed model string
    - messages: List of message maps with :role and :content
    - opts: Options passed to the provider

  ## Options
    - `:receive_timeout` - Request timeout in ms (default: #{@default_timeout})
    - `:ollama_base_url` - Override Ollama server URL (default: #{@ollama_base_url})
    - `:cache` - Enable prompt caching for supported providers (default: false).
      Works with direct Anthropic API (`anthropic:`), OpenRouter Anthropic models
      (`openrouter:anthropic/...`), and Bedrock Claude models (`bedrock:`).
      Uses 5-minute ephemeral cache.

  ## AWS Bedrock Region

  For Bedrock models, the region is determined in this order:
  1. `AWS_REGION` environment variable
  2. `config :llm_client, :bedrock_region, "region-name"`
  3. Default: `#{@default_bedrock_region}`

  ## Returns
    - `{:ok, %{content: string, tokens: %{input: int, output: int, cache_creation: int, cache_read: int}}}`
    - `{:error, reason}`

  ## Prompt Caching

  When `cache: true` is set and the model supports it (Anthropic via OpenRouter or direct),
  the system and tool prompts are cached. Token counts include:
    - `input` - Non-cached input tokens
    - `output` - Generated output tokens
    - `cache_creation` - Tokens written to cache (costs 1.25x input rate)
    - `cache_read` - Tokens read from cache (costs 0.1x input rate)
  """
  @spec generate_text(String.t(), [message()], keyword()) :: {:ok, response()} | {:error, term()}
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
  @spec generate_text!(String.t(), [message()], keyword()) :: response()
  def generate_text!(model, messages, opts \\ []) do
    case generate_text(model, messages, opts) do
      {:ok, response} -> response
      {:error, reason} -> raise "LLM error: #{inspect(reason)}"
    end
  end

  @doc """
  Generate a structured JSON object from an LLM.

  Only supported for ReqLLM providers (cloud models). Local providers (Ollama, OpenAI-compat)
  will return an error as they don't reliably support structured output.

  ## Arguments
    - model: Provider-prefixed model string (must be a ReqLLM provider)
    - messages: List of message maps with :role and :content
    - schema: JSON Schema map defining the expected output structure
    - opts: Options passed to the provider

  ## Options
    - `:receive_timeout` - Request timeout in ms (default: 120_000)
    - `:cache` - Enable prompt caching for supported providers (default: false)

  ## Returns
    - `{:ok, %{object: map(), tokens: %{...}}}`
    - `{:error, :structured_output_not_supported}` for local providers
    - `{:error, reason}` for other failures
  """
  @spec generate_object(String.t(), [message()], map(), keyword()) ::
          {:ok, object_response()} | {:error, term()}
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
  @spec generate_object!(String.t(), [message()], map(), keyword()) :: object_response()
  def generate_object!(model, messages, schema, opts \\ []) do
    case generate_object(model, messages, schema, opts) do
      {:ok, response} -> response
      {:error, reason} -> raise "LLM structured output error: #{inspect(reason)}"
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

  Returns false for local providers (Ollama, OpenAI-compat),
  true for cloud providers (OpenRouter, Anthropic, etc.).
  """
  @spec requires_api_key?(String.t()) :: boolean()
  def requires_api_key?(model) do
    case parse_provider(model) do
      {:ollama, _} -> false
      {:openai_compat, _, _} -> false
      {:req_llm, _} -> true
    end
  end

  @doc """
  Create a SubAgent-compatible callback for a model.

  The callback handles both :json and :ptc_lisp modes automatically.

  ## Options

  - `:cache` - Enable prompt caching (default: false). When true, the callback
    always sets `cache: true` on requests, regardless of what the caller passes.
    This bakes caching into the transport layer so orchestration code doesn't
    need to thread the option through every layer.

  ## Examples

      llm = LLMClient.callback("sonnet")
      llm = LLMClient.callback("bedrock:haiku", cache: true)

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{...})
  """
  @spec callback(String.t(), keyword()) :: (map() -> {:ok, map()} | {:error, term()})
  def callback(model_or_alias, opts \\ []) do
    LLMClient.load_dotenv()
    model = LLMClient.Registry.resolve!(model_or_alias)

    if opts == [] do
      &call(model, &1)
    else
      fn req -> call(model, Map.merge(req, Map.new(opts))) end
    end
  end

  @doc """
  Handle a SubAgent request directly.

  Routes to `generate_object/4` for :json mode, `generate_text/3` for :ptc_lisp.

  ## Request Map

  For JSON mode:
  - `:system` - System prompt string
  - `:messages` - List of `%{role: atom, content: String.t()}`
  - `:output` - `:json`
  - `:schema` - JSON Schema map
  - `:cache` - Boolean (optional)

  For PTC-Lisp mode:
  - `:system` - System prompt string
  - `:messages` - List of `%{role: atom, content: String.t()}`
  - `:cache` - Boolean (optional)

  ## Returns

  - `{:ok, %{content: String.t(), tokens: map()}}` on success
  - `{:error, term()}` on failure
  """
  @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(model, %{output: :json, schema: schema} = req) do
    messages = [%{role: :system, content: req.system} | req.messages]

    case generate_object(model, messages, schema, cache: req[:cache] || false) do
      {:ok, %{object: object, tokens: tokens}} ->
        {:ok, %{content: Jason.encode!(object), tokens: tokens}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def call(model, req) do
    messages = [%{role: :system, content: req.system} | req.messages]
    generate_text(model, messages, cache: req[:cache] || false)
  end

  # --- Provider Implementations ---

  defp call_ollama(model, messages, opts) do
    base_url = Keyword.get(opts, :ollama_base_url, @ollama_base_url)
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)

    # Ollama's /api/generate expects a single prompt, so we format messages
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

    # Format messages for OpenAI chat completions API
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
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)
    http_opts = Keyword.get(opts, :req_http_options, [])
    cache_enabled = Keyword.get(opts, :cache, false)

    # Apply caching: either via provider_options (Anthropic) or message/opts transformation (OpenRouter)
    {messages, extra_opts} = apply_caching(model, messages, cache_enabled)

    # Apply Bedrock region if needed
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
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)
    http_opts = Keyword.get(opts, :req_http_options, [])
    cache_enabled = Keyword.get(opts, :cache, false)

    # Apply caching (reuse existing apply_caching/3)
    {messages, extra_opts} = apply_caching(model, messages, cache_enabled)

    # Apply Bedrock region if needed
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

  # Apply caching based on provider type
  # Returns {possibly_modified_messages, extra_opts_keyword_list}
  defp apply_caching(model, messages, true = _cache_enabled) do
    cond do
      # Direct Anthropic API - use provider_options for caching
      String.starts_with?(model, "anthropic:") ->
        extra_opts = [
          provider_options: [
            anthropic_prompt_cache: true,
            anthropic_prompt_cache_ttl: "5m"
          ]
        ]

        {messages, extra_opts}

      # OpenRouter with Anthropic model - embed cache_control in message content
      # AND force Anthropic as provider (Google doesn't support cache_control)
      String.starts_with?(model, "openrouter:") and anthropic_model_on_openrouter?(model) ->
        # openrouter_provider is a top-level option, not under provider_options
        extra_opts = [
          openrouter_provider: %{order: ["Anthropic"], allow_fallbacks: false}
        ]

        {add_cache_control_to_messages(messages), extra_opts}

      # Bedrock with Claude model - use same caching options as direct Anthropic
      # req_llm's Bedrock provider auto-switches from Converse to InvokeModel API
      # when caching + tools are present for full cache control
      bedrock_model?(model) ->
        extra_opts = [
          provider_options: [
            anthropic_prompt_cache: true,
            anthropic_prompt_cache_ttl: "5m"
          ]
        ]

        {messages, extra_opts}

      # Other providers - no caching support
      true ->
        {messages, []}
    end
  end

  defp apply_caching(_model, messages, false), do: {messages, []}

  # Ensure AWS_REGION is set for Bedrock models.
  # AWS SDK reads region from environment, so we set it if not already present.
  # Priority: AWS_REGION env var > config > default.
  # NOTE: Uses System.put_env/2 which is a global side effect. Acceptable for CLI
  # usage but may surprise callers in a multi-tenant library context.
  defp apply_bedrock_region(model, opts) do
    if bedrock_model?(model) and System.get_env("AWS_REGION") == nil do
      region =
        Application.get_env(:llm_client, :bedrock_region) ||
          @default_bedrock_region

      System.put_env("AWS_REGION", region)
    end

    opts
  end

  defp bedrock_model?(model) do
    String.starts_with?(model, "amazon_bedrock:") or String.starts_with?(model, "bedrock:")
  end

  defp anthropic_model_on_openrouter?(model) do
    String.contains?(model, "anthropic") or String.contains?(model, "claude")
  end

  # Add cache_control to the last system message content for OpenRouter.
  # OpenRouter requires cache_control embedded in content blocks, not as provider options.
  # Must use ReqLLM.Message structs (not loose maps) for structured content.
  # Only the last system message gets cache_control to stay within Anthropic's 4-breakpoint limit.
  defp add_cache_control_to_messages(messages) do
    # Find the index of the last system message
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
        # Only add cache_control to the last system message
        content_part =
          ReqLLM.Message.ContentPart.text(content, %{cache_control: %{type: "ephemeral"}})

        %ReqLLM.Message{role: :system, content: [content_part]}

      {%{role: :system, content: content}, _idx} when is_binary(content) ->
        %ReqLLM.Message{role: :system, content: [ReqLLM.Message.ContentPart.text(content)]}

      # Convert other loose maps to Message structs for consistency
      {%{role: role, content: content}, _idx} when is_atom(role) and is_binary(content) ->
        %ReqLLM.Message{role: role, content: [ReqLLM.Message.ContentPart.text(content)]}

      # Already a Message struct - pass through
      {%ReqLLM.Message{} = message, _idx} ->
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
    |> Enum.map(fn
      %{role: :system, content: content} -> "System: #{content}"
      %{role: :user, content: content} -> "User: #{content}"
      %{role: :assistant, content: content} -> "Assistant: #{content}"
    end)
    |> Enum.join("\n\n")
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

  # Build normalized token map from ReqLLM response
  defp build_tokens_from_req_llm_response(usage, provider_meta) do
    cache_write_from_meta = extract_cache_write_tokens(provider_meta)

    # Check all known cache field names across providers:
    # - :cached_tokens / :cache_read_input_tokens (Anthropic/Bedrock)
    # - :cache_creation_input_tokens / :cache_creation_tokens (Anthropic/Bedrock)
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

  # Extract cache_write_tokens from provider_meta (raw OpenRouter/Anthropic response)
  # OpenRouter returns: usage.prompt_tokens_details.cache_write_tokens
  defp extract_cache_write_tokens(nil), do: 0

  defp extract_cache_write_tokens(%{} = meta) do
    # Try different paths where cache_write might be stored
    get_in(meta, ["usage", "prompt_tokens_details", "cache_write_tokens"]) ||
      get_in(meta, [:usage, :prompt_tokens_details, :cache_write_tokens]) ||
      get_in(meta, ["prompt_tokens_details", "cache_write_tokens"]) ||
      0
  end

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
        # Bedrock can use either IAM credentials or session tokens
        System.get_env("AWS_ACCESS_KEY_ID") != nil or
          System.get_env("AWS_SESSION_TOKEN") != nil

      true ->
        # Unknown provider, assume available
        true
    end
  end
end
