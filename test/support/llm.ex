defmodule PtcRunner.TestSupport.LLM do
  @moduledoc """
  Unified LLM client for tests, supporting multiple providers.

  Routes requests based on model prefix:
  - `ollama:model-name` → Local Ollama server
  - `openai-compat:base_url|model` → Any OpenAI-compatible API
  - `*` → ReqLLM (OpenRouter, Anthropic, Google, etc.)

  ## Examples

      # Local Ollama
      LLM.generate_text("ollama:deepseek-coder:6.7b", messages)

      # ReqLLM providers (default)
      LLM.generate_text("openrouter:anthropic/claude-haiku-4.5", messages)
  """

  require Logger

  @default_timeout 120_000
  @ollama_base_url "http://localhost:11434"

  @type message :: %{role: :system | :user | :assistant, content: String.t()}

  @doc """
  Generate text from an LLM.

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec generate_text(String.t(), [message()], keyword()) :: {:ok, String.t()} | {:error, term()}
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
  Check if a provider is available.
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

    prompt = format_messages_as_prompt(messages)

    Logger.debug("Calling Ollama: #{model}")

    case Req.post("#{base_url}/api/generate",
           json: %{model: model, prompt: prompt, stream: false},
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: %{"response" => text}}} ->
        {:ok, text}

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

    case Req.post("#{base_url}/chat/completions",
           json: %{model: model, messages: formatted_messages},
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: body}} ->
        text = get_in(body, ["choices", Access.at(0), "message", "content"]) || ""
        {:ok, text}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_req_llm(model, messages, opts) do
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)

    case ReqLLM.generate_text(model, messages, receive_timeout: timeout) do
      {:ok, response} ->
        text = ReqLLM.Response.text(response) || ""
        {:ok, text}

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
    |> Enum.map_join("\n\n", fn
      %{role: :system, content: content} -> "System: #{content}"
      %{role: :user, content: content} -> "User: #{content}"
      %{role: :assistant, content: content} -> "Assistant: #{content}"
    end)
    |> Kernel.<>("\n\nAssistant:")
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
        true
    end
  end
end
