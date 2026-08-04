defmodule PtcRunner.Kernel.ProviderCallbackBoundary do
  @moduledoc false

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession

  @type provider_occurrence :: %{
          provider: binary(),
          destination: :workflow | :mission,
          index: non_neg_integer()
        }

  @failure_marker {__MODULE__, :nested_failure}

  @doc false
  @spec nested_failure(term()) :: {:error, {{module(), atom()}, term()}}
  def nested_failure(reason), do: {:error, {@failure_marker, reason}}

  @spec context(ProviderSession.t()) :: map()
  def context(session) do
    case ProviderSession.execution_deadline(session) do
      {:ok, deadline} when not is_nil(deadline) ->
        %{deadline: deadline, deadline_ms: Deadline.expires_at(deadline)}

      _without_operation_deadline ->
        %{}
    end
  end

  @spec invoke(
          ProviderSession.t(),
          pos_integer(),
          provider_occurrence() | map(),
          (-> term())
        ) ::
          {:ok, term()}
          | {:deadline_expired, term(), CommandDiagnostic.t()}
          | {:error, CommandDiagnostic.t()}
  def invoke(session, max_heap_words, provider, callback)
      when is_integer(max_heap_words) and max_heap_words > 0 and is_function(callback, 0) do
    case ProviderSession.execution_deadline(session) do
      {:ok, nil} ->
        {:ok, callback.()}

      {:ok, deadline} ->
        invoke_active(session, deadline, max_heap_words, provider, callback)

      :error ->
        {:error, acquisition_diagnostic(provider)}
    end
  end

  @spec release_preflights([map()], ProviderSession.t(), pos_integer()) :: :ok
  def release_preflights(preflighted, session, max_heap_words)
      when is_list(preflighted) and is_integer(max_heap_words) and max_heap_words > 0 do
    case ProviderSession.execution_deadline(session) do
      {:ok, nil} ->
        Enum.each(preflighted, &release_preflight/1)

      {:ok, _run_deadline} ->
        release_active_preflights(preflighted, session, max_heap_words)

      :error ->
        :ok
    end
  end

  defp invoke_active(session, deadline, max_heap_words, provider, callback) do
    result =
      case Deadline.remaining(deadline) do
        0 ->
          {:error, :timeout}

        timeout_ms ->
          BoundedWorker.run(callback,
            timeout_ms: timeout_ms,
            max_heap_words: max_heap_words,
            cancel_with_caller: true,
            cancel_with: ProviderSession.worker_cancel_target(session)
          )
      end

    diagnostic = acquisition_diagnostic(provider)

    case result do
      {:ok, {:error, {@failure_marker, _reason}}} ->
        {:error, diagnostic}

      {:ok, callback_result} ->
        if Deadline.expired?(deadline),
          do: {:deadline_expired, callback_result, diagnostic},
          else: {:ok, callback_result}

      {:error, _reason} ->
        {:error, diagnostic}
    end
  end

  defp release_active_preflights(preflighted, session, max_heap_words) do
    case ProviderSession.cleanup_timeout(session) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        cleanup_deadline = Deadline.new(timeout_ms)
        Enum.each(preflighted, &release_active_preflight(&1, cleanup_deadline, max_heap_words))

      _invalid_session ->
        :ok
    end

    :ok
  end

  defp release_active_preflight(provider, cleanup_deadline, max_heap_words) do
    case Deadline.remaining(cleanup_deadline) do
      0 ->
        :ok

      remaining_ms ->
        BoundedWorker.run(fn -> release_preflight(provider) end,
          timeout_ms: remaining_ms,
          max_heap_words: max_heap_words,
          cancel_with_caller: true
        )
    end
  end

  defp release_preflight(%{preflighted: provider}),
    do: ProviderRegistry.release_preflight(provider)

  defp release_preflight(provider), do: ProviderRegistry.release_preflight(provider)

  defp acquisition_diagnostic(provider) do
    occurrence = %{destination: provider.destination, index: provider.index}
    {:ok, subject} = CommandSubject.provider(provider.provider, :acquisition, occurrence)

    CommandDiagnostic.new!(:provider_acquisition, :provider_unavailable,
      subject: subject,
      provider_activity: true
    )
  end
end
