defmodule PtcRunner.Kernel.StateHandle do
  @moduledoc false

  use GenServer

  alias PtcRunner.Lisp.RetainedSize

  @enforce_keys [:pid, :token]
  defstruct [:pid, :token]

  @type t :: %__MODULE__{pid: pid(), token: reference()}

  @spec start(keyword()) :: {:ok, t()} | {:error, term()}
  def start(opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    memory = Keyword.get(opts, :memory, %{})
    byte_cap = Keyword.fetch!(opts, :byte_cap)
    token = make_ref()

    with {:ok, pid} <- GenServer.start(__MODULE__, {owner, token, memory, byte_cap}) do
      {:ok, %__MODULE__{pid: pid, token: token}}
    end
  end

  @type lease :: reference()

  @spec checkout(t()) :: {:ok, map(), lease()} | {:busy, map()} | {:error, :stale_handle}
  def checkout(handle), do: call(handle, :checkout)

  @spec checkin(t(), lease(), map()) ::
          :ok | {:error, :memory_limit_exceeded | :stale_handle | :stale_lease}
  def checkin(handle, lease, memory) when is_reference(lease) and is_map(memory),
    do: call(handle, {:checkin, lease, memory})

  @spec release(t(), lease()) :: :ok | {:error, :stale_handle | :stale_lease}
  def release(handle, lease) when is_reference(lease), do: call(handle, {:release, lease})

  @spec projection(t()) :: {:ok, map()} | {:error, :stale_handle}
  def projection(handle), do: call(handle, :projection)

  @spec stop(t()) :: :ok
  def stop(%__MODULE__{} = handle) do
    case call(handle, :stop) do
      :ok -> :ok
      {:error, :stale_handle} -> :ok
    end
  end

  @impl GenServer
  def init({owner, token, memory, byte_cap}) do
    {:ok,
     %{
       owner_ref: Process.monitor(owner),
       token: token,
       memory: memory,
       byte_cap: byte_cap,
       lease: nil
     }}
  end

  @impl GenServer
  def handle_call({token, :checkout}, {caller, _tag}, %{token: token, lease: nil} = state) do
    lease = make_ref()
    holder_ref = Process.monitor(caller)
    {:reply, {:ok, state.memory, lease}, %{state | lease: {lease, caller, holder_ref}}}
  end

  def handle_call({token, :checkout}, _from, %{token: token} = state),
    do: {:reply, {:busy, state.memory}, state}

  def handle_call(
        {token, {:checkin, lease, memory}},
        {caller, _tag},
        %{token: token, lease: {lease, caller, holder_ref}} = state
      ) do
    case RetainedSize.bytes_with_cap(memory, state.byte_cap) do
      bytes when is_integer(bytes) and bytes <= state.byte_cap ->
        Process.demonitor(holder_ref, [:flush])
        {:reply, :ok, %{state | memory: memory, lease: nil}}

      _oversized ->
        Process.demonitor(holder_ref, [:flush])
        {:reply, {:error, :memory_limit_exceeded}, %{state | lease: nil}}
    end
  end

  def handle_call({token, {:checkin, _lease, _memory}}, _from, %{token: token} = state),
    do: {:reply, {:error, :stale_lease}, state}

  def handle_call(
        {token, {:release, lease}},
        {caller, _tag},
        %{token: token, lease: {lease, caller, holder_ref}} = state
      ) do
    Process.demonitor(holder_ref, [:flush])
    {:reply, :ok, %{state | lease: nil}}
  end

  def handle_call({token, {:release, _lease}}, _from, %{token: token} = state),
    do: {:reply, {:error, :stale_lease}, state}

  def handle_call({token, :projection}, _from, %{token: token} = state) do
    projection = %{
      defined_count: map_size(state.memory),
      memory_bytes: RetainedSize.bytes_with_cap(state.memory, state.byte_cap),
      busy: not is_nil(state.lease)
    }

    {:reply, {:ok, projection}, state}
  end

  def handle_call({token, :stop}, _from, %{token: token} = state),
    do: {:stop, :normal, :ok, state}

  def handle_call({_wrong_token, _operation}, _from, state),
    do: {:reply, {:error, :stale_handle}, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{lease: {_lease, _holder, ref}} = state
      ),
      do: {:noreply, %{state | lease: nil}}

  defp call(%__MODULE__{pid: pid, token: token}, operation) do
    GenServer.call(pid, {token, operation})
  catch
    :exit, {:noproc, _details} -> {:error, :stale_handle}
    :exit, {:normal, _details} -> {:error, :stale_handle}
  end
end
