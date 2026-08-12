defmodule PtcRunner.LLM.Registry do
  @moduledoc """
  Resolves trusted model aliases to provider model identifiers.

  The standard Kernel LLM provider builder uses this registry while assembling
  an explicit `llm-request` capability. Manifests cannot replace the registry
  or name adapter modules.
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

  @doc false
  def resolve(name), do: impl().resolve(name)

  @doc false
  def resolve!(name) do
    case resolve(name) do
      {:ok, model_id} -> model_id
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp impl do
    case Application.get_env(:ptc_runner, :model_registry) do
      nil ->
        raise "No model registry configured. Set config :ptc_runner, :model_registry, MyRegistry"

      mod ->
        mod
    end
  end
end
