defmodule PtcRunner.Kernel.ProviderCallOwner do
  @moduledoc false

  alias PtcRunner.Kernel.CancelableRequest
  alias PtcRunner.Kernel.ProviderCallAdmission
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunState

  @capacity_text "LLM provider call capacity exhausted"
  @unavailable_text "LLM provider admission unavailable"
  @timeout_text "LLM provider admission deadline elapsed"

  @spec run(ProviderCallAdmission.t(), function(), map(), map()) ::
          {:ok, map()} | {:error, ProviderError.t()}
  def run(admission, requester, request, %{llm_request_deadline_ms: deadline} = context)
      when is_function(requester, 2) and is_map(request) and
             is_integer(deadline) do
    admission_monitor = monitor_admission(admission)

    try do
      requester_context = Map.take(context, [:llm_request_deadline_ms])

      case CancelableRequest.start_cancelable(requester, request, requester_context, self()) do
        {:ok, handle} ->
          checkout(admission, handle, deadline, context, admission_monitor)

        {:error, :cancellation_witness_unavailable} ->
          refusal(:admission_unavailable, @unavailable_text, false)
      end
    after
      Process.demonitor(admission_monitor, [:flush])
    end
  end

  def run(_admission, _requester, _request, _context),
    do: refusal(:admission_unavailable, @unavailable_text, false)

  @spec checkout(
          ProviderCallAdmission.t(),
          CancelableRequest.t(),
          integer(),
          map(),
          reference()
        ) :: {:ok, map()} | {:error, ProviderError.t()}
  defp checkout(admission, handle, deadline, context, admission_monitor) do
    guardian = self()

    {checkout_pid, checkout_monitor} =
      spawn_monitor(fn ->
        result = ProviderCallAdmission.checkout_for(admission, guardian, deadline)
        send(guardian, {:provider_admission_checkout, self(), result})
      end)

    await_checkout(
      admission,
      handle,
      deadline,
      context,
      admission_monitor,
      checkout_pid,
      checkout_monitor
    )
  end

  defp await_checkout(
         admission,
         handle,
         deadline,
         context,
         admission_monitor,
         checkout_pid,
         checkout_monitor
       ) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:provider_admission_checkout, ^checkout_pid, {:ok, lease}} ->
        Process.demonitor(checkout_monitor, [:flush])
        granted(admission, lease, handle, deadline, context, admission_monitor)

      {:provider_admission_checkout, ^checkout_pid, {:error, reason}} ->
        Process.demonitor(checkout_monitor, [:flush])
        _ = CancelableRequest.cancel_and_drain(handle, cleanup_deadline(context))
        checkout_refusal(reason)

      {:cancel_provider_call, tracker, request_ref, cleanup_deadline}
      when is_pid(tracker) and is_reference(request_ref) and is_integer(cleanup_deadline) ->
        Process.exit(checkout_pid, :kill)
        await_checkout_down(checkout_pid, checkout_monitor)
        drained = CancelableRequest.cancel_and_drain(handle, cleanup_deadline)
        send(tracker, {:provider_call_drained, request_ref, self(), drained})
        checkout_cancelled(drained, context)

      {:DOWN, ^admission_monitor, :process, _admission, _reason} ->
        Process.exit(checkout_pid, :kill)
        await_checkout_down(checkout_pid, checkout_monitor)
        _ = CancelableRequest.cancel_and_drain(handle, cleanup_deadline(context))
        checkout_refusal(:provider_admission_unavailable)

      {:DOWN, ^checkout_monitor, :process, ^checkout_pid, _reason} ->
        _ = CancelableRequest.cancel_and_drain(handle, cleanup_deadline(context))
        checkout_refusal(:provider_admission_unavailable)
    after
      timeout ->
        Process.exit(checkout_pid, :kill)
        await_checkout_down(checkout_pid, checkout_monitor)
        _ = CancelableRequest.cancel_and_drain(handle, cleanup_deadline(context))
        checkout_refusal(:provider_admission_timeout)
    end
  end

  defp await_checkout_down(pid, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end
  end

  defp checkout_cancelled(:drained, _context),
    do: refusal(:timeout, "LLM request cancelled", true)

  defp checkout_cancelled(:uncertain, context) do
    mark_cleanup_failed(context)
    cleanup_failed()
  end

  defp checkout_refusal(:provider_capacity_exhausted),
    do: refusal(:capacity_exhausted, @capacity_text, true)

  defp checkout_refusal(:provider_admission_timeout),
    do: refusal(:timeout, @timeout_text, true)

  defp checkout_refusal(:provider_admission_unavailable),
    do: refusal(:admission_unavailable, @unavailable_text, false)

  defp granted(_admission, lease, handle, deadline, context, admission_monitor) do
    if deadline <= System.monotonic_time(:millisecond) do
      complete_unused(lease, handle, cleanup_deadline(context), context)
    else
      :ok = CancelableRequest.dispatch(handle)

      case CancelableRequest.await_or_cancel(handle, deadline, admission_monitor) do
        {:ok, result} -> publish_after_completion(lease, result, context)
        {:error, :timeout} -> cancel(lease, handle, cleanup_deadline(context), context)
        {:error, :cancellation_witness_unavailable} -> uncertain(lease, context)
        {:error, :provider_admission_unavailable} -> cleanup_failed()
        {:cancelled, :drained} -> complete_cancelled(lease)
        {:cancelled, :uncertain} -> uncertain(lease, context)
      end
    end
  end

  defp complete_unused(lease, handle, cleanup_deadline, context) do
    case CancelableRequest.cancel_and_drain(handle, cleanup_deadline) do
      :drained ->
        case ProviderCallAdmission.complete(lease, :cancelled) do
          :ok -> refusal(:timeout, @timeout_text, true)
          _ -> cleanup_failed()
        end

      :uncertain ->
        uncertain(lease, context)
    end
  end

  defp publish_after_completion(lease, result, context) do
    case ProviderCallAdmission.complete(lease, :completed) do
      :ok ->
        result

      _ ->
        mark_cleanup_failed(context)
        cleanup_failed()
    end
  end

  defp cancel(lease, handle, cleanup_deadline, context) do
    case CancelableRequest.cancel_and_drain(handle, cleanup_deadline) do
      :drained ->
        case ProviderCallAdmission.complete(lease, :cancelled) do
          :ok ->
            {:error,
             ProviderError.new(:timeout, "LLM request deadline elapsed",
               retryable?: true,
               dispatch_provenance: :possibly_dispatched
             )}

          _ ->
            cleanup_failed()
        end

      :uncertain ->
        uncertain(lease, context)
    end
  end

  defp uncertain(lease, context) do
    _ = ProviderCallAdmission.complete(lease, :uncertain)
    mark_cleanup_failed(context)
    cleanup_failed()
  end

  defp mark_cleanup_failed(%{provider_run_state: run_state}) do
    _ =
      RunState.fail_once(
        run_state,
        :provider_cleanup_error,
        :provider_cleanup_failed
      )

    :ok
  end

  defp mark_cleanup_failed(_context), do: :ok

  defp complete_cancelled(lease) do
    case ProviderCallAdmission.complete(lease, :cancelled) do
      :ok ->
        {:error,
         ProviderError.new(:timeout, "LLM request cancelled",
           retryable?: true,
           dispatch_provenance: :possibly_dispatched
         )}

      _ ->
        cleanup_failed()
    end
  end

  defp cleanup_deadline(%{provider_cleanup_timeout_ms: timeout_ms})
       when is_integer(timeout_ms) and timeout_ms > 0,
       do: System.monotonic_time(:millisecond) + timeout_ms

  defp cleanup_deadline(_context), do: System.monotonic_time(:millisecond) + 5_000

  defp cleanup_failed,
    do:
      {:error,
       ProviderError.new(:admission_unavailable, @unavailable_text,
         dispatch_provenance: :possibly_dispatched
       )}

  defp refusal(kind, text, retryable?) do
    {:error,
     ProviderError.new(kind, text,
       retryable?: retryable?,
       dispatch_provenance: :not_dispatched
     )}
  end

  @spec monitor_admission(ProviderCallAdmission.t()) :: reference()
  defp monitor_admission(admission), do: Process.monitor(admission)
end
