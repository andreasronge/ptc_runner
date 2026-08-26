defmodule PtcRunner.Kernel.PublicationHandleOwner do
  @moduledoc false

  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction

  alias PtcRunner.Kernel.PublicationHandle

  @spec start(pid()) :: {:ok, pid()} | {:error, term()}
  def start(controller) when is_pid(controller),
    do: GenServer.start(__MODULE__, controller)

  @spec reserve(pid(), binary(), PublicationHandle.kind(), non_neg_integer()) ::
          {:ok, PublicationHandle.t()} | {:error, atom()}
  def reserve(owner, path, kind, mode),
    do: GenServer.call(owner, {:reserve, path, kind, mode}, :infinity)

  @doc false
  @spec reserve_stream(pid(), binary(), :inspection, non_neg_integer()) ::
          {:ok, PublicationHandle.t()} | {:error, atom()}
  def reserve_stream(owner, path, kind, mode),
    do: GenServer.call(owner, {:reserve_stream, path, kind, mode}, :infinity)

  @spec reserve_visible(pid(), binary(), PublicationHandle.kind(), non_neg_integer()) ::
          {:ok, PublicationHandle.t()} | {:error, atom()}
  def reserve_visible(owner, path, kind, mode),
    do: GenServer.call(owner, {:reserve_visible, path, kind, mode}, :infinity)

  @doc false
  @spec reserve_append(pid(), binary(), :trace, non_neg_integer()) ::
          {:ok, PublicationHandle.t()} | {:error, atom()}
  def reserve_append(owner, path, kind, mode),
    do: GenServer.call(owner, {:reserve_append, path, kind, mode}, :infinity)

  @spec call(pid(), term()) :: term()
  def call(owner, operation), do: GenServer.call(owner, {:operation, operation}, :infinity)

  @impl GenServer
  def init(controller) do
    {:ok,
     %{
       controller_ref: Process.monitor(controller),
       handle: nil,
       preserve_on_cleanup?: false,
       removed?: false
     }}
  end

  @impl GenServer
  def handle_call({:reserve, path, kind, mode}, _from, %{handle: nil} = state) do
    case PublicationHandle.reserve_direct(path, kind, mode, self()) do
      {:ok, handle} -> {:reply, {:ok, handle}, %{state | handle: handle}}
      {:error, _reason} = error -> {:stop, :normal, error, state}
    end
  end

  def handle_call({:reserve, _path, _kind, _mode}, _from, state),
    do: {:reply, {:error, :destination_unavailable}, state}

  def handle_call({:reserve_stream, path, :inspection, mode}, _from, %{handle: nil} = state) do
    case PublicationHandle.reserve_direct(path, :inspection, mode, self()) do
      {:ok, handle} -> {:reply, {:ok, handle}, %{state | handle: handle}}
      {:error, _reason} = error -> {:stop, :normal, error, state}
    end
  end

  def handle_call({:reserve_stream, _path, _kind, _mode}, _from, state),
    do: {:reply, {:error, :destination_unavailable}, state}

  def handle_call({:reserve_visible, path, kind, mode}, _from, %{handle: nil} = state) do
    case PublicationHandle.reserve_visible_direct(path, kind, mode, self()) do
      {:ok, handle} -> {:reply, {:ok, handle}, %{state | handle: handle}}
      {:error, _reason} = error -> {:stop, :normal, error, state}
    end
  end

  def handle_call({:reserve_visible, _path, _kind, _mode}, _from, state),
    do: {:reply, {:error, :destination_unavailable}, state}

  def handle_call({:reserve_append, path, :trace, mode}, _from, %{handle: nil} = state) do
    case PublicationHandle.reserve_append_direct(path, :trace, mode, self()) do
      {:ok, handle} -> {:reply, {:ok, handle}, %{state | handle: handle}}
      {:error, _reason} = error -> {:stop, :normal, error, state}
    end
  end

  def handle_call({:reserve_append, _path, _kind, _mode}, _from, state),
    do: {:reply, {:error, :destination_unavailable}, state}

  def handle_call({:operation, operation}, _from, %{handle: handle} = state) do
    operation_reply(operation, handle, state)
  rescue
    _exception -> {:reply, {:error, :publication_failed}, state}
  end

  def handle_call({:operation, _operation}, _from, state),
    do: {:reply, {:error, :publication_cleanup_failed}, state}

  def handle_call(_request, _from, state),
    do: {:reply, {:error, :publication_failed}, state}

  @impl GenServer
  def handle_cast(_message, state), do: {:noreply, state}

  defp operation_reply(:sync_and_retain, %PublicationHandle{kind: :recovery} = handle, state),
    do: sync_and_retain_reply(handle, state, :sync_and_retain)

  defp operation_reply(
         {:sync_and_retain, fault_hook},
         %PublicationHandle{kind: :recovery} = handle,
         state
       )
       when is_nil(fault_hook) or is_function(fault_hook, 1),
       do: sync_and_retain_reply(handle, state, {:sync_and_retain, fault_hook})

  defp operation_reply(:sync_and_retain, _handle, state),
    do: {:reply, {:error, :invalid_destination}, state}

  defp operation_reply(:release, handle, state) do
    case PublicationHandle.owner_execute(handle, :release) do
      :ok -> {:stop, :normal, :ok, %{state | handle: nil}}
      {:error, _reason} = error -> {:stop, :normal, error, %{state | handle: nil}}
    end
  end

  defp operation_reply(:discard, handle, %{preserve_on_cleanup?: true} = state) do
    _ = PublicationHandle.owner_execute(handle, :close)
    {:stop, :normal, :ok, %{state | handle: nil}}
  end

  defp operation_reply(:discard, handle, state) do
    result = PublicationHandle.owner_execute(handle, :remove)
    _ = PublicationHandle.owner_execute(handle, close_after(result))
    {:stop, :normal, result, %{state | handle: nil}}
  end

  defp operation_reply(operation, %PublicationHandle{} = handle, state)
       when operation in [:remove, :unlink] do
    case PublicationHandle.owner_execute(handle, operation) do
      :ok -> {:reply, :ok, %{state | removed?: true}}
      result -> {:reply, result, state}
    end
  end

  defp operation_reply(:close, %PublicationHandle{} = handle, %{removed?: true} = state) do
    _ = PublicationHandle.owner_execute(handle, :close_device)
    {:stop, :normal, :ok, %{state | handle: nil}}
  end

  defp operation_reply(operation, handle, state) do
    case PublicationHandle.owner_execute(handle, operation) do
      {:updated, %PublicationHandle{} = updated_handle} ->
        {:reply, :ok, %{state | handle: updated_handle}}

      :close ->
        {:stop, :normal, :ok, %{state | handle: nil}}

      result ->
        {:reply, result, state}
    end
  end

  defp sync_and_retain_reply(handle, state, operation) do
    case PublicationHandle.owner_execute(handle, operation) do
      :ok ->
        {:reply, :ok, %{state | preserve_on_cleanup?: true}}

      {:preserve, {:error, _reason} = error} ->
        {:reply, error, %{state | preserve_on_cleanup?: true}}

      result ->
        {:reply, result, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _controller, _reason}, %{controller_ref: ref} = state) do
    _ = cleanup(state.handle, state)
    {:stop, :normal, %{state | handle: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{handle: handle} = state), do: cleanup(handle, state)

  defp cleanup(nil, _state), do: :ok

  defp cleanup(handle, %{preserve_on_cleanup?: true}) do
    _ = PublicationHandle.owner_execute(handle, :close)
    :ok
  rescue
    _exception -> :ok
  end

  defp cleanup(handle, %{removed?: true}) do
    _ = PublicationHandle.owner_execute(handle, :close_device)
    :ok
  rescue
    _exception -> :ok
  end

  defp cleanup(handle, _state) do
    result = PublicationHandle.owner_execute(handle, :remove)
    _ = PublicationHandle.owner_execute(handle, close_after(result))
    :ok
  rescue
    _exception -> :ok
  end

  # A successful removal already released the staging and reservation names.
  # Both are derived from the destination and are reserved again by the next
  # handle for that destination, so closing must not identity-check and remove
  # them a second time.
  defp close_after(:ok), do: :close_device
  defp close_after(_result), do: :close
end
