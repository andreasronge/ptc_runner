defmodule PtcRunner.Kernel.ReplTerminalization do
  @moduledoc false

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMBudget
  alias PtcRunner.Kernel.TraceLog

  @doc false
  @spec finalize_abandoned(map() | nil, binary() | nil, term(), Limits.t()) :: :ok
  def finalize_abandoned(
        %{event_sink: %EventSink{} = event_sink},
        trace_path,
        provider_cleanup,
        %Limits{} = limits
      ) do
    if Process.alive?(event_sink.pid) do
      reason =
        if provider_cleanup == {:error, :provider_cleanup_failed},
          do: :provider_cleanup_failed,
          else: :session_owner_failed

      case EventSink.finalize_and_events(event_sink, %{
             outcome: :error,
             reason: reason,
             usage: %{llm_budget: LLMBudget.unavailable_terminal_projection(limits)}
           }) do
        {:ok, %{events: events}} -> persist(trace_path, event_sink, events)
        {:error, :event_sink_error} -> :ok
      end
    end

    :ok
  end

  def finalize_abandoned(_opened_sinks, _trace_path, _provider_cleanup, _limits), do: :ok

  @doc false
  @spec persist(binary() | nil, EventSink.t(), [map()]) ::
          :ok | {:error, :trace_persistence_failed}
  def persist(nil, %EventSink{}, _events), do: :ok

  def persist(path, %EventSink{} = event_sink, events)
      when is_binary(path) and is_list(events) do
    private? = EventSink.policy(event_sink) == :private

    case TraceLog.append_jsonl(path, events, private: private?) do
      :ok -> :ok
      {:error, _reason} -> {:error, :trace_persistence_failed}
    end
  end
end
