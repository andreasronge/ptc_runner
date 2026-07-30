defmodule PtcRunner.Kernel.MCPOAuth.LocalFences do
  @moduledoc """
  Runtime-shared fail-closed fences for OAuth response transitions.

  Durable store transitions remain authoritative. Each secret-free transition
  has its own `:persistent_term` key, so publishing it is atomic and does not
  depend on a process that can restart between a server response and durable
  persistence. Admission reads one runtime snapshot and conservatively erases
  only fences satisfied by a strictly newer grant. Identities are opaque
  digests; token, principal, and endpoint values are never retained.
  """

  alias PtcRunner.Kernel.MCPOAuth.GrantKey
  alias PtcRunner.Kernel.MCPOAuth.Store

  @persistent_prefix {__MODULE__, :fence}

  @type identity :: binary()
  @type fence ::
          {:rejected_generation, non_neg_integer()}
          | {:scope_requirement, non_neg_integer(), MapSet.t(binary())}

  @spec identity(Store.t(), GrantKey.t()) :: identity()
  def identity(store, %GrantKey{} = key) do
    {Store.local_identity(store), key}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  @spec block(identity(), reference(), fence()) :: :ok
  def block(identity, operation_ref, fence)
      when is_binary(identity) and is_reference(operation_ref) do
    :persistent_term.put(key(identity, operation_ref), fence)
    :ok
  end

  @spec resolve(identity(), reference()) :: :ok
  def resolve(identity, operation_ref)
      when is_binary(identity) and is_reference(operation_ref) do
    :persistent_term.erase(key(identity, operation_ref))
    :ok
  end

  @spec admit(identity(), non_neg_integer(), MapSet.t(binary())) ::
          :ok | {:error, :authorization_required}
  def admit(identity, generation, %MapSet{} = granted_scopes)
      when is_binary(identity) and is_integer(generation) and generation >= 0 do
    remaining =
      for {{@persistent_prefix, ^identity, _operation_ref} = key, fence} <-
            :persistent_term.get(),
          reduce: [] do
        remaining ->
          if satisfied?(fence, generation, granted_scopes) do
            :persistent_term.erase(key)
            remaining
          else
            [key | remaining]
          end
      end

    if remaining == [], do: :ok, else: {:error, :authorization_required}
  end

  defp satisfied?({:rejected_generation, rejected}, generation, _granted),
    do: generation > rejected

  defp satisfied?(
         {:scope_requirement, source_generation, required},
         generation,
         granted
       ),
       do: generation > source_generation and MapSet.subset?(required, granted)

  defp satisfied?(_invalid, _generation, _granted), do: false

  defp key(identity, operation_ref),
    do: {@persistent_prefix, identity, operation_ref}
end
