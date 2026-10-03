defmodule PtcRunner.Kernel.Dispatcher.ProviderCall do
  @moduledoc "Internal monitored provider lifecycle. The callback gate is opened only by RunState."

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CapabilityExceptionDiagnostic
  alias PtcRunner.Kernel.CapabilityInvocation
  alias PtcRunner.Kernel.Dispatcher.LlmResult
  alias PtcRunner.Kernel.Dispatcher.Result
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.ModelCapabilities
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunState

  def invoke(
        state,
        reservation_id,
        invocation,
        requested_timeout_ms,
        context,
        environment,
        validation
      ) do
    capability = invocation.capability
    arguments = invocation.arguments
    remaining = RunState.usage(state).remaining_ms

    timeout_ms =
      invocation
      |> CapabilityInvocation.clamp_provider_timeout(min(requested_timeout_ms, remaining))

    limits = Result.state_limits(state)

    if timeout_ms <= 0 do
      result =
        if LlmResult.llm_deadline_wins?(invocation) do
          Result.record_llm_timeout_evidence(state)
          Result.llm_request_timeout()
        else
          Result.limit_error(state, nil, :run_deadline)
        end

      {:settlement, {:adapter_error, :not_dispatched}, result}
    else
      parent = self()
      go = make_ref()

      {pid, ref} =
        spawn_monitor(fn ->
          Process.flag(:max_heap_size, %{
            size: limits.provider_heap_words,
            kill: true,
            error_logger: false
          })

          # Gate: run nothing until the dispatcher has attached this pid to
          # its reservation in RunState. If the dispatching process dies
          # first, exit instead of running the callback as an untracked
          # orphan holding a live provider slot.
          parent_ref = Process.monitor(parent)

          receive do
            ^go ->
              result = safely_invoke(capability.callback, arguments, context, parent)

              if Result.terminal_provider_failure?(result),
                do: RunState.mark_evaluation_terminal_provider_failure(state)

              send(parent, {
                :provider_result,
                self(),
                System.monotonic_time(:millisecond),
                result
              })

            {:DOWN, ^parent_ref, :process, _parent, _reason} ->
              :ok
          end
        end)

      attach =
        if capability.provider_call_guardian,
          do: RunState.attach_provider_guardian(state, reservation_id, pid),
          else: RunState.attach_provider(state, reservation_id, pid)

      case attach do
        :ok ->
          case RunState.open_provider_gate(state, reservation_id, pid, go) do
            :ok ->
              await_provider(
                state,
                reservation_id,
                invocation,
                pid,
                ref,
                timeout_ms,
                environment,
                validation
              )

            {:error, reason}
            when reason in [
                   :provider_mismatch,
                   :run_closed,
                   :unknown_reservation
                 ] ->
              Process.exit(pid, :kill)
              await_down(pid, ref)

              {:settlement, {:adapter_error, :not_dispatched},
               Result.limit_error(state, nil, :run_closed)}

            {:error, reason} when reason in [:already_dispatched, :dispatch_unknown] ->
              Process.exit(pid, :kill)
              await_down(pid, ref)

              {:settlement, {:adapter_error, :provider_error},
               Result.limit_error(state, nil, :run_closed)}
          end

        {:error, :provider_down} ->
          reason = await_down(pid, ref)

          # The provider died before the gate opened, so the callback never
          # ran and no effect can have reached the outside world.
          {:settlement, {:adapter_error, :not_dispatched},
           Result.post_invocation_failure(
             provider_exit(reason),
             environment,
             capability,
             :not_dispatched
           )}

        {:error, reason} when reason in [:closed, :unknown_reservation] ->
          await_down(pid, ref)

          {:settlement, {:adapter_error, :not_dispatched},
           Result.limit_error(state, nil, :run_closed)}
      end
    end
  end

  defp await_provider(
         state,
         _reservation_id,
         invocation,
         pid,
         ref,
         timeout_ms,
         environment,
         validation
       ) do
    capability = invocation.capability

    receive do
      {:provider_result, ^pid, completed_at_ms, raw_result} ->
        await_down(pid, ref)
        settlement = LlmResult.settlement_evidence(raw_result)
        result = enforce_completion_deadline(invocation, completed_at_ms, raw_result)
        record_provider_diagnostics(state, invocation, result)

        normalized =
          Result.normalize_result(
            state,
            environment,
            invocation,
            validation,
            {:provider_completed, completed_at_ms, result}
          )

        {:settlement, settlement, normalized}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:settlement, {:adapter_error, :worker_exit},
         Result.post_invocation_failure(provider_exit(reason), environment, capability)}
    after
      timeout_ms ->
        cancel_provider_at_timeout(state, capability, pid, ref)
        timeout_result = Result.await_timeout_result(invocation)

        if ModelCapabilities.model_call?(capability.name, invocation.model_call_names),
          do: Result.record_llm_timeout_evidence(state)

        {:settlement, {:adapter_error, :timeout},
         Result.post_invocation_failure(
           timeout_result,
           environment,
           capability
         )}
    end
  end

  defp cancel_provider_at_timeout(state, %{provider_call_guardian: true}, pid, ref) do
    request_ref = make_ref()

    deadline =
      System.monotonic_time(:millisecond) + Result.state_limits(state).provider_cleanup_timeout_ms

    send(pid, {:cancel_provider_call, self(), request_ref, deadline})
    await_guardian_down(pid, ref, request_ref, deadline)
  end

  defp cancel_provider_at_timeout(_state, _capability, pid, ref) do
    Process.exit(pid, :kill)
    await_down(pid, ref)
  end

  defp await_guardian_down(pid, ref, request_ref, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:provider_call_drained, ^request_ref, ^pid, _status} ->
        await_guardian_down(pid, ref, request_ref, deadline)

      {:DOWN, ^ref, :process, ^pid, reason} ->
        reason
    after
      timeout ->
        Process.exit(pid, :kill)
        await_down(pid, ref)
    end
  end

  defp await_down(pid, ref) do
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> reason
    end
  end

  defp enforce_completion_deadline(invocation, completed_at_ms, result) do
    if LlmResult.llm_deadline_wins?(invocation, completed_at_ms) do
      {:error, ProviderError.new(:timeout, "LLM request deadline elapsed", retryable?: true)}
    else
      result
    end
  end

  defp provider_exit(reason) do
    %{
      status: :error,
      kind: :provider_error,
      reason: Result.normalize_exit(reason),
      retryable?: false
    }
  end

  defp safely_invoke(callback, arguments, context, diagnostic_owner) do
    if is_function(callback, 2), do: callback.(arguments, context), else: callback.(arguments)
  rescue
    exception -> raised_exception(exception, __STACKTRACE__, context, diagnostic_owner)
  catch
    :exit, _reason -> {:raised, :exit}
    _kind, _reason -> {:raised, :throw}
  end

  defp raised_exception(
         exception,
         stacktrace,
         %{inspection_sink: %InspectionSink{}},
         diagnostic_owner
       ) do
    case CapabilityExceptionDiagnostic.start(exception, stacktrace, diagnostic_owner) do
      {:ok, pid, exception_class} ->
        {:raised, :exception, {:diagnostic_worker, pid, exception_class}}

      {:error, exception_class} ->
        {:raised, :exception, {:diagnostic_unavailable, exception_class}}
    end
  end

  defp raised_exception(_exception, _stacktrace, _context, _diagnostic_owner),
    do: {:raised, :exception}

  defp record_provider_diagnostics(state, invocation, result) do
    case replay_request_hash(result) do
      request_hash when is_binary(request_hash) ->
        RunState.record_replay_miss(state, request_hash)

      nil ->
        :ok
    end

    case llm_provider_error(invocation.capability, result, invocation.model_call_names) do
      %ProviderError{} = error -> RunState.record_llm_provider_failure(state, error)
      nil -> :ok
    end

    :ok
  end

  defp replay_request_hash({:error, %ProviderError{} = error}) do
    if ProviderError.valid?(error), do: error.replay_request_hash, else: nil
  end

  defp replay_request_hash(_result), do: nil

  defp llm_provider_error(
         %Capability{name: name},
         {:error, %ProviderError{} = error},
         model_call_names
       ) do
    if ModelCapabilities.model_call?(name, model_call_names) and ProviderError.valid?(error),
      do: error,
      else: nil
  end

  defp llm_provider_error(_capability, _result, _model_call_names), do: nil
end
