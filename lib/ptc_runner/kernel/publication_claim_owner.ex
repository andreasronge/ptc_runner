defmodule PtcRunner.Kernel.PublicationClaimOwner do
  @moduledoc false

  use GenServer

  @type lease :: {pid(), reference()}

  alias PtcRunner.Kernel.PublicationHandle

  @spec start(:atomics.atomics_ref()) :: {:ok, pid()} | {:error, term()}
  def start(lifecycle), do: start(lifecycle, self())

  @doc false
  @spec start(:atomics.atomics_ref(), pid()) :: {:ok, pid()} | {:error, term()}
  def start(lifecycle, creator) when is_pid(creator),
    do: GenServer.start(__MODULE__, {lifecycle, creator})

  @spec claim(pid()) :: {:ok, lease()} | {:error, :already_claimed | :terminal}
  def claim(owner), do: GenServer.call(owner, {:claim, self()}, :infinity)

  @spec valid?(pid(), lease()) :: boolean()
  def valid?(owner, lease), do: GenServer.call(owner, {:valid, lease}, :infinity)

  @spec claimed?(pid()) :: boolean()
  def claimed?(owner), do: GenServer.call(owner, :claimed?, :infinity)

  @spec terminalize(pid()) :: :ok | {:error, :publication_cleanup_failed}
  def terminalize(owner), do: GenServer.call(owner, :terminalize, :infinity)

  @spec register(pid(), PublicationHandle.t()) :: :ok | {:error, :terminal}
  def register(owner, %PublicationHandle{} = handle),
    do: GenServer.call(owner, {:register, handle}, :infinity)

  @doc false
  @spec unregister(pid(), PublicationHandle.t()) :: :ok | {:error, :terminal}
  def unregister(owner, %PublicationHandle{} = handle),
    do: GenServer.call(owner, {:unregister, PublicationHandle.identity(handle)}, :infinity)

  @impl GenServer
  def init({lifecycle, creator}) do
    {:ok,
     %{
       lifecycle: lifecycle,
       creator: creator,
       creator_ref: Process.monitor(creator),
       claimant: nil,
       claimant_ref: nil,
       handles: %{}
     }}
  end

  @impl GenServer
  def handle_call({:claim, claimant}, _from, %{claimant: nil} = state) do
    token = make_ref()

    if state.creator_ref, do: Process.demonitor(state.creator_ref, [:flush])

    ref = Process.monitor(claimant)
    :atomics.put(state.lifecycle, 1, 1)

    {:reply, {:ok, {claimant, token}},
     %{
       state
       | creator: nil,
         creator_ref: nil,
         claimant: {claimant, token},
         claimant_ref: ref
     }}
  end

  def handle_call({:claim, _new_claimant}, _from, %{claimant: _claimed} = state),
    do: {:reply, {:error, :already_claimed}, state}

  def handle_call({:register, %PublicationHandle{} = handle}, _from, state) do
    if :atomics.get(state.lifecycle, 1) == 0 do
      key = PublicationHandle.identity(handle)
      {:reply, :ok, %{state | handles: Map.put(state.handles, key, handle)}}
    else
      {:reply, {:error, :terminal}, state}
    end
  end

  def handle_call({:unregister, identity}, _from, state) do
    if :atomics.get(state.lifecycle, 1) in [0, 1] do
      {:reply, :ok, %{state | handles: Map.delete(state.handles, identity)}}
    else
      {:reply, {:error, :terminal}, state}
    end
  end

  def handle_call({:valid, {claimant, token}}, _from, %{claimant: {claimant, token}} = state)
      when is_pid(claimant) and is_reference(token),
      do: {:reply, :atomics.get(state.lifecycle, 1) == 1, state}

  def handle_call({:valid, _lease}, _from, state), do: {:reply, false, state}

  def handle_call(:claimed?, _from, state),
    do: {:reply, state.claimant != nil and :atomics.get(state.lifecycle, 1) == 1, state}

  def handle_call(:terminalize, _from, state) do
    :atomics.put(state.lifecycle, 1, 2)
    result = cleanup_handles(state.handles)
    {:stop, :normal, result, %{state | handles: %{}}}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _claimant, _reason}, %{claimant_ref: ref} = state) do
    :atomics.put(state.lifecycle, 1, 2)
    cleanup_handles(state.handles)
    {:stop, :normal, %{state | claimant: nil, claimant_ref: nil, handles: %{}}}
  end

  def handle_info({:DOWN, ref, :process, _creator, _reason}, %{creator_ref: ref} = state) do
    :atomics.put(state.lifecycle, 1, 2)
    cleanup_handles(state.handles)
    {:stop, :normal, %{state | creator: nil, creator_ref: nil, handles: %{}}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state), do: cleanup_handles(state.handles)

  defp cleanup_handles(handles) do
    results =
      Enum.map(handles, fn {_identity, handle} ->
        result = PublicationHandle.discard(handle)
        _ = PublicationHandle.close(handle)
        result
      end)

    if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, :publication_cleanup_failed}
  end
end
