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

  @type message :: %{role: :system | :user | :assistant, content: String.t()}
  @type response :: %{
          content: String.t(),
          tokens: %{input: non_neg_integer(), output: non_neg_integer()}
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

  ## Returns
    - `{:ok, %{content: string, tokens: %{input: int, output: int}}}`
    - `{:error, reason}`
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
        tokens = extract_ollama_tokens(body)
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

        tokens = %{
          input: usage["prompt_tokens"] || 0,
          output: usage["completion_tokens"] || 0
        }

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

    case ReqLLM.generate_text(model, messages,
           receive_timeout: timeout,
           req_http_options: http_opts
         ) do
      {:ok, response} ->
        text = ReqLLM.Response.text(response) || ""
        usage = ReqLLM.Response.usage(response) || %{}

        tokens = %{
          input: usage[:input_tokens] || usage["input_tokens"] || 0,
          output: usage[:output_tokens] || usage["output_tokens"] || 0
        }

        {:ok, %{content: text, tokens: tokens}}

      {:error, reason} ->
        {:error, reason}
    end
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

      true ->
        # Unknown provider, assume available
        true
    end
  end
end
