defmodule PtcRunner.TestSupport.LLM do
  @moduledoc """
  Test wrapper around LLMClient with simplified return type.

  Returns `{:ok, text}` instead of `{:ok, %{content, tokens}}` for simpler test assertions.
  """

  @doc """
  Generate text from an LLM.

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec generate_text(String.t(), [map()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate_text(model, messages, opts \\ []) do
    case LLMClient.generate_text(model, messages, opts) do
      {:ok, %{content: text}} -> {:ok, text}
      error -> error
    end
  end

  @doc """
  Check if a provider is available.
  """
  defdelegate available?(model), to: LLMClient

  @doc """
  Check if the model requires an API key.
  """
  defdelegate requires_api_key?(model), to: LLMClient
end
