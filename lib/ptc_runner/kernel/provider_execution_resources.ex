defmodule PtcRunner.Kernel.ProviderExecutionResources do
  @moduledoc false

  alias PtcRunner.Kernel.MCPOAuth.LoopbackListener
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession

  @type action :: :put | :drop
  @type kind :: :session | :registry | :memory | :listener

  @doc false
  @spec update(map(), action(), kind(), term(), pid(), atom()) ::
          {:ok, map()} | {:error, atom()}
  def update(state, :put, kind, resource, lifecycle_owner, unavailable)
      when is_map(state) and is_pid(lifecycle_owner) and is_atom(unavailable) do
    field = field(kind)

    if is_nil(Map.fetch!(state, field)) and valid?(kind, resource, lifecycle_owner),
      do: {:ok, Map.put(state, field, resource)},
      else: {:error, unavailable}
  end

  def update(state, :drop, kind, resource, _lifecycle_owner, unavailable)
      when is_map(state) and is_atom(unavailable) do
    field = field(kind)

    if Map.fetch!(state, field) === resource,
      do: {:ok, Map.put(state, field, nil)},
      else: {:error, unavailable}
  end

  defp field(:session), do: :provider_session
  defp field(:registry), do: :registry
  defp field(:memory), do: :oauth_memory
  defp field(:listener), do: :oauth_listener

  defp valid?(:session, session, lifecycle_owner),
    do:
      ProviderSession.valid?(session) and
        ProviderSession.lifecycle_owner(session) == lifecycle_owner

  defp valid?(:registry, registry, _owner), do: ProviderRegistry.valid?(registry)
  defp valid?(:memory, %Memory{pid: pid}, _owner), do: is_pid(pid) and Process.alive?(pid)
  defp valid?(:listener, %LoopbackListener{}, _owner), do: true
  defp valid?(_kind, _resource, _owner), do: false
end
