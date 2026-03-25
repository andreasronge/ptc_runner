defmodule PtcRunner.LLM.Registry do
  @moduledoc """
  Behaviour and unified interface for model resolution.

  Resolves model aliases (e.g., "haiku") to full provider:model strings
  (e.g., "openrouter:anthropic/claude-haiku-4.5"). This enables simple
  model references in SubAgent.run:

      # Instead of building callbacks manually:
      {:ok, step} = SubAgent.run(agent, llm: "haiku")
      {:ok, step} = SubAgent.run(agent, llm: "bedrock:haiku")

  ## Configuration

  The default implementation uses built-in aliases. To swap registries:

      config :ptc_runner, :model_registry, MyApp.ModelRegistry

  Or configure the default provider:

      config :ptc_runner, :default_provider, :bedrock

  ## Custom Registry

  Implement the behaviour to add custom aliases:

      defmodule MyApp.ModelRegistry do
        @behaviour PtcRunner.LLM.Registry

        @impl true
        def resolve("fast"), do: {:ok, "anthropic:claude-haiku-4-5-20251001"}
        def resolve("smart"), do: {:ok, "anthropic:claude-sonnet-4-5-20250929"}
        def resolve(name), do: PtcRunner.LLM.DefaultRegistry.resolve(name)

        # Delegate remaining callbacks to DefaultRegistry
        defdelegate resolve!(name), to: PtcRunner.LLM.DefaultRegistry
        defdelegate default_model(), to: PtcRunner.LLM.DefaultRegistry
        defdelegate default_provider(), to: PtcRunner.LLM.DefaultRegistry
        defdelegate aliases(), to: PtcRunner.LLM.DefaultRegistry
        defdelegate list_models(), to: PtcRunner.LLM.DefaultRegistry
        defdelegate preset_models(provider), to: PtcRunner.LLM.DefaultRegistry
        defdelegate available_providers(), to: PtcRunner.LLM.DefaultRegistry
        defdelegate provider_from_model(model), to: PtcRunner.LLM.DefaultRegistry
        defdelegate validate(model_string), to: PtcRunner.LLM.DefaultRegistry
      end
  """

  @doc """
  Resolve a model name or alias to a full provider:model string.

  ## Formats

  - `"alias"` - Resolves using default provider (e.g., "haiku" -> "openrouter:...")
  - `"provider:alias"` - Resolves with specific provider (e.g., "bedrock:haiku")
  - `"provider:full/model/id"` - Passes through as-is

  ## Examples

      iex> PtcRunner.LLM.Registry.resolve("haiku")
      {:ok, "openrouter:anthropic/claude-haiku-4.5"}

      iex> PtcRunner.LLM.Registry.resolve("bedrock:haiku")
      {:ok, "amazon_bedrock:anthropic.claude-haiku-4-5-20251001-v1:0"}
  """
  @callback resolve(String.t()) :: {:ok, String.t()} | {:error, String.t()}

  @doc "Resolve a model name, raising on error."
  @callback resolve!(String.t()) :: String.t()

  @doc "Get the default model using the default provider."
  @callback default_model() :: String.t()

  @doc "Get the default provider atom."
  @callback default_provider() :: atom()

  @doc "Get list of all alias names."
  @callback aliases() :: [String.t()]

  @doc "List all models with availability status."
  @callback list_models() :: [map()]

  @doc "Get model presets for a provider as alias -> model_id map."
  @callback preset_models(atom()) :: %{String.t() => String.t()}

  @doc "Get list of available providers based on environment."
  @callback available_providers() :: [atom()]

  @doc "Extract the provider atom from a model string."
  @callback provider_from_model(String.t()) :: atom() | nil

  @doc "Validate a model string format."
  @callback validate(String.t()) :: :ok | {:error, String.t()}

  # Delegate to configured implementation

  @doc false
  def resolve(name), do: impl().resolve(name)

  @doc false
  def resolve!(name), do: impl().resolve!(name)

  @doc false
  def default_model, do: impl().default_model()

  @doc false
  def default_provider, do: impl().default_provider()

  @doc false
  def aliases, do: impl().aliases()

  @doc false
  def list_models, do: impl().list_models()

  @doc false
  def preset_models(provider \\ default_provider()), do: impl().preset_models(provider)

  @doc false
  def available_providers, do: impl().available_providers()

  @doc false
  def provider_from_model(model), do: impl().provider_from_model(model)

  @doc false
  def validate(model_string), do: impl().validate(model_string)

  defp impl do
    Application.get_env(:ptc_runner, :model_registry, PtcRunner.LLM.DefaultRegistry)
  end
end
