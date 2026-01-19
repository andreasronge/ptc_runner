defmodule LLMClient do
  @moduledoc """
  Unified LLM client for local and cloud providers.

  Routes requests based on model prefix:
  - `ollama:model-name` → Local Ollama server
  - `openai-compat:base_url|model` → Any OpenAI-compatible API
  - `*` → ReqLLM (OpenRouter, Anthropic, Google, etc.)

  ## Usage

      # Generate text with a cloud model
      {:ok, response} = LLMClient.generate_text("openrouter:anthropic/claude-haiku-4.5", messages)
      response.content  # => "Hello!"
      response.tokens   # => %{input: 10, output: 5}

      # Use model aliases
      {:ok, model_id} = LLMClient.resolve("haiku")
      {:ok, response} = LLMClient.generate_text(model_id, messages)

      # Check availability
      LLMClient.available?("ollama:deepseek-coder:6.7b")  # => true/false

  ## Model Aliases

  Built-in aliases for common models:
  - `haiku`, `sonnet` - Claude models via OpenRouter
  - `gemini` - Google Gemini via OpenRouter
  - `deepseek`, `kimi`, `gpt` - Other cloud models
  - `deepseek-local`, `qwen-local`, `llama-local` - Local Ollama models

  Use `LLMClient.presets/0` to get all aliases.
  """

  # Provider functions with auto-resolve
  def generate_text(model, messages, opts \\ []) do
    with {:ok, resolved} <- LLMClient.Registry.resolve(model) do
      LLMClient.Providers.generate_text(resolved, messages, opts)
    end
  end

  def generate_text!(model, messages, opts \\ []) do
    resolved = LLMClient.Registry.resolve!(model)
    LLMClient.Providers.generate_text!(resolved, messages, opts)
  end

  def generate_object(model, messages, schema, opts \\ []) do
    with {:ok, resolved} <- LLMClient.Registry.resolve(model) do
      LLMClient.Providers.generate_object(resolved, messages, schema, opts)
    end
  end

  def generate_object!(model, messages, schema, opts \\ []) do
    resolved = LLMClient.Registry.resolve!(model)
    LLMClient.Providers.generate_object!(resolved, messages, schema, opts)
  end

  def available?(model) do
    case LLMClient.Registry.resolve(model) do
      {:ok, resolved} -> LLMClient.Providers.available?(resolved)
      {:error, _} -> false
    end
  end

  def requires_api_key?(model) do
    case LLMClient.Registry.resolve(model) do
      {:ok, resolved} -> LLMClient.Providers.requires_api_key?(resolved)
      {:error, _} -> true
    end
  end

  # SubAgent callback functions
  defdelegate callback(model_or_alias), to: LLMClient.Providers
  defdelegate call(model, request), to: LLMClient.Providers

  # Registry functions
  defdelegate resolve(name), to: LLMClient.Registry
  defdelegate resolve!(name), to: LLMClient.Registry
  defdelegate default_model(), to: LLMClient.Registry
  defdelegate validate(model_string), to: LLMClient.Registry

  defdelegate calculate_cost(alias_or_model_id, tokens), to: LLMClient.Registry

  @doc """
  Get all model presets as a map of alias to model ID.

  ## Examples

      LLMClient.presets()
      # => %{"haiku" => "openrouter:anthropic/claude-haiku-4.5", ...}

      LLMClient.presets(:bedrock)
      # => %{"haiku" => "amazon_bedrock:anthropic.claude-3-haiku-20240307-v1:0", ...}
  """
  def presets(provider \\ nil) do
    if provider do
      LLMClient.Registry.preset_models(provider)
    else
      LLMClient.Registry.preset_models()
    end
  end

  @doc """
  Get list of all model aliases.

  ## Example

      LLMClient.aliases()
      # => ["deepseek", "deepseek-local", "gemini", "gpt", "haiku", ...]
  """
  defdelegate aliases(), to: LLMClient.Registry

  @doc """
  Extract the provider from a model string.

  ## Example

      LLMClient.provider_from_model("amazon_bedrock:anthropic.claude-3-haiku")
      # => :amazon_bedrock
  """
  defdelegate provider_from_model(model), to: LLMClient.Registry

  @doc """
  List all models with availability status.
  """
  defdelegate list_models(), to: LLMClient.Registry

  @doc """
  Get detailed info for a model.
  """
  defdelegate get_model_info(alias_or_model_id), to: LLMClient.Registry

  @doc """
  Format model list for CLI output.
  """
  defdelegate format_model_list(), to: LLMClient.Registry

  @doc """
  Get list of available providers.
  """
  defdelegate available_providers(), to: LLMClient.Registry
end
