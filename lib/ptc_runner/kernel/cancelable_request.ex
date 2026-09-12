defmodule PtcRunner.Kernel.CancelableRequest do
  @moduledoc false

  alias PtcRunner.Kernel.AdapterCancellationWitness

  @enforce_keys [:pid, :monitor, :gate, :owner, :state]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            pid: pid(),
            monitor: reference(),
            gate: reference(),
            owner: pid(),
            state: :atomics.atomics_ref()
          }

  @spec start_cancelable(function(), map(), map(), pid()) ::
          {:ok, t()} | {:error, :cancellation_witness_unavailable}
  def start_cancelable(requester, request, context, guardian)
      when is_function(requester, 2) and is_map(request) and is_map(context) and
             guardian == self() do
    gate = make_ref()
    state = :atomics.new(1, signed: false)
    owner = self()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          owner_monitor = Process.monitor(owner)

          receive do
            {:dispatch, ^gate} ->
              :ok = AdapterCancellationWitness.install(owner, gate, state)
              result = invoke_requester(requester, request, context)
              :atomics.put(state, 1, 3)
              send(owner, {:cancelable_request_result, gate, result})

            {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
              :ok
          end
        end,
        provider_spawn_options()
      )

    {:ok,
     %__MODULE__{
       pid: pid,
       monitor: monitor,
       gate: gate,
       owner: owner,
       state: state
     }}
  rescue
    _ -> {:error, :cancellation_witness_unavailable}
  catch
    _, _ -> {:error, :cancellation_witness_unavailable}
  end

  def start_cancelable(_requester, _request, _context, _guardian),
    do: {:error, :cancellation_witness_unavailable}

  @spec dispatch(t()) :: :ok | {:error, :cancellation_witness_unavailable}
  def dispatch(%__MODULE__{owner: owner, pid: pid, gate: gate, state: state})
      when owner == self() do
    if :atomics.compare_exchange(state, 1, 0, 1) == :ok do
      send(pid, {:dispatch, gate})
      :ok
    else
      {:error, :cancellation_witness_unavailable}
    end
  end

  def dispatch(_handle), do: {:error, :cancellation_witness_unavailable}

  @spec await_or_cancel(t(), integer(), reference(), integer()) ::
          {:ok, term()} | {:cancelled, :drained | :uncertain} | {:error, atom()}
  def await_or_cancel(
        %__MODULE__{owner: owner, pid: pid, monitor: monitor, gate: gate} = handle,
        deadline,
        admission_monitor,
        cleanup_timeout_ms
      )
      when owner == self() and is_integer(deadline) and is_reference(admission_monitor) and
             is_integer(cleanup_timeout_ms) and cleanup_timeout_ms > 0 do
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
        cleanup_deadline = System.monotonic_time(:millisecond) + cleanup_timeout_ms
        _ = cancel_and_drain(handle, cleanup_deadline)
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
          state: state
        },
        deadline
      )
      when owner == self() and is_integer(deadline) do
    Process.unlink(pid)

    case :atomics.compare_exchange(state, 1, 1, 4) do
      2 ->
        send(pid, {:cancel_adapter_request, gate, owner})
        await_adapter_drain(pid, monitor, gate, state, deadline, false)

      _cancellation_claimed_or_request_finished ->
        Process.exit(pid, :kill)
        await_down(pid, monitor, deadline)
    end
  end

  def cancel_and_drain(_handle, _deadline), do: :uncertain

  defp await_adapter_drain(pid, monitor, gate, state, deadline, acknowledged?) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:adapter_request_drained, ^gate, ^pid} ->
        await_adapter_drain(pid, monitor, gate, state, deadline, true)

      {:DOWN, ^monitor, :process, ^pid, :normal} ->
        if acknowledged? or :atomics.get(state, 1) == 3, do: :drained, else: :uncertain

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :uncertain
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
    exception -> {__MODULE__, :raised, exception, __STACKTRACE__}
  catch
    kind, reason -> {__MODULE__, :caught, kind, reason}
  end

  defp normalize_result({:ok, result}), do: {:ok, result}

  defp normalize_result({__MODULE__, :raised, _exception, _stacktrace} = failure),
    do: {:ok, failure}

  defp normalize_result({__MODULE__, :caught, _kind, _reason} = failure),
    do: {:ok, failure}

  defp provider_spawn_options do
    max_heap_size = Process.info(self(), :max_heap_size) |> elem(1)
    [:link, :monitor, {:max_heap_size, max_heap_size}]
  end
end
