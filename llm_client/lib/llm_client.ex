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

  # Provider functions
  defdelegate generate_text(model, messages, opts \\ []), to: LLMClient.Providers
  defdelegate generate_text!(model, messages, opts \\ []), to: LLMClient.Providers
  defdelegate available?(model), to: LLMClient.Providers
  defdelegate requires_api_key?(model), to: LLMClient.Providers

  # Registry functions
  defdelegate resolve(name), to: LLMClient.Registry
  defdelegate resolve!(name), to: LLMClient.Registry
  defdelegate default_model(), to: LLMClient.Registry
  defdelegate validate(model_string), to: LLMClient.Registry

  defdelegate calculate_cost(alias_or_model_id, input_tokens, output_tokens),
    to: LLMClient.Registry

  @doc """
  Get all model presets as a map of alias to model ID.

  ## Example

      LLMClient.presets()
      # => %{"haiku" => "openrouter:anthropic/claude-haiku-4.5", ...}
  """
  defdelegate presets(), to: LLMClient.Registry, as: :preset_models

  @doc """
  Get list of all model aliases.

  ## Example

      LLMClient.aliases()
      # => ["deepseek", "deepseek-local", "gemini", "gpt", "haiku", ...]
  """
  defdelegate aliases(), to: LLMClient.Registry

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
