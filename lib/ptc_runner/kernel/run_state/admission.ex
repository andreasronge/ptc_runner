defmodule PtcRunner.Kernel.RunState.Admission do
  @moduledoc "Internal pure evaluation admission transitions. Monitors, timers and replies belong to RunState."

  @workflow_continuation "$workflow"

  def grantable?(state) do
    state.evaluation_lease == nil and not stale_lease_reservations?(state)
  end

  defp stale_lease_reservations?(state) do
    Enum.any?(state.reservations, fn
      {_caller, %{evaluation_lease: lease}} -> is_reference(lease)
      _reservation -> false
    end)
  end

  def admission_deadline(state, requested_at) do
    min(
      requested_at + state.limits.evaluation_admission_timeout_ms,
      state.deadline_ms
    )
  end

  def take_admission_waiter(state, monitor_ref) do
    waiters = :queue.to_list(state.admission_queue)

    case Enum.split_with(waiters, &(&1.monitor_ref == monitor_ref)) do
      {[waiter], rest} -> {waiter, %{state | admission_queue: :queue.from_list(rest)}}
      {[], _waiters} -> {nil, state}
    end
  end

  def continuation(state, mission_name),
    do: Map.get(state.continuations, mission_name, %{memory: %{}, history: [], revision: 0})

  def record_evaluation(state, @workflow_continuation),
    do: %{state | evaluations: state.evaluations + 1}

  def record_evaluation(state, mission_name) do
    %{
      state
      | evaluations: state.evaluations + 1,
        evaluations_by_mission:
          Map.update(state.evaluations_by_mission, mission_name, 1, &(&1 + 1))
    }
  end

  @doc "Assigns a prepared lease; the owner controls monitor transfer and evaluation charging."
  def grant_lease(state, mission, lease) do
    %{
      state
      | evaluation_lease: lease,
        evaluation_mission: mission,
        evaluation_release_waiter: nil,
        evaluation_terminal_provider_failure?: false,
        evaluation_terminal_host_failure?: false
    }
  end

  @doc "Checks admission using the caller's timestamp and a clock sampled by the owner."
  def decision(state, mode, admission_deadline, now) do
    cond do
      state.closed? ->
        {:error, :run_closed}

      now >= state.deadline_ms ->
        {:error, :deadline_expired}

      mode == :fail_fast and (not grantable?(state) or not :queue.is_empty(state.admission_queue)) ->
        {:error, :busy}

      mode == :block and now >= admission_deadline ->
        {:error, :admission_timeout}

      state.evaluations >= state.limits.subordinate_evaluations ->
        {:error, :limit_exceeded}

      grantable?(state) and :queue.is_empty(state.admission_queue) ->
        :grant

      true ->
        :enqueue
    end
  end

  def queued_decision(state, waiter, now) do
    cond do
      state.closed? -> {:error, :run_closed}
      now >= state.deadline_ms -> {:error, :deadline_expired}
      now >= waiter.deadline_mono -> {:error, :admission_timeout}
      state.evaluations >= state.limits.subordinate_evaluations -> {:error, :limit_exceeded}
      not grantable?(state) -> :wait
      true -> :grant
    end
  end

  def enqueue(state, waiter),
    do: %{state | admission_queue: :queue.in(waiter, state.admission_queue)}
end
