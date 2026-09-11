defmodule PtcRunner.Kernel.CancelableRequest do
  @moduledoc false

  @enforce_keys [:pid, :monitor, :gate, :owner]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            pid: pid(),
            monitor: reference(),
            gate: reference(),
            owner: pid()
          }

  @spec start_cancelable(function(), map(), map(), pid()) ::
          {:ok, t()} | {:error, :cancellation_witness_unavailable}
  def start_cancelable(requester, request, context, guardian)
      when is_function(requester, 2) and is_map(request) and is_map(context) and
             guardian == self() do
    gate = make_ref()
    owner = self()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          owner_monitor = Process.monitor(owner)

          receive do
            {:dispatch, ^gate} ->
              result = requester.(request, context)
              send(owner, {:cancelable_request_result, gate, result})

            {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
              :ok
          end
        end,
        [:link, :monitor]
      )

    {:ok, %__MODULE__{pid: pid, monitor: monitor, gate: gate, owner: owner}}
  rescue
    _ -> {:error, :cancellation_witness_unavailable}
  catch
    _, _ -> {:error, :cancellation_witness_unavailable}
  end

  def start_cancelable(_requester, _request, _context, _guardian),
    do: {:error, :cancellation_witness_unavailable}

  @spec dispatch(t()) :: :ok | {:error, :cancellation_witness_unavailable}
  def dispatch(%__MODULE__{owner: owner, pid: pid, gate: gate}) when owner == self() do
    send(pid, {:dispatch, gate})
    :ok
  end

  def dispatch(_handle), do: {:error, :cancellation_witness_unavailable}

  @spec await_or_cancel(t(), integer(), reference()) ::
          {:ok, term()} | {:cancelled, :drained | :uncertain} | {:error, atom()}
  def await_or_cancel(
        %__MODULE__{owner: owner, pid: pid, monitor: monitor, gate: gate} = handle,
        deadline,
        admission_monitor
      )
      when owner == self() and is_integer(deadline) and is_reference(admission_monitor) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:cancelable_request_result, ^gate, result} ->
        receive do
          {:DOWN, ^monitor, :process, ^pid, :normal} ->
            {:ok, result}

          {:DOWN, ^monitor, :process, ^pid, _reason} ->
            {:error, :cancellation_witness_unavailable}
        end

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :cancellation_witness_unavailable}

      {:DOWN, ^admission_monitor, :process, _admission, _reason} ->
        _ = cancel_and_drain(handle, deadline)
        {:error, :provider_admission_unavailable}

      {:cancel_provider_call, tracker, request_ref, cleanup_deadline}
      when is_pid(tracker) and is_reference(request_ref) and is_integer(cleanup_deadline) ->
        drained = cancel_and_drain(handle, cleanup_deadline)
        send(tracker, {:provider_call_drained, request_ref, self(), drained})
        {:cancelled, drained}
    after
      timeout -> {:error, :timeout}
    end
  end

  @spec cancel_and_drain(t(), integer()) :: :drained | :uncertain
  def cancel_and_drain(%__MODULE__{owner: owner, pid: pid, monitor: monitor}, deadline)
      when owner == self() and is_integer(deadline) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :drained
    after
      timeout -> :uncertain
    end
  end

  def cancel_and_drain(_handle, _deadline), do: :uncertain
end
