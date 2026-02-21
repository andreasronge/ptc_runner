defmodule PtcRunner.SubAgent.LLMResolver do
  @moduledoc """
  LLM resolution and invocation for SubAgents.

  Handles calling LLMs that can be either functions or atoms, with support for
  LLM registry lookups for atom-based LLM references (like `:haiku` or `:sonnet`).

  LLM responses are normalized to a consistent format:
  - Plain string responses become `%{content: string, tokens: nil}`
  - Map responses with `:content` key preserve tokens if present
  """

  @typedoc """
  Normalized LLM response with content, optional token counts, and optional tool calls.

  For tool calling mode, the response may include `tool_calls` instead of or in addition to `content`.
  """
  @type normalized_response ::
          %{content: String.t() | nil, tokens: map() | nil}
          | %{content: String.t() | nil, tokens: map() | nil, tool_calls: [map()]}

  @doc """
  Resolve and invoke an LLM, handling both functions and atom references.

  Normalizes the LLM response to always return a map with `:content` and `:tokens` keys.
  This provides a consistent interface for callers regardless of whether the LLM
  callback returns a plain string or a map with token information.

  ## Parameters

  - `llm` - Either a function/1 or an atom referencing the registry
  - `input` - The LLM input map to pass to the callback
  - `registry` - Map of atom to LLM callback for atom-based LLM references

  ## Returns

  - `{:ok, %{content: String.t(), tokens: map() | nil}}` - Normalized response on success
  - `{:error, reason}` - Error tuple with reason on failure

  ## Examples

      iex> llm = fn %{messages: [%{content: _}]} -> {:ok, "result"} end
      iex> PtcRunner.SubAgent.LLMResolver.resolve(llm, %{messages: [%{content: "test"}]}, %{})
      {:ok, %{content: "result", tokens: nil}}

      iex> llm = fn _ -> {:ok, %{content: "result", tokens: %{input: 10, output: 5}}} end
      iex> PtcRunner.SubAgent.LLMResolver.resolve(llm, %{messages: []}, %{})
      {:ok, %{content: "result", tokens: %{input: 10, output: 5}}}

      iex> registry = %{haiku: fn %{messages: _} -> {:ok, "response"} end}
      iex> PtcRunner.SubAgent.LLMResolver.resolve(:haiku, %{messages: [%{content: "test"}]}, registry)
      {:ok, %{content: "response", tokens: nil}}
  """
  @spec resolve(atom() | (map() -> {:ok, term()} | {:error, term()}), map(), map()) ::
          {:ok, normalized_response()} | {:error, term()}
  def resolve(llm, input, _registry) when is_function(llm, 1) do
    case llm.(input) do
      {:ok, response} -> {:ok, normalize_response(response)}
      {:error, _} = error -> error
    end
  end

  def resolve(llm, input, registry) when is_atom(llm) do
    case Map.fetch(registry, llm) do
      {:ok, callback} when is_function(callback, 1) ->
        case callback.(input) do
          {:ok, response} -> {:ok, normalize_response(response)}
          {:error, _} = error -> error
        end

      {:ok, _other} ->
        {:error,
         {:invalid_llm,
          "Registry value for #{inspect(llm)} is not a function/1. Check llm_registry values."}}

      :error when map_size(registry) == 0 ->
        {:error,
         {:llm_registry_required,
          "LLM atom #{inspect(llm)} requires llm_registry option. Pass llm_registry: %{#{llm}: &callback/1} to SubAgent.run/2."}}

      :error ->
        {:error,
         {:llm_not_found,
          "LLM #{inspect(llm)} not found in registry. Available: #{inspect(Map.keys(registry))}"}}
    end
  end

  @doc """
  Normalize an LLM response to a consistent format.

  ## Examples

      iex> PtcRunner.SubAgent.LLMResolver.normalize_response("hello")
      %{content: "hello", tokens: nil}

      iex> PtcRunner.SubAgent.LLMResolver.normalize_response(%{content: "hello"})
      %{content: "hello", tokens: nil}

      iex> PtcRunner.SubAgent.LLMResolver.normalize_response(%{content: "hello", tokens: %{input: 10, output: 5}})
      %{content: "hello", tokens: %{input: 10, output: 5}}
  """
  @spec normalize_response(String.t() | map()) :: normalized_response()
  def normalize_response(response) when is_binary(response) do
    %{content: response, tokens: nil}
  end

  def normalize_response(%{tool_calls: tool_calls} = response) when is_list(tool_calls) do
    %{
      content: Map.get(response, :content),
      tokens: Map.get(response, :tokens),
      tool_calls: tool_calls
    }
  end

  def normalize_response(%{content: content} = response) when is_binary(content) do
    tokens = Map.get(response, :tokens)
    %{content: content, tokens: tokens}
  end

  def normalize_response(%{} = response) do
    %{content: Map.get(response, :content), tokens: Map.get(response, :tokens)}
  end

  @doc """
  Calculate total tokens from input and output token counts.

  ## Examples

      iex> PtcRunner.SubAgent.LLMResolver.total_tokens(%{input: 10, output: 5})
      15

      iex> PtcRunner.SubAgent.LLMResolver.total_tokens(%{input: 0, output: 0})
      0

      iex> PtcRunner.SubAgent.LLMResolver.total_tokens(%{})
      0
  """
  @spec total_tokens(map()) :: non_neg_integer()
  def total_tokens(tokens) when is_map(tokens) do
    Map.get(tokens, :input, 0) + Map.get(tokens, :output, 0)
  end
end
