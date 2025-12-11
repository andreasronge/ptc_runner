defmodule PtcDemo.ModelRegistry do
  @moduledoc """
  Single source of truth for model definitions and resolution.

  Provides:
  - Simple aliases (haiku, devstral, gemini, deepseek, kimi, gpt)
  - Auto-detection of best provider based on available API keys
  - Validation with helpful error messages
  - Cost information for fallback calculation

  ## Usage

      # Resolve an alias to a full model ID
      {:ok, model_id} = ModelRegistry.resolve("haiku")

      # Get the default model based on API keys
      model_id = ModelRegistry.default_model()

      # List available models
      ModelRegistry.format_model_list() |> IO.puts()
  """

  @type provider :: :anthropic | :openrouter | :openai | :google

  @models %{
    "haiku" => %{
      description: "Claude Haiku 4.5 - Fast, cost-effective",
      input_cost_per_mtok: 0.80,
      output_cost_per_mtok: 4.00,
      providers: [
        anthropic: "anthropic:claude-haiku-4.5",
        openrouter: "openrouter:anthropic/claude-haiku-4.5"
      ]
    },
    "devstral" => %{
      description: "Devstral 2512 - Mistral AI code model (free)",
      input_cost_per_mtok: 0.0,
      output_cost_per_mtok: 0.0,
      providers: [
        openrouter: "openrouter:mistralai/devstral-2512:free"
      ]
    },
    "gemini" => %{
      description: "Gemini 2.5 Flash - Google's fast model",
      input_cost_per_mtok: 0.15,
      output_cost_per_mtok: 0.60,
      providers: [
        google: "google:gemini-2.5-flash",
        openrouter: "openrouter:google/gemini-2.5-flash"
      ]
    },
    "deepseek" => %{
      description: "DeepSeek V3.2 - Cost-effective reasoning",
      input_cost_per_mtok: 0.14,
      output_cost_per_mtok: 0.28,
      providers: [
        openrouter: "openrouter:deepseek/deepseek-v3.2"
      ]
    },
    "kimi" => %{
      description: "Kimi K2 - Moonshot AI's model",
      input_cost_per_mtok: 0.60,
      output_cost_per_mtok: 2.40,
      providers: [
        openrouter: "openrouter:moonshotai/kimi-k2"
      ]
    },
    "gpt" => %{
      description: "GPT-5.1 Codex Mini - OpenAI code model",
      input_cost_per_mtok: 1.50,
      output_cost_per_mtok: 6.00,
      providers: [
        openai: "openai:gpt-5.1-codex-mini",
        openrouter: "openrouter:openai/gpt-5.1-codex-mini"
      ]
    }
  }

  @provider_keys %{
    anthropic: "ANTHROPIC_API_KEY",
    openrouter: "OPENROUTER_API_KEY",
    openai: "OPENAI_API_KEY",
    google: "GOOGLE_API_KEY"
  }

  @doc """
  Resolve a model name to a full model ID.

  Resolution order:
  1. Check if it's already a full model ID (contains ":")
  2. Look up in aliases
  3. Auto-select provider based on available API keys

  Returns `{:ok, model_id}` or `{:error, reason}`.
  """
  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(name) when is_binary(name) do
    cond do
      String.contains?(name, ":") ->
        validate_and_return(name)

      Map.has_key?(@models, name) ->
        resolve_for_available_provider(name)

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
  Get the default model based on available API keys.

  Uses "haiku" as the default alias.
  """
  @spec default_model() :: String.t()
  def default_model do
    resolve!("haiku")
  end

  @doc """
  List all available models with their availability status.

  Returns a list of maps with alias, description, providers, and availability.
  """
  @spec list_models() :: [map()]
  def list_models do
    available = available_providers()

    @models
    |> Enum.map(fn {alias_name, model} ->
      provider_atoms = Keyword.keys(model.providers)
      available? = Enum.any?(provider_atoms, &(&1 in available))

      %{
        alias: alias_name,
        description: model.description,
        providers: provider_atoms,
        available: available?
      }
    end)
    |> Enum.sort_by(& &1.alias)
  end

  @doc """
  Format models for CLI --list-models output.
  """
  @spec format_model_list() :: String.t()
  def format_model_list do
    available = available_providers()

    header = """
    Available Models
    ================

    """

    models =
      list_models()
      |> Enum.map(fn model ->
        status = if model.available, do: "[available]", else: "[needs API key]"
        providers = model.providers |> Enum.map(&to_string/1) |> Enum.join(", ")

        "  #{String.pad_trailing(model.alias, 10)} #{model.description}\n" <>
          "             Providers: #{providers} #{status}"
      end)
      |> Enum.join("\n\n")

    available_str =
      if available == [] do
        "none"
      else
        available |> Enum.map(&to_string/1) |> Enum.join(", ")
      end

    footer = """


    Current API keys: #{available_str}

    Usage:
      mix lisp --model=haiku           # Use alias
      mix lisp --model=anthropic:...   # Direct provider
      mix lisp --model=openrouter:...  # Via OpenRouter
    """

    header <> models <> footer
  end

  @doc """
  Validate a model string format.

  Valid formats:
  - "alias" - Known alias (haiku, gemini, etc.)
  - "provider:model" - Direct provider (anthropic:claude-haiku-4.5)
  - "openrouter:provider/model" - OpenRouter format

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate(String.t()) :: :ok | {:error, String.t()}
  def validate(model_string) do
    cond do
      # Known alias
      Map.has_key?(@models, model_string) ->
        :ok

      # Valid direct provider format (provider:model-name)
      Regex.match?(~r/^(anthropic|openai|google):[\w.-]+$/, model_string) ->
        :ok

      # Valid OpenRouter format (openrouter:provider/model or openrouter:provider/model:variant)
      Regex.match?(~r/^openrouter:[\w-]+\/[\w.-]+(:\w+)?$/, model_string) ->
        :ok

      # OpenRouter with colon instead of slash (common mistake)
      Regex.match?(~r/^openrouter:\w+:\w+/, model_string) and
          not Regex.match?(~r/^openrouter:[\w-]+\//, model_string) ->
        {:error,
         "Invalid OpenRouter format: '#{model_string}'. Use 'openrouter:provider/model' (slash, not colon after provider name)"}

      # Unknown format
      true ->
        {:error,
         "Unknown model format: '#{model_string}'. Use 'provider:model' or 'openrouter:provider/model'"}
    end
  end

  @doc """
  Get available API keys as provider atoms.
  """
  @spec available_providers() :: [provider()]
  def available_providers do
    @provider_keys
    |> Enum.filter(fn {_provider, env_var} -> System.get_env(env_var) end)
    |> Enum.map(fn {provider, _} -> provider end)
  end

  @doc """
  Get all aliases as a map for backwards compatibility.

  Returns a map of alias -> model_id using the first available provider.
  """
  @spec preset_models() :: %{String.t() => String.t()}
  def preset_models do
    available = available_providers()

    @models
    |> Enum.map(fn {alias_name, model} ->
      model_id =
        case find_available_provider(model.providers, available) do
          nil -> Keyword.values(model.providers) |> List.first()
          id -> id
        end

      {alias_name, model_id}
    end)
    |> Map.new()
  end

  @doc """
  Get full model info including cost rates.

  Returns the model definition map or nil if not found.
  """
  @spec get_model_info(String.t()) :: map() | nil
  def get_model_info(alias_or_model_id) do
    cond do
      Map.has_key?(@models, alias_or_model_id) ->
        Map.get(@models, alias_or_model_id)

      String.contains?(alias_or_model_id, ":") ->
        # Try to find by model ID in providers
        Enum.find_value(@models, fn {_alias, model} ->
          if alias_or_model_id in Keyword.values(model.providers) do
            model
          end
        end)

      true ->
        nil
    end
  end

  @doc """
  Calculate cost from token counts when API doesn't return it.

  Uses the model's cost rates if available.
  Returns the cost in dollars or 0.0 if rates not available.
  """
  @spec calculate_cost(String.t(), non_neg_integer(), non_neg_integer()) :: float()
  def calculate_cost(alias_or_model_id, input_tokens, output_tokens) do
    case get_model_info(alias_or_model_id) do
      nil ->
        0.0

      model ->
        input_cost = model.input_cost_per_mtok * input_tokens / 1_000_000
        output_cost = model.output_cost_per_mtok * output_tokens / 1_000_000
        input_cost + output_cost
    end
  end

  @doc """
  Get list of all alias names.
  """
  @spec aliases() :: [String.t()]
  def aliases do
    Map.keys(@models) |> Enum.sort()
  end

  # Private functions

  defp validate_and_return(model_string) do
    case validate(model_string) do
      :ok -> {:ok, model_string}
      error -> error
    end
  end

  defp resolve_for_available_provider(alias_name) do
    model = Map.get(@models, alias_name)
    available = available_providers()

    case find_available_provider(model.providers, available) do
      nil ->
        # Fall back to first provider (likely openrouter)
        {:ok, model.providers |> Keyword.values() |> List.first()}

      model_id ->
        {:ok, model_id}
    end
  end

  defp find_available_provider(providers, available) do
    Enum.find_value(providers, fn {provider, model_id} ->
      if provider in available, do: model_id
    end)
  end

  defp unknown_model_error(name) do
    aliases_str = aliases() |> Enum.join(", ")

    """
    Unknown model: '#{name}'

    Available aliases: #{aliases_str}

    Or use a full model ID:
      - Direct: anthropic:claude-haiku-4.5
      - OpenRouter: openrouter:anthropic/claude-haiku-4.5

    Run with --list-models to see all options.
    """
  end
end
