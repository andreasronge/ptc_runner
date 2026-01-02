defmodule PtcDemo.ModelRegistry do
  @moduledoc """
  Simple model registry for the demo.

  All aliases resolve to OpenRouter models (requires only OPENROUTER_API_KEY).
  For direct provider access, use explicit syntax like `anthropic:claude-haiku-4.5`.

  ## Usage

      # Resolve an alias to OpenRouter model ID
      {:ok, model_id} = ModelRegistry.resolve("haiku")
      # => {:ok, "openrouter:anthropic/claude-haiku-4.5"}

      # Use explicit provider (bypasses aliases)
      {:ok, model_id} = ModelRegistry.resolve("anthropic:claude-haiku-4.5")

      # List available models
      ModelRegistry.format_model_list() |> IO.puts()
  """

  # Simple alias -> OpenRouter model ID mapping
  @models %{
    "haiku" => "openrouter:anthropic/claude-haiku-4.5",
    "sonnet" => "openrouter:anthropic/claude-sonnet-4",
    "devstral" => "openrouter:mistralai/devstral-2512:free",
    "gemini" => "openrouter:google/gemini-2.5-flash",
    "deepseek" => "openrouter:deepseek/deepseek-chat-v3-0324",
    "kimi" => "openrouter:moonshotai/kimi-k2",
    "gpt" => "openrouter:openai/gpt-4.1-mini"
  }

  # Descriptions for --list-models output
  @model_info %{
    "haiku" => "Claude Haiku 4.5 - Fast, cost-effective",
    "sonnet" => "Claude Sonnet 4 - Balanced performance",
    "devstral" => "Devstral 2512 - Mistral AI code model (free)",
    "gemini" => "Gemini 2.5 Flash - Google's fast model",
    "deepseek" => "DeepSeek Chat V3 - Cost-effective reasoning",
    "kimi" => "Kimi K2 - Moonshot AI's model",
    "gpt" => "GPT-4.1 Mini - OpenAI's efficient model"
  }

  # Cost per million tokens (for estimation)
  @model_costs %{
    "haiku" => %{input: 0.80, output: 4.00},
    "sonnet" => %{input: 3.00, output: 15.00},
    "devstral" => %{input: 0.0, output: 0.0},
    "gemini" => %{input: 0.15, output: 0.60},
    "deepseek" => %{input: 0.14, output: 0.28},
    "kimi" => %{input: 0.60, output: 2.40},
    "gpt" => %{input: 0.40, output: 1.60}
  }

  @default_model "haiku"

  @doc """
  Resolve a model name to a full model ID.

  - Aliases (haiku, gemini, etc.) resolve to OpenRouter models
  - Explicit format (provider:model) passes through after validation

  ## Examples

      iex> PtcDemo.ModelRegistry.resolve("haiku")
      {:ok, "openrouter:anthropic/claude-haiku-4.5"}

      iex> PtcDemo.ModelRegistry.resolve("anthropic:claude-haiku-4.5")
      {:ok, "anthropic:claude-haiku-4.5"}
  """
  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(name) when is_binary(name) do
    cond do
      # Known alias -> OpenRouter model
      Map.has_key?(@models, name) ->
        {:ok, Map.get(@models, name)}

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
    Map.get(@models, @default_model)
  end

  @doc """
  List all available model aliases.
  """
  @spec list_models() :: [map()]
  def list_models do
    @models
    |> Enum.map(fn {alias_name, model_id} ->
      %{
        alias: alias_name,
        model_id: model_id,
        description: Map.get(@model_info, alias_name, "")
      }
    end)
    |> Enum.sort_by(& &1.alias)
  end

  @doc """
  Format models for CLI --list-models output.
  """
  @spec format_model_list() :: String.t()
  def format_model_list do
    has_key? = System.get_env("OPENROUTER_API_KEY") != nil

    header = """
    Model Aliases (via OpenRouter)
    ===============================

    """

    models =
      list_models()
      |> Enum.map(fn model ->
        "  #{String.pad_trailing(model.alias, 10)} #{model.description}\n" <>
          "             #{model.model_id}"
      end)
      |> Enum.join("\n\n")

    status =
      if has_key?,
        do: "OPENROUTER_API_KEY is set",
        else: "OPENROUTER_API_KEY not set (required for aliases)"

    footer = """


    Status: #{status}

    Usage:
      mix lisp --model=haiku                              # Use alias
      mix lisp --model=openrouter:anthropic/claude-sonnet-4  # Explicit OpenRouter
      mix lisp --model=anthropic:claude-haiku-4.5         # Direct Anthropic API
    """

    header <> models <> footer
  end

  @doc """
  Validate a model string format.

  Valid formats:
  - "alias" - Known alias (haiku, gemini, etc.)
  - "provider:model" - Direct provider (anthropic:claude-haiku-4.5)
  - "openrouter:provider/model" - OpenRouter format
  """
  @spec validate(String.t()) :: :ok | {:error, String.t()}
  def validate(model_string) do
    cond do
      Map.has_key?(@models, model_string) ->
        :ok

      Regex.match?(~r/^(anthropic|openai|google):[\w.-]+$/, model_string) ->
        :ok

      Regex.match?(~r/^openrouter:[\w-]+\/[\w.-]+(:\w+)?$/, model_string) ->
        :ok

      Regex.match?(~r/^openrouter:\w+:\w+/, model_string) and
          not Regex.match?(~r/^openrouter:[\w-]+\//, model_string) ->
        {:error,
         "Invalid OpenRouter format: '#{model_string}'. Use 'openrouter:provider/model' (slash, not colon)"}

      true ->
        {:error,
         "Unknown model format: '#{model_string}'. Use 'provider:model' or 'openrouter:provider/model'"}
    end
  end

  @doc """
  Get all aliases as a map (for CLI /model command).
  """
  @spec preset_models() :: %{String.t() => String.t()}
  def preset_models, do: @models

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
    # Try direct alias lookup first
    costs =
      Map.get(@model_costs, alias_or_model_id) ||
        find_costs_by_model_id(alias_or_model_id)

    case costs do
      nil ->
        0.0

      %{input: input_rate, output: output_rate} ->
        input_rate * input_tokens / 1_000_000 + output_rate * output_tokens / 1_000_000
    end
  end

  # Private functions

  defp validate_and_return(model_string) do
    case validate(model_string) do
      :ok -> {:ok, model_string}
      error -> error
    end
  end

  defp find_costs_by_model_id(model_id) do
    # Find alias that maps to this model_id
    case Enum.find(@models, fn {_alias, id} -> id == model_id end) do
      {alias_name, _} -> Map.get(@model_costs, alias_name)
      nil -> nil
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
