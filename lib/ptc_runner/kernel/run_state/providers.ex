defmodule PtcRunner.Kernel.RunState.Providers do
  @moduledoc "Internal pure provider reservation transitions. Lifecycle effects belong to RunState."

  def reservation_for_caller?(reservations, caller) do
    Enum.any?(reservations, fn {_id, reservation} -> reservation.caller == caller end)
  end

  def reservation_by_provider_ref(reservations, ref) do
    Enum.find_value(reservations, fn {reservation_id, reservation} ->
      if reservation.provider_ref == ref, do: {reservation_id, reservation}
    end)
  end

  def reservation_by_caller_ref(reservations, ref) do
    Enum.find_value(reservations, fn {reservation_id, reservation} ->
      if reservation.caller_ref == ref, do: {reservation_id, reservation}
    end)
  end

  def attach(state, id, provider, monitor_ref, kind) do
    update_in(state.reservations[id], fn reservation ->
      reservation
      |> Map.put(:provider, provider)
      |> Map.put(:provider_ref, monitor_ref)
      |> Map.put(:provider_kind, kind)
    end)
  end

  def gate_status(state, id, provider, unavailable?) do
    cond do
      unavailable? -> {:error, :run_closed}
      not Map.has_key?(state.reservations, id) -> {:error, :unknown_reservation}
      get_in(state.reservations, [id, :provider]) != provider -> {:error, :provider_mismatch}
      get_in(state.reservations, [id, :dispatched?]) -> {:error, :already_dispatched}
      true -> :ok
    end
  end

  def mark_dispatched(state, id), do: put_in(state.reservations[id].dispatched?, true)

  def settled(state, reservations, llm_budget) do
    %{
      state
      | provider_tasks: max(state.provider_tasks - 1, 0),
        reservations: reservations,
        llm_budget: llm_budget
    }
  end

  def guardian_down(state, reservation, reason) do
    if Map.get(reservation, :provider_kind) == :guardian and reason != :normal do
      failure =
        state.terminal_failure ||
          %{kind: :provider_cleanup_error, reason: :provider_cleanup_failed}

      {%{state | closed?: true, terminal_failure: failure}, true}
    else
      {state, false}
    end
  end

  def cancel_started(state, id, pid, ref) do
    update_in(state.reservations[id], fn reservation ->
      reservation
      |> Map.put(:caller_ref, nil)
      |> Map.put(:cancel_pid, pid)
      |> Map.put(:cancel_ref, ref)
    end)
  end

  def cancellation_complete(state, id) do
    update_in(state.reservations[id], &Map.drop(&1, [:cancel_pid, :cancel_ref]))
  end

  def caller_down(state, id), do: put_in(state.reservations[id].caller_ref, nil)

  def provider_down(state, id) do
    update_in(state.reservations[id], &%{&1 | provider: nil, provider_ref: nil})
  end
end
