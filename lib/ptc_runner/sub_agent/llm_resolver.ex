defmodule PtcRunner.SubAgent.LLMResolver do
  @moduledoc """
  LLM resolution and invocation for SubAgents.

  Handles calling LLMs that can be either functions or atoms, with support for
  LLM registry lookups for atom-based LLM references (like `:haiku` or `:sonnet`).
  """

  @doc """
  Resolve and invoke an LLM, handling both functions and atom references.

  ## Parameters

  - `llm` - Either a function/1 or an atom referencing the registry
  - `input` - The LLM input map to pass to the callback
  - `registry` - Map of atom to LLM callback for atom-based LLM references

  ## Returns

  - `{:ok, response}` - LLM response string on success
  - `{:error, reason}` - Error tuple with reason on failure

  ## Examples

      iex> llm = fn %{messages: [%{content: _}]} -> {:ok, "result"} end
      iex> PtcRunner.SubAgent.LLMResolver.resolve(llm, %{messages: [%{content: "test"}]}, %{})
      {:ok, "result"}

      iex> registry = %{haiku: fn %{messages: _} -> {:ok, "response"} end}
      iex> PtcRunner.SubAgent.LLMResolver.resolve(:haiku, %{messages: [%{content: "test"}]}, registry)
      {:ok, "response"}
  """
  @spec resolve(atom() | (map() -> {:ok, String.t()} | {:error, term()}), map(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve(llm, input, _registry) when is_function(llm, 1) do
    llm.(input)
  end

  def resolve(llm, input, registry) when is_atom(llm) do
    case Map.fetch(registry, llm) do
      {:ok, callback} when is_function(callback, 1) ->
        callback.(input)

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
end
