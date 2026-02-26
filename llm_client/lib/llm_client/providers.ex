defmodule LLMClient.Providers do
  @moduledoc """
  LLM provider interface with alias resolution and dotenv support.

  When used inside the ptc_runner project, delegates to `PtcRunner.LLM.ReqLLMAdapter`.
  When used standalone (e.g., `cd llm_client && mix test`), uses `req_llm` directly.
  """

  # Resolve the adapter module at runtime to avoid circular compile deps.
  # In ptc_runner context, PtcRunner.LLM.ReqLLMAdapter is available.
  # Standalone, we fall back to LLMClient.FallbackAdapter which has the same implementation.
  defp adapter do
    if Code.ensure_loaded?(PtcRunner.LLM.ReqLLMAdapter) do
      PtcRunner.LLM.ReqLLMAdapter
    else
      LLMClient.FallbackAdapter
    end
  end

  @doc """
  Create a SubAgent-compatible callback for a model.

  Loads `.env`, resolves aliases, and creates a callback via the adapter.

  ## Options

  - `:cache` - Enable prompt caching (default: false)
  """
  @spec callback(String.t(), keyword()) :: (map() -> {:ok, map()} | {:error, term()})
  def callback(model_or_alias, opts \\ []) do
    LLMClient.load_dotenv()
    model = LLMClient.Registry.resolve!(model_or_alias)
    mod = adapter()

    if opts == [] do
      fn req -> apply(mod, :call, [model, req]) end
    else
      fn req -> apply(mod, :call, [model, Map.merge(req, Map.new(opts))]) end
    end
  end

  @doc "Route a SubAgent request to the adapter."
  def call(model, request), do: apply(adapter(), :call, [model, request])

  @doc "Generate text from an LLM."
  def generate_text(model, messages, opts \\ []),
    do: apply(adapter(), :generate_text, [model, messages, opts])

  @doc "Generate text, raising on error."
  def generate_text!(model, messages, opts \\ []),
    do: apply(adapter(), :generate_text!, [model, messages, opts])

  @doc "Generate a structured JSON object."
  def generate_object(model, messages, schema, opts \\ []),
    do: apply(adapter(), :generate_object, [model, messages, schema, opts])

  @doc "Generate a structured JSON object, raising on error."
  def generate_object!(model, messages, schema, opts \\ []),
    do: apply(adapter(), :generate_object!, [model, messages, schema, opts])

  @doc "Generate text with tool definitions."
  def generate_with_tools(model, messages, tools, opts \\ []),
    do: apply(adapter(), :generate_with_tools, [model, messages, tools, opts])

  @doc "Generate embeddings for text input."
  def embed(model, input, opts \\ []),
    do: apply(adapter(), :embed, [model, input, opts])

  @doc "Generate embeddings, raising on error."
  def embed!(model, input, opts \\ []),
    do: apply(adapter(), :embed!, [model, input, opts])

  @doc "Stream an LLM response."
  def stream(model, request), do: apply(adapter(), :stream, [model, request])

  @doc "Check if a provider is available."
  def available?(model), do: apply(adapter(), :available?, [model])

  @doc "Check if the model requires an API key."
  def requires_api_key?(model), do: apply(adapter(), :requires_api_key?, [model])
end
