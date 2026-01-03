defmodule LLMClient.Registry do
  @moduledoc """
  Simple model registry for LLM providers.

  Supports multiple provider types:
  - Aliases resolve to OpenRouter models (requires OPENROUTER_API_KEY)
  - Local Ollama models via `ollama:model-name`
  - OpenAI-compatible APIs via `openai-compat:base_url|model`
  - Direct provider access via `anthropic:model`, `openai:model`, etc.

  ## Usage

      # Resolve an alias to OpenRouter model ID
      {:ok, model_id} = LLMClient.Registry.resolve("haiku")
      # => {:ok, "openrouter:anthropic/claude-haiku-4.5"}

      # Use local Ollama model
      {:ok, model_id} = LLMClient.Registry.resolve("ollama:deepseek-coder:6.7b")

      # Use explicit provider (bypasses aliases)
      {:ok, model_id} = LLMClient.Registry.resolve("anthropic:claude-haiku-4.5")

      # List available models
      LLMClient.Registry.format_model_list() |> IO.puts()
  """

  # Unified model metadata: alias -> %{id, description, costs}
  @models %{
    # Cloud models (via OpenRouter)
    "haiku" => %{
      id: "openrouter:anthropic/claude-haiku-4.5",
      description: "Claude Haiku 4.5 - Fast, cost-effective",
      costs: %{input: 0.80, output: 4.00}
    },
    "sonnet" => %{
      id: "openrouter:anthropic/claude-sonnet-4",
      description: "Claude Sonnet 4 - Balanced performance",
      costs: %{input: 3.00, output: 15.00}
    },
    "devstral" => %{
      id: "openrouter:mistralai/devstral-2512:free",
      description: "Devstral 2512 - Mistral AI code model (free)",
      costs: %{input: 0.0, output: 0.0}
    },
    "gemini" => %{
      id: "openrouter:google/gemini-2.5-flash",
      description: "Gemini 2.5 Flash - Google's fast model",
      costs: %{input: 0.15, output: 0.60}
    },
    "deepseek" => %{
      id: "openrouter:deepseek/deepseek-chat-v3-0324",
      description: "DeepSeek Chat V3 - Cost-effective reasoning",
      costs: %{input: 0.14, output: 0.28}
    },
    "kimi" => %{
      id: "openrouter:moonshotai/kimi-k2",
      description: "Kimi K2 - Moonshot AI's model",
      costs: %{input: 0.60, output: 2.40}
    },
    "gpt" => %{
      id: "openrouter:openai/gpt-4.1-mini",
      description: "GPT-4.1 Mini - OpenAI's efficient model",
      costs: %{input: 0.40, output: 1.60}
    },
    # Local models (via Ollama) - free
    "deepseek-local" => %{
      id: "ollama:deepseek-coder:6.7b",
      description: "DeepSeek Coder 6.7B - Local via Ollama",
      costs: %{input: 0.0, output: 0.0}
    },
    "qwen-local" => %{
      id: "ollama:qwen2.5-coder:7b",
      description: "Qwen 2.5 Coder 7B - Local via Ollama",
      costs: %{input: 0.0, output: 0.0}
    },
    "llama-local" => %{
      id: "ollama:llama3.2:3b",
      description: "Llama 3.2 3B - Local via Ollama (fast)",
      costs: %{input: 0.0, output: 0.0}
    }
  }

  @default_model "haiku"

  @doc """
  Resolve a model name to a full model ID.

  - Aliases (haiku, gemini, etc.) resolve to OpenRouter models
  - Explicit format (provider:model) passes through after validation

  ## Examples

      iex> LLMClient.Registry.resolve("haiku")
      {:ok, "openrouter:anthropic/claude-haiku-4.5"}

      iex> LLMClient.Registry.resolve("anthropic:claude-haiku-4.5")
      {:ok, "anthropic:claude-haiku-4.5"}
  """
  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(name) when is_binary(name) do
    cond do
      # Known alias -> OpenRouter model
      Map.has_key?(@models, name) ->
        {:ok, @models[name].id}

      # Explicit provider format -> validate and pass through
      String.contains?(name, ":") ->
        validate_and_return(name)

      true ->
        {:error, unknown_model_error(name)}
    end
  end

  @doc """
  Resolve a model name, raising on error.
  """
  @spec resolve!(String.t()) :: String.t()
  def resolve!(name) do
    case resolve(name) do
      {:ok, model_id} -> model_id
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc """
  Get the default model (haiku via OpenRouter).
  """
  @spec default_model() :: String.t()
  def default_model do
    @models[@default_model].id
  end

  @doc """
  List all available model aliases with status.
  """
  @spec list_models() :: [map()]
  def list_models do
    providers = available_providers()

    @models
    |> Enum.map(fn {alias_name, meta} ->
      model_providers = providers_for_model(meta.id)

      %{
        alias: alias_name,
        model_id: meta.id,
        description: meta.description,
        providers: model_providers,
        available: Enum.any?(model_providers, &(&1 in providers))
      }
    end)
    |> Enum.sort_by(& &1.alias)
  end

  @doc """
  Get all available providers based on environment variables.
  """
  @spec available_providers() :: [atom()]
  def available_providers do
    [
      {:anthropic, "ANTHROPIC_API_KEY"},
      {:openai, "OPENAI_API_KEY"},
      {:google, "GOOGLE_API_KEY"},
      {:openrouter, "OPENROUTER_API_KEY"}
    ]
    |> Enum.filter(fn {_p, env} -> System.get_env(env) != nil end)
    |> Enum.map(fn {p, _env} -> p end)
    |> then(fn cloud ->
      if LLMClient.Providers.available?("ollama:test"), do: [:ollama | cloud], else: cloud
    end)
  end

  @doc """
  Get detailed info for a model by alias or model_id.
  """
  @spec get_model_info(String.t()) :: map() | nil
  def get_model_info(alias_or_model_id) do
    # Try alias first
    case Map.get(@models, alias_or_model_id) do
      nil ->
        # Try as model_id
        alias_name =
          Enum.find_value(@models, fn {a, meta} ->
            if meta.id == alias_or_model_id, do: a
          end)

        if alias_name, do: build_model_info(alias_name), else: nil

      _meta ->
        build_model_info(alias_or_model_id)
    end
  end

  defp build_model_info(alias_name) do
    meta = @models[alias_name]

    %{
      alias: alias_name,
      model_id: meta.id,
      description: meta.description,
      input_cost_per_mtok: meta.costs.input,
      output_cost_per_mtok: meta.costs.output,
      providers: providers_for_model(meta.id)
    }
  end

  defp providers_for_model(model_id) do
    cond do
      String.starts_with?(model_id, "openrouter:") -> [:openrouter]
      String.starts_with?(model_id, "ollama:") -> [:ollama]
      String.starts_with?(model_id, "anthropic:") -> [:anthropic]
      String.starts_with?(model_id, "openai:") -> [:openai]
      String.starts_with?(model_id, "google:") -> [:google]
      true -> []
    end
  end

  @doc """
  Format models for CLI --list-models output.
  """
  @spec format_model_list() :: String.t()
  def format_model_list do
    available = available_providers()

    {cloud_models, local_models} =
      list_models()
      |> Enum.split_with(fn m ->
        Enum.any?([:openrouter, :anthropic, :openai, :google], &(&1 in m.providers))
      end)

    header = """
    Available Models
    ================

    Cloud Models:
    """

    cloud_section =
      cloud_models
      |> Enum.map(fn model ->
        status = if model.available, do: "[available]", else: "[needs API key]"
        providers_str = model.providers |> Enum.map(&to_string/1) |> Enum.join(", ")

        "  #{String.pad_trailing(model.alias, 12)} #{String.pad_trailing(status, 16)} #{model.description}\n" <>
          "               Providers: #{providers_str}"
      end)
      |> Enum.join("\n\n")

    local_header = """

    Local Models (via Ollama):
    """

    local_section =
      local_models
      |> Enum.map(fn model ->
        status = if model.available, do: "[available]", else: "[needs Ollama]"

        "  #{String.pad_trailing(model.alias, 12)} #{String.pad_trailing(status, 16)} #{model.description}"
      end)
      |> Enum.join("\n")

    api_keys =
      [
        {"ANTHROPIC_API_KEY", :anthropic},
        {"OPENROUTER_API_KEY", :openrouter},
        {"OPENAI_API_KEY", :openai},
        {"GOOGLE_API_KEY", :google}
      ]
      |> Enum.filter(fn {_env, p} -> p in available end)
      |> Enum.map(fn {env, _p} -> env end)
      |> Enum.join(", ")

    api_keys_str = if api_keys == "", do: "none", else: api_keys

    footer = """


    Status:
      Current API keys: #{api_keys_str}
      Ollama: #{if :ollama in available, do: "running", else: "not running"}

    Usage:
      mix lisp --model=haiku                                 # Cloud alias
      mix lisp --model=deepseek-local                        # Local alias
      mix lisp --model=ollama:codellama:7b                   # Direct Ollama
      mix lisp --model=openrouter:anthropic/claude-sonnet-4  # Direct OpenRouter
    """

    header <> cloud_section <> local_header <> local_section <> footer
  end

  @doc """
  Validate a model string format.

  Valid formats:
  - "alias" - Known alias (haiku, gemini, deepseek-local, etc.)
  - "provider:model" - Direct provider (anthropic:claude-haiku-4.5)
  - "openrouter:provider/model" - OpenRouter format
  - "ollama:model-name" - Local Ollama model
  - "openai-compat:base_url|model" - OpenAI-compatible API
  """
  @spec validate(String.t()) :: :ok | {:error, String.t()}
  def validate(model_string) do
    cond do
      Map.has_key?(@models, model_string) ->
        :ok

      # Ollama models
      Regex.match?(~r/^ollama:[\w.-]+(:[\w.-]+)?$/, model_string) ->
        :ok

      # OpenAI-compatible APIs
      String.starts_with?(model_string, "openai-compat:") ->
        :ok

      # Direct providers (anthropic, openai, google)
      Regex.match?(~r/^(anthropic|openai|google):[\w.-]+$/, model_string) ->
        :ok

      # OpenRouter format
      Regex.match?(~r/^openrouter:[\w-]+\/[\w.-]+(:\w+)?$/, model_string) ->
        :ok

      Regex.match?(~r/^openrouter:\w+:\w+/, model_string) and
          not Regex.match?(~r/^openrouter:[\w-]+\//, model_string) ->
        {:error,
         "Invalid OpenRouter format: '#{model_string}'. Use 'openrouter:provider/model' (slash, not colon)"}

      true ->
        {:error,
         "Unknown model format: '#{model_string}'. Use 'provider:model', 'ollama:model', or 'openrouter:provider/model'"}
    end
  end

  @doc """
  Get all aliases as a map (for CLI /model command).
  """
  @spec preset_models() :: %{String.t() => String.t()}
  def preset_models do
    Map.new(@models, fn {alias_name, meta} -> {alias_name, meta.id} end)
  end

  @doc """
  Get list of all alias names.
  """
  @spec aliases() :: [String.t()]
  def aliases, do: Map.keys(@models) |> Enum.sort()

  @doc """
  Calculate cost from token counts.

  Uses the model's cost rates if available (looks up by alias or model_id).
  Returns the cost in dollars or 0.0 if rates not available.
  """
  @spec calculate_cost(String.t(), non_neg_integer(), non_neg_integer()) :: float()
  def calculate_cost(alias_or_model_id, input_tokens, output_tokens) do
    costs = find_costs(alias_or_model_id)

    case costs do
      nil ->
        0.0

      %{input: input_rate, output: output_rate} ->
        input_rate * input_tokens / 1_000_000 + output_rate * output_tokens / 1_000_000
    end
  end

  # Private functions

  defp find_costs(alias_or_model_id) do
    # Try direct alias lookup first
    case Map.get(@models, alias_or_model_id) do
      %{costs: costs} ->
        costs

      nil ->
        # Try as model_id
        case Enum.find(@models, fn {_alias, meta} -> meta.id == alias_or_model_id end) do
          {_alias, meta} -> meta.costs
          nil -> nil
        end
    end
  end

  defp validate_and_return(model_string) do
    case validate(model_string) do
      :ok -> {:ok, model_string}
      error -> error
    end
  end

  defp unknown_model_error(name) do
    aliases_str = aliases() |> Enum.join(", ")

    """
    Unknown model: '#{name}'

    Available aliases: #{aliases_str}

    Or use explicit provider format:
      - OpenRouter: openrouter:anthropic/claude-haiku-4.5
      - Direct: anthropic:claude-haiku-4.5

    Run with --list-models to see all options.
    """
  end
end
