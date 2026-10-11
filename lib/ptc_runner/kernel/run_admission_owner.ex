defmodule PtcRunner.Kernel.RunAdmissionOwner do
  @moduledoc """
  Atomic capacity, reservation and publication state for hosted executions.

  Admission and transfer authorize execution before any resource opens.
  Completion releases capacity only after owner cleanup, or fences the domain.
  This owner never starts an execution session.
  """
  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction

  def start_link(capacity), do: GenServer.start_link(__MODULE__, capacity)
  def admit(host), do: call(host, :admit)
  def transfer(host, ref, ticket, caller), do: call(host, {:transfer, ref, ticket, caller})
  def complete(host, clean?), do: call(host, {:complete, clean?})

  @impl true
  def init(capacity),
    do: {:ok, %{capacity: capacity, owners: %{}, reservations: %{}, status: :ready}}

  @impl true
  def handle_call(:snapshot, _, state) do
    state = fence_dead_owners(state)

    status = if state.status == :ready, do: :ready, else: :unavailable
    {:reply, {:ok, %{capacity: state.capacity, in_use: in_use(state), status: status}}, state}
  end

  def handle_call({:reserve, deadline}, {caller, _}, state) do
    state = fence_dead_owners(state)

    cond do
      state.status != :ready or not deadline_live?(deadline) or not Process.alive?(caller) ->
        {:reply, {:error, :run_admission_unavailable}, state}

      in_use(state) >= state.capacity ->
        {:reply, {:error, :run_capacity_exhausted}, state}

      true ->
        ref = make_ref()
        timer = deadline_timer(deadline, ref)

        reservation = %{
          caller: caller,
          monitor: Process.monitor(caller),
          deadline: deadline,
          timer: timer,
          ticket: nil,
          owner: nil,
          cancelled?: false,
          publication: :none,
          admission_refused?: false,
          cleanup_uncertain?: false
        }

        {:reply, {:ok, {__MODULE__, self(), ref}},
         %{state | reservations: Map.put(state.reservations, ref, reservation)}}
    end
  end

  def handle_call({:retain_publication, ref}, {caller, _}, state) do
    state = fence_dead_owners(state)

    case state.reservations[ref] do
      %{caller: ^caller, owner: nil, ticket: nil, publication: :none} = reservation ->
        if state.status == :ready and deadline_live?(reservation.deadline) and
             Process.alive?(caller) and not reservation.cancelled? do
          {:reply, :ok, put_reservation(state, ref, %{reservation | publication: :pending})}
        else
          {:reply, {:error, :run_admission_unavailable}, refuse_activation(state, ref)}
        end

      _ ->
        {:reply, {:error, :run_admission_unavailable}, state}
    end
  end

  def handle_call({:finish_publication, ref, clean?}, {caller, _}, state)
      when is_boolean(clean?) do
    state = reap_dead_reservation_owner(state, ref)

    case state.reservations[ref] do
      %{caller: ^caller, owner: nil, publication: :frozen} ->
        next = drop_reservation(state, ref)
        {:reply, :ok, %{next | status: if(clean?, do: next.status, else: :unavailable)}}

      %{caller: ^caller, owner: nil, publication: publication} = reservation
      when publication in [:held, :pending] ->
        reply =
          cond do
            reservation.cleanup_uncertain? -> {:error, :call_cleanup_failed}
            reservation.admission_refused? -> {:error, :call_admission_refused}
            reservation.cancelled? -> {:error, :call_cancelled}
            true -> :ok
          end

        next = drop_reservation(state, ref)
        {:reply, reply, %{next | status: if(clean?, do: next.status, else: :unavailable)}}

      %{caller: ^caller, owner: owner} = reservation when is_pid(owner) and not clean? ->
        next = cancel_reservation(state, ref)

        next =
          put_reservation(next, ref, %{reservation | publication: :discard, cancelled?: true})

        {:reply, :ok, %{next | status: :unavailable}}

      _ ->
        {:reply, {:error, :run_admission_unavailable}, state}
    end
  end

  def handle_call({:freeze_publication, ref, clean?}, {caller, _}, state)
      when is_boolean(clean?) do
    state = reap_dead_reservation_owner(state, ref)

    case state.reservations[ref] do
      %{caller: ^caller, owner: nil, publication: publication} = reservation
      when publication in [:held, :pending] ->
        reply = publication_result(reservation, clean?)
        next = put_reservation(state, ref, %{reservation | publication: :frozen})
        fenced? = not clean? or reply == {:error, :call_cleanup_failed}
        {:reply, reply, %{next | status: if(fenced?, do: :unavailable, else: next.status)}}

      _ ->
        {:reply, {:error, :run_admission_unavailable}, state}
    end
  end

  def handle_call({:begin_activation, ref}, {caller, _}, state) do
    state = fence_dead_owners(state)

    case state.reservations[ref] do
      %{caller: ^caller, owner: nil, ticket: nil} = reservation ->
        if state.status == :ready and deadline_live?(reservation.deadline) and
             Process.alive?(caller) and not reservation.cancelled? do
          ticket = make_ref()
          {:reply, {:ok, ticket}, put_reservation(state, ref, %{reservation | ticket: ticket})}
        else
          {:reply, {:error, :run_admission_unavailable}, refuse_activation(state, ref)}
        end

      _ ->
        {:reply, {:error, :run_admission_unavailable}, state}
    end
  end

  def handle_call({:transfer, ref, ticket, caller}, {owner, _}, state) do
    state = fence_dead_owners(state)

    case state.reservations[ref] do
      %{caller: ^caller, owner: nil, ticket: ^ticket} = reservation when is_reference(ticket) ->
        if state.status == :ready and deadline_live?(reservation.deadline) and
             Process.alive?(caller) and not reservation.cancelled? and
             not Map.has_key?(state.owners, owner) do
          Process.demonitor(reservation.monitor, [:flush])
          next = put_reservation(state, ref, %{reservation | owner: owner, monitor: nil})
          {:reply, :ok, %{next | owners: Map.put(next.owners, owner, Process.monitor(owner))}}
        else
          {:reply, {:error, :run_admission_unavailable}, refuse_activation(state, ref)}
        end

      _ ->
        {:reply, {:error, :run_admission_unavailable}, state}
    end
  end

  def handle_call({:cancel, ref}, {caller, _}, state) do
    case state.reservations[ref] do
      %{caller: ^caller, cancelled?: false} ->
        {:reply, :ok, cancel_reservation(state, ref)}

      _ ->
        {:reply, {:error, :run_admission_unavailable}, state}
    end
  end

  def handle_call({:cancel_external, ref}, _from, state) do
    case state.reservations[ref] do
      %{cancelled?: false} -> {:reply, :ok, cancel_reservation(state, ref)}
      _ -> {:reply, {:error, :run_admission_unavailable}, state}
    end
  end

  def handle_call(:quiesce, _from, %{status: :ready} = state),
    do: {:reply, :ok, %{state | status: :quiesced}}

  def handle_call(:quiesce, _from, state),
    do: {:reply, {:error, :run_admission_unavailable}, state}

  def handle_call(:shutdown_clean, _from, state),
    do: {:reply, state.status == :quiesced and in_use(state) == 0, state}

  def handle_call(:cancel_all, _from, state) do
    state = %{state | status: :unavailable}
    Enum.each(Map.keys(state.owners), &send(&1, {:run_admission_cancel, self()}))

    state =
      Enum.reduce(Map.keys(state.reservations), state, fn ref, acc ->
        cancel_reservation(acc, ref)
      end)

    {:reply, :ok, state}
  end

  def handle_call(:admit, {owner, _}, state) do
    state = fence_dead_owners(state)

    cond do
      Map.has_key?(state.owners, owner) or not Process.alive?(owner) ->
        {:reply, {:error, :run_admission_unavailable}, state}

      state.status != :ready ->
        {:reply, {:error, :run_admission_unavailable}, state}

      in_use(state) >= state.capacity ->
        {:reply, {:error, :run_capacity_exhausted}, state}

      true ->
        {:reply, :ok, %{state | owners: Map.put(state.owners, owner, Process.monitor(owner))}}
    end
  end

  def handle_call({:complete, clean?}, {owner, _}, state) when is_boolean(clean?) do
    if Map.has_key?(state.owners, owner) do
      {:reply, :ok, settle_owner(state, owner, clean?)}
    else
      {:reply, {:error, :run_admission_unavailable}, state}
    end
  end

  def handle_call(_, _, state), do: {:reply, {:error, :run_admission_unavailable}, state}

  @impl true
  def handle_info({:DOWN, ref, :process, owner, _}, state) do
    if state.owners[owner] == ref do
      {:noreply, settle_owner(state, owner, false)}
    else
      next =
        Enum.reduce(state.reservations, state, fn
          {key, %{monitor: ^ref, caller: ^owner, publication: :frozen}}, acc ->
            %{drop_reservation(acc, key) | status: :unavailable}

          {key, %{monitor: ^ref, caller: ^owner}}, acc ->
            cancel_reservation(acc, key)

          _, acc ->
            acc
        end)

      {:noreply, next}
    end
  end

  def handle_info({:reservation_deadline, ref}, state) do
    case state.reservations[ref] do
      nil ->
        {:noreply, state}

      reservation ->
        if deadline_live?(reservation.deadline) do
          timer = deadline_timer(reservation.deadline, ref)
          {:noreply, put_reservation(state, ref, %{reservation | timer: timer})}
        else
          {:noreply, cancel_reservation(state, ref)}
        end
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp in_use(state),
    do: map_size(state.owners) + Enum.count(state.reservations, fn {_, r} -> is_nil(r.owner) end)

  defp deadline_live?(:infinity), do: true

  defp deadline_live?(deadline) when is_integer(deadline),
    do: deadline > System.monotonic_time(:millisecond)

  defp deadline_live?(_), do: false

  defp deadline_timer(:infinity, _), do: nil

  defp deadline_timer(deadline, ref),
    do:
      Process.send_after(
        self(),
        {:reservation_deadline, ref},
        min(4_294_967_295, max(0, deadline - System.monotonic_time(:millisecond)))
      )

  defp put_reservation(state, ref, reservation),
    do: %{state | reservations: Map.put(state.reservations, ref, reservation)}

  defp refuse_activation(state, ref) do
    reservation = state.reservations[ref]

    if reservation.publication == :pending and state.status != :ready and
         deadline_live?(reservation.deadline) and Process.alive?(reservation.caller) and
         not reservation.cancelled? do
      put_reservation(state, ref, %{reservation | admission_refused?: true})
    else
      cancel_reservation(state, ref)
    end
  end

  defp cancel_reservation(state, ref) do
    case state.reservations[ref] do
      nil ->
        state

      %{publication: :frozen} ->
        state

      %{owner: nil, publication: publication} = reservation
      when publication in [:held, :pending] ->
        if Process.alive?(reservation.caller) do
          put_reservation(state, ref, %{reservation | cancelled?: true})
        else
          %{drop_reservation(state, ref) | status: :unavailable}
        end

      %{owner: nil} ->
        drop_reservation(state, ref)

      %{cancelled?: true} ->
        state

      reservation ->
        send(reservation.owner, {:run_admission_cancel, self()})
        put_reservation(state, ref, %{reservation | cancelled?: true})
    end
  end

  defp publication_result(reservation, clean?) do
    cond do
      not clean? or reservation.cleanup_uncertain? -> {:error, :call_cleanup_failed}
      reservation.admission_refused? -> {:error, :call_admission_refused}
      reservation.cancelled? -> {:error, :call_cancelled}
      true -> :ok
    end
  end

  defp drop_reservation(state, ref) do
    {reservation, reservations} = Map.pop(state.reservations, ref)
    if reservation.monitor, do: Process.demonitor(reservation.monitor, [:flush])
    if reservation.timer, do: Process.cancel_timer(reservation.timer)
    %{state | reservations: reservations}
  end

  defp reap_dead_reservation_owner(state, ref) do
    case state.reservations[ref] do
      %{owner: owner} when is_pid(owner) ->
        if Map.has_key?(state.owners, owner) and not Process.alive?(owner),
          do: settle_owner(state, owner, false),
          else: state

      _ ->
        state
    end
  end

  defp settle_owner(state, owner, clean?) do
    Process.demonitor(Map.fetch!(state.owners, owner), [:flush])
    next = complete_owner_reservation(state, owner, clean?)

    %{
      next
      | owners: Map.delete(next.owners, owner),
        status: if(clean?, do: next.status, else: :unavailable)
    }
  end

  defp complete_owner_reservation(state, owner, clean?) do
    Enum.reduce(state.reservations, state, fn
      {ref, %{owner: ^owner, publication: :pending} = reservation}, acc ->
        put_reservation(acc, ref, %{
          reservation
          | owner: nil,
            publication: :held,
            cleanup_uncertain?: reservation.cleanup_uncertain? or not clean?,
            monitor: Process.monitor(reservation.caller)
        })

      {ref, %{owner: ^owner}}, acc ->
        drop_reservation(acc, ref)

      _, acc ->
        acc
    end)
  end

  defp fence_dead_owners(state) do
    state =
      Enum.reduce(state.reservations, state, fn {ref, reservation}, acc ->
        cond do
          reservation.publication == :frozen and not Process.alive?(reservation.caller) ->
            %{drop_reservation(acc, ref) | status: :unavailable}

          not deadline_live?(reservation.deadline) or
              (is_nil(reservation.owner) and not Process.alive?(reservation.caller)) ->
            cancel_reservation(acc, ref)

          true ->
            acc
        end
      end)

    if Enum.any?(state.owners, fn {pid, _} -> not Process.alive?(pid) end),
      do: %{state | status: :unavailable},
      else: state
  end

  @doc false
  def call(host, request) when is_pid(host) do
    GenServer.call(host, request, :infinity)
  catch
    :exit, _ -> {:error, :run_admission_unavailable}
  end

  @doc false
  def call(_, _), do: {:error, :run_admission_unavailable}
end
