defmodule PtcRunner.Kernel.ProviderCallOwner do
  @moduledoc false

  alias PtcRunner.Kernel.CancelableRequest
  alias PtcRunner.Kernel.ProviderCallAdmission
  alias PtcRunner.Kernel.ProviderError

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
      case CancelableRequest.start_cancelable(requester, request, context, self()) do
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
    case ProviderCallAdmission.checkout(admission, deadline) do
      {:ok, lease} ->
        granted(admission, lease, handle, deadline, context, admission_monitor)

      {:error, reason} ->
        _ = CancelableRequest.cancel_and_drain(handle, deadline)
        checkout_refusal(reason)
    end
  end

  defp checkout_refusal(:provider_capacity_exhausted),
    do: refusal(:capacity_exhausted, @capacity_text, true)

  defp checkout_refusal(:provider_admission_timeout),
    do: refusal(:timeout, @timeout_text, true)

  defp checkout_refusal(:provider_admission_unavailable),
    do: refusal(:admission_unavailable, @unavailable_text, false)

  defp granted(_admission, lease, handle, deadline, context, admission_monitor) do
    if deadline <= System.monotonic_time(:millisecond) do
      complete_unused(lease, handle, deadline)
    else
      :ok = CancelableRequest.dispatch(handle)

      case CancelableRequest.await_or_cancel(handle, deadline, admission_monitor) do
        {:ok, result} -> publish_after_completion(lease, result)
        {:error, :timeout} -> cancel(lease, handle, cleanup_deadline(context))
        {:error, :cancellation_witness_unavailable} -> uncertain(lease)
        {:error, :provider_admission_unavailable} -> cleanup_failed()
        {:cancelled, :drained} -> complete_cancelled(lease)
        {:cancelled, :uncertain} -> uncertain(lease)
      end
    end
  end

  defp complete_unused(lease, handle, deadline) do
    case CancelableRequest.cancel_and_drain(handle, deadline) do
      :drained ->
        case ProviderCallAdmission.complete(lease, :cancelled) do
          :ok -> refusal(:timeout, @timeout_text, true)
          _ -> cleanup_failed()
        end

      :uncertain ->
        uncertain(lease)
    end
  end

  defp publish_after_completion(lease, result) do
    case ProviderCallAdmission.complete(lease, :completed) do
      :ok -> result
      _ -> cleanup_failed()
    end
  end

  defp cancel(lease, handle, cleanup_deadline) do
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
        uncertain(lease)
    end
  end

  defp uncertain(lease) do
    _ = ProviderCallAdmission.complete(lease, :uncertain)
    cleanup_failed()
  end

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
