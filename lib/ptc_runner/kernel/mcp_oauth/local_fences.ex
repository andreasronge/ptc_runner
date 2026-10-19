defmodule PtcRunner.Kernel.MCPOAuth.LocalFences do
  @moduledoc """
  Store-owned fail-closed fences for OAuth response transitions.

  Fences survive manager replacement and failed persistence retries, but die
  with the backing store. Operations are serialized by the store owner and
  admission examines only one grant's fences. Durable transitions remain
  authoritative; only strictly newer satisfying grants retire local fences.
  Fence keys are opaque digests and values contain no credentials.
  """

  alias PtcRunner.Kernel.MCPOAuth.GrantKey
  alias PtcRunner.Kernel.MCPOAuth.Store

  @type identity :: {Store.t(), binary()}
  @type fence ::
          {:rejected_generation, non_neg_integer()}
          | {:scope_requirement, non_neg_integer(), MapSet.t(binary())}

  @spec identity(Store.t(), GrantKey.t()) :: identity()
  def identity(store, %GrantKey{} = key) do
    digest =
      {Store.local_identity(store), key}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))

    {store, digest}
  end

  @spec block(identity(), reference(), fence()) :: :ok
  def block({store, identity}, operation_ref, fence) when is_reference(operation_ref),
    do: Store.local_fence(store, {:block, identity, operation_ref, fence})

  @spec resolve(identity(), reference()) :: :ok
  def resolve({store, identity}, operation_ref) when is_reference(operation_ref),
    do: Store.local_fence(store, {:resolve, identity, operation_ref})

  @spec admit(identity(), non_neg_integer(), MapSet.t(binary())) ::
          :ok | {:error, :authorization_required}
  def admit({store, identity}, generation, %MapSet{} = scopes),
    do: Store.local_fence(store, {:admit, identity, generation, scopes})

  @doc false
  @spec transition(map(), tuple()) :: {term(), map()}
  def transition(fences, {:block, identity, ref, fence}) do
    {:ok, Map.update(fences, identity, %{ref => fence}, &Map.put(&1, ref, fence))}
  end

  def transition(fences, {:resolve, identity, ref}) do
    remaining = Map.delete(Map.get(fences, identity, %{}), ref)
    {:ok, retain(fences, identity, remaining)}
  end

  def transition(fences, {:admit, identity, generation, scopes}) do
    remaining =
      Map.reject(Map.get(fences, identity, %{}), fn {_ref, fence} ->
        satisfied?(fence, generation, scopes)
      end)

    result = if map_size(remaining) == 0, do: :ok, else: {:error, :authorization_required}
    {result, retain(fences, identity, remaining)}
  end

  defp retain(fences, identity, remaining) when map_size(remaining) == 0,
    do: Map.delete(fences, identity)

  defp retain(fences, identity, remaining), do: Map.put(fences, identity, remaining)

  defp satisfied?({:rejected_generation, rejected}, generation, _granted),
    do: generation > rejected

  defp satisfied?(
         {:scope_requirement, source_generation, required},
         generation,
         granted
       ),
       do: generation > source_generation and MapSet.subset?(required, granted)

  defp satisfied?(_invalid, _generation, _granted), do: false
end
