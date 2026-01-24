defmodule PtcRunner.SubAgent.Chaining do
  @moduledoc """
  Chaining functions for SubAgent pipelines.

  Provides `then!/3` and `then/3` for composing SubAgent executions,
  where each agent receives the previous agent's return value as context.

  ## Usage

  These functions are re-exported from `PtcRunner.SubAgent` for convenience:

      SubAgent.run!(agent1, llm: llm, context: %{x: 1})
      |> SubAgent.then!(agent2, llm: llm)
      |> SubAgent.then!(agent3, llm: llm)

  Or with error handling:

      SubAgent.run(agent1, llm: llm, context: %{x: 1})
      |> SubAgent.then(agent2, llm: llm)
      |> SubAgent.then(agent3, llm: llm)
  """

  alias PtcRunner.Step
  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.CompiledAgent
  alias PtcRunner.SubAgent.PromptExpander

  @doc """
  Chains agents in a pipeline, passing the previous step as context.

  Equivalent to `run!(agent, Keyword.put(opts, :context, step))`. Enables
  pipeline-style composition where each agent receives the previous agent's
  `return` value as input.

  ## Examples

      iex> doubler = PtcRunner.SubAgent.new(
      ...>   prompt: "Double {{n}}",
      ...>   signature: "(n :int) -> {result :int}",
      ...>   max_turns: 1
      ...> )
      iex> adder = PtcRunner.SubAgent.new(
      ...>   prompt: "Add 10 to {{result}}",
      ...>   signature: "(result :int) -> {final :int}",
      ...>   max_turns: 1
      ...> )
      iex> mock_llm = fn %{messages: msgs} ->
      ...>   content = msgs |> List.last() |> Map.get(:content)
      ...>   cond do
      ...>     content =~ "Double" -> {:ok, "```clojure\\n{:result (* 2 data/n)}\\n```"}
      ...>     content =~ "Add 10" -> {:ok, "```clojure\\n{:final (+ data/result 10)}\\n```"}
      ...>   end
      ...> end
      iex> result = PtcRunner.SubAgent.run!(doubler, llm: mock_llm, context: %{n: 5})
      ...> |> PtcRunner.SubAgent.then!(adder, llm: mock_llm)
      iex> result.return["final"]
      20

  """
  @spec then!(Step.t(), SubAgent.t() | CompiledAgent.t() | String.t(), keyword()) :: Step.t()
  def then!(step, agent, opts \\ []) do
    validate_chain_keys!(step, agent)
    SubAgent.run!(agent, Keyword.put(opts, :context, step))
  end

  @doc """
  Chains SubAgent/CompiledAgent executions with error propagation.

  Unlike `then!/3`, this returns `{:ok, Step}` or `{:error, Step}`
  instead of raising on chain validation failures.

  ## Examples

      SubAgent.run(agent1, llm: llm, context: %{x: 1})
      |> SubAgent.then(agent2, llm: llm)
      |> SubAgent.then(compiled)  # No LLM needed if pure

  """
  @spec then(
          {:ok, Step.t()} | {:error, Step.t()},
          SubAgent.t() | CompiledAgent.t() | String.t(),
          keyword()
        ) ::
          {:ok, Step.t()} | {:error, Step.t()}
  def then(result, agent, opts \\ [])

  def then({:error, step}, _agent, _opts), do: {:error, step}

  def then({:ok, step}, agent, opts) do
    validate_chain_keys!(step, agent)
    SubAgent.run(agent, Keyword.put(opts, :context, step))
  rescue
    e in ArgumentError -> {:error, Step.error(:chain_error, Exception.message(e), %{})}
  end

  # Validates that step output keys satisfy the next agent's signature requirements.
  defp validate_chain_keys!(%Step{}, %SubAgent{signature: nil}), do: :ok
  defp validate_chain_keys!(%Step{fail: fail}, _agent) when fail != nil, do: :ok

  defp validate_chain_keys!(%Step{return: return}, %SubAgent{signature: sig}) do
    do_validate_chain_keys!(return, sig)
  end

  # CompiledAgent validation
  defp validate_chain_keys!(%Step{}, %CompiledAgent{signature: nil}), do: :ok

  defp validate_chain_keys!(%Step{fail: fail}, %CompiledAgent{})
       when fail != nil,
       do: :ok

  defp validate_chain_keys!(%Step{return: return}, %CompiledAgent{signature: sig}) do
    do_validate_chain_keys!(return, sig)
  end

  # Shared validation logic for both SubAgent and CompiledAgent
  defp do_validate_chain_keys!(return, sig) do
    required_keys = PromptExpander.extract_signature_params(sig)

    # Handle non-map return values (no keys available)
    provided_keys =
      case return do
        map when is_map(map) -> map |> Map.keys() |> Enum.map(&to_string/1)
        _ -> []
      end

    missing = required_keys -- provided_keys

    if missing != [] do
      raise ArgumentError,
            "Chain mismatch: agent requires #{inspect(Enum.sort(missing))} but previous step doesn't output them"
    end

    :ok
  end
end
