defmodule PtcRunner.Kernel.ProviderRuntimeOpening do
  @moduledoc false
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.MCPOAuth.LoopbackListener
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderExecutionResources
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession

  @spec open(PreparedRun.t(), ProviderExecution.t(), Deadline.t()) ::
          {:ok, ProviderExecution.Opened.t()} | {:error, term()}
  def open(prepared, execution, deadline) do
    # Only the opening owner calls the tracker. Its private table keeps resources
    # available for synchronous cleanup even if the active pipeline raises.
    table = :ets.new(__MODULE__, [:set, :private])

    :ets.insert(
      table,
      {:resources,
       %{provider_session: nil, registry: nil, oauth_memory: nil, oauth_listener: nil}}
    )

    owner = self()

    tracker = fn action, kind, resource ->
      state = :ets.lookup_element(table, :resources, 2)

      case ProviderExecutionResources.update(
             state,
             action,
             kind,
             resource,
             owner,
             :provider_runtime_lost
           ) do
        {:ok, next} ->
          :ets.insert(table, {:resources, next})
          :ok

        {:error, _reason} = error ->
          error
      end
    end

    try do
      result = invoke(prepared, execution, tracker, owner, deadline)
      settle(result, :ets.lookup_element(table, :resources, 2))
    after
      :ets.delete(table)
    end
  end

  defp invoke(prepared, execution, tracker, owner, deadline) do
    ProviderExecution.open_serving(prepared, execution, tracker, owner, deadline)
  rescue
    _exception -> {:error, :invalid_provider_runtime}
  catch
    _kind, _reason -> {:error, :invalid_provider_runtime}
  end

  defp settle({:ok, _opened} = result, resources) do
    close_temporary(resources)
    result
  end

  defp settle(result, resources) do
    cleanup =
      if resources.provider_session,
        do: ProviderSession.close(resources.provider_session),
        else: :ok

    if resources.registry, do: ProviderRegistry.close(resources.registry)
    close_temporary(resources)
    if cleanup == :ok, do: result, else: {:error, :provider_cleanup_failed}
  end

  defp close_temporary(resources) do
    if resources.oauth_listener, do: LoopbackListener.close(resources.oauth_listener)
    if resources.oauth_memory, do: Memory.close(resources.oauth_memory)
  end
end
