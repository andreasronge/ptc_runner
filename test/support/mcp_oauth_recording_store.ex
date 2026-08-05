defmodule PtcRunner.Test.MCPOAuthRecordingStore do
  @moduledoc false

  alias PtcRunner.Kernel.MCPOAuth.Store

  @behaviour Store

  @spec wrap(Store.t(), pid(), keyword()) :: {:ok, Store.t()} | {:error, :invalid_store}
  def wrap({module, adapter_state}, observer, opts \\ [])
      when is_atom(module) and is_pid(observer) and is_list(opts) do
    Store.new(__MODULE__, %{
      delegate: {module, adapter_state},
      observer: observer,
      expire_callback?: Keyword.get(opts, :expire_callback?, false),
      interceptor: Keyword.get(opts, :interceptor, fn _operation, _deadline -> :delegate end)
    })
  end

  @impl Store
  def transact(state, operation, deadline) do
    result =
      case state.interceptor.(operation, deadline) do
        :delegate ->
          {module, adapter_state} = state.delegate
          module.transact(adapter_state, operation, deadline)

        {:return, result} ->
          result
      end

    record_anchor(state.observer, operation, result)
    maybe_expire_callback(result, operation, state.expire_callback?)
  end

  @impl Store
  def local_identity(state), do: Store.local_identity(state.delegate)

  @impl Store
  def register_manager(state, manager), do: Store.register_manager(state.delegate, manager)

  defp record_anchor(observer, {:time_anchor}, {:ok, anchor}),
    do: send(observer, {:oauth_sequence, {:time_anchor, anchor}})

  defp record_anchor(observer, {:begin_flow, _key, %{binding: binding}, _ttl_ms}, _result),
    do: send_anchor(observer, :begin_flow, binding)

  defp record_anchor(
         observer,
         {:begin_code_dispatch, _key, _flow_id, _fence, binding},
         _result
       ),
       do: send_anchor(observer, :begin_code_dispatch, binding)

  defp record_anchor(
         observer,
         {:begin_mutation_dispatch, _key, _fence, binding},
         _result
       ),
       do: send_anchor(observer, :begin_mutation_dispatch, binding)

  defp record_anchor(_observer, _operation, _result), do: :ok

  defp send_anchor(observer, operation, binding) do
    send(
      observer,
      {:oauth_sequence, {operation, Map.get(binding, :freshness_anchor)}}
    )
  end

  defp maybe_expire_callback(
         {:ok, flow},
         {:consume_callback, _key, _flow_id, _state, _issuer},
         true
       ) do
    {:ok, Map.put(flow, :binding_freshness_remaining_ms, 0)}
  end

  defp maybe_expire_callback(result, _operation, _expire_callback?), do: result
end
