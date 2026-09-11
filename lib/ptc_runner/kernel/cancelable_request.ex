defmodule PtcRunner.Kernel.CancelableRequest do
  @moduledoc false

  alias PtcRunner.Kernel.AdapterCancellationWitness

  @enforce_keys [:pid, :monitor, :gate, :owner, :dispatched]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            pid: pid(),
            monitor: reference(),
            gate: reference(),
            owner: pid(),
            dispatched: reference()
          }

  @spec start_cancelable(function(), map(), map(), pid()) ::
          {:ok, t()} | {:error, :cancellation_witness_unavailable}
  def start_cancelable(requester, request, context, guardian)
      when is_function(requester, 2) and is_map(request) and is_map(context) and
             guardian == self() do
    gate = make_ref()
    dispatched = :atomics.new(1, signed: false)
    owner = self()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          owner_monitor = Process.monitor(owner)

          receive do
            {:dispatch, ^gate} ->
              :ok = AdapterCancellationWitness.install(owner, gate)
              result = invoke_requester(requester, request, context)
              send(owner, {:cancelable_request_result, gate, result})

            {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
              :ok
          end
        end,
        [:link, :monitor]
      )

    {:ok,
     %__MODULE__{
       pid: pid,
       monitor: monitor,
       gate: gate,
       owner: owner,
       dispatched: dispatched
     }}
  rescue
    _ -> {:error, :cancellation_witness_unavailable}
  catch
    _, _ -> {:error, :cancellation_witness_unavailable}
  end

  def start_cancelable(_requester, _request, _context, _guardian),
    do: {:error, :cancellation_witness_unavailable}

  @spec dispatch(t()) :: :ok | {:error, :cancellation_witness_unavailable}
  def dispatch(%__MODULE__{owner: owner, pid: pid, gate: gate, dispatched: dispatched})
      when owner == self() do
    if :atomics.compare_exchange(dispatched, 1, 0, 1) == :ok do
      send(pid, {:dispatch, gate})
      :ok
    else
      {:error, :cancellation_witness_unavailable}
    end
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
            normalize_result(result)

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
  def cancel_and_drain(
        %__MODULE__{
          owner: owner,
          pid: pid,
          monitor: monitor,
          gate: gate,
          dispatched: dispatched
        },
        deadline
      )
      when owner == self() and is_integer(deadline) do
    Process.unlink(pid)

    if :atomics.get(dispatched, 1) == 0 do
      Process.exit(pid, :kill)
      await_down(pid, monitor, deadline)
    else
      send(pid, {:cancel_adapter_request, gate, owner})
      await_adapter_drain(pid, monitor, gate, deadline, false)
    end
  end

  def cancel_and_drain(_handle, _deadline), do: :uncertain

  defp await_adapter_drain(pid, monitor, gate, deadline, acknowledged?) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:adapter_request_drained, ^gate, ^pid} ->
        await_adapter_drain(pid, monitor, gate, deadline, true)

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        if acknowledged?, do: :drained, else: :uncertain
    after
      timeout -> :uncertain
    end
  end

  defp await_down(pid, monitor, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :drained
    after
      timeout -> :uncertain
    end
  end

  defp invoke_requester(requester, request, context) do
    {:ok, requester.(request, context)}
  rescue
    _exception -> :requester_failed
  catch
    _kind, _reason -> :requester_failed
  end

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result(:requester_failed), do: {:error, :cancellation_witness_unavailable}
end
