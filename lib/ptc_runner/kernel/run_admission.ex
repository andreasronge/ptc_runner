defmodule PtcRunner.Kernel.RunAdmission do
  @moduledoc """
  Explicit host-owned admission for concurrent one-shot executions.

  Start one owner under the embedding host's supervisor with
  `max_concurrent_runs: n`, and pass its PID to `execute/5` for every hosted
  run. Preparation and publication keep their existing Kernel contracts;
  execution returns the same sealed `PtcRunner.Kernel.ExecutionOutcome`.
  Provider execution must use host-owned applications and no interactive
  authorization. This module neither starts ReqLLM nor changes its pools.

  A full owner returns `{:error, :run_capacity_exhausted}` before consuming the
  preparation, claiming publication, or activating providers. There is no
  waiting queue for execution capacity. Inbound connections, preparation,
  provisional admission processes, and control mailboxes remain the host's
  responsibility to bound.

  `reserve/2` supports transport commitment before execution exists. An unused
  reservation holds only capacity, a caller monitor and a deadline timer; it
  creates no session, input, policy, sink, publication authority, execution
  identity or provider activity. The caller supplies those only to `activate/3`
  or `activate/5`. Caller death or `close/1` releases unused capacity.
  Absolute deadlines remain in force after activation and request cancellation
  without releasing capacity ahead of cleanup.

  After activation, the lease belongs to the execution-session owner.
  Caller death triggers that owner's normal provider cleanup. Capacity is
  released only after cleanup has finished. An owner that dies without a
  cleanup acknowledgement, or reports cleanup failure, fences this admission
  owner: later runs return `{:error, :run_admission_unavailable}`. Other
  admitted runs may finish. The child spec never automatically restarts this
  capacity domain; the host must drain old work before replacing it. Active
  execution owners also monitor admission-owner death and abort their runs.

  ServingTemplate retains a transferred reservation through calling-worker
  publication. Execution cleanup transfers its capacity back to the monitored
  caller, without making the slot available; only publication completion releases
  it. Expiry marks it cancelled but retains it until publication cleanup. Caller
  death in this interval fences admission, as publication cleanup is unproven.

  This counts hosted workflows, not physical LLM requests. Per-run provider
  task limits still apply. Direct adapter calls and executions through other
  entry points bypass this owner; Finch capacity, aggregate physical-attempt
  admission, and rate limits remain separate host responsibilities.
  """
  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction

  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.PublicationAuthority

  @typedoc "Opaque single-use caller-owned capacity reservation."
  @opaque reservation :: {__MODULE__, pid(), reference()}
  @typedoc "Activated execution handle; only its caller may await it."
  @opaque execution :: {__MODULE__, pid(), ExecutionSessionOwner.t()}

  @doc """
  Reserves capacity atomically for the calling process, without execution resources.

  `deadline` is an absolute `System.monotonic_time(:millisecond)` integer
  or `:infinity`. An expired or invalid deadline returns
  `{:error, :run_admission_unavailable}`. A full domain returns
  `{:error, :run_capacity_exhausted}`; a dead or fenced domain returns
  `{:error, :run_admission_unavailable}`. No snapshot authorizes admission.
  """
  @spec reserve(pid(), integer() | :infinity) ::
          {:ok, reservation()} | {:error, :run_capacity_exhausted | :run_admission_unavailable}
  def reserve(host, deadline), do: call(host, {:reserve, deadline})

  @doc """
  Activates a provider-free reservation and returns an execution handle.

  Only the reserving caller can activate it, once. Transfer to a new execution
  owner happens before publication claim, preparation consumption, sink opening
  or dispatch. Failed activation closes the reservation; input validation errors
  retain their existing execution error codes. A closed, expired, foreign or
  already activated reservation returns `{:error, :run_admission_unavailable}`.
  Use `await/1` to collect the sealed outcome and wait for owner cleanup.
  """
  @spec activate(reservation(), PreparedRun.t(), PublicationAuthority.t()) ::
          {:ok, execution()} | {:error, term()}
  def activate(reservation, prepared, authority),
    do: activate_execution(reservation, prepared, authority, nil)

  @doc "Activates with the preparation's bound catalog and host-owned provider services."
  @spec activate(
          reservation(),
          PreparedRun.t(),
          PublicationAuthority.t(),
          InstallationCatalog.t(),
          ProviderRuntimeServices.t()
        ) ::
          {:ok, execution()} | {:error, term()}
  def activate(
        reservation,
        prepared,
        authority,
        catalog,
        %ProviderRuntimeServices{provider_application_mode: :host_owned} = services
      ) do
    case ProviderExecution.new(catalog, services, []) do
      {:ok, execution} ->
        activate_execution(reservation, prepared, authority, execution)

      {:error, _} = error ->
        cancel(reservation)
        error
    end
  end

  def activate(reservation, _, _, _, _) do
    cancel(reservation)
    {:error, :invalid_provider_execution}
  end

  defp activate_execution({__MODULE__, host, ref} = reservation, prepared, authority, execution) do
    with {:ok, ticket} <- call(host, {:begin_activation, ref}) do
      case ExecutionSessionOwner.start_reserved(
             host,
             ref,
             ticket,
             prepared,
             authority,
             self(),
             execution
           ) do
        {:ok, owner} ->
          {:ok, {__MODULE__, self(), owner}}

        {:error, _} = error ->
          cancel(reservation)
          error
      end
    end
  end

  defp activate_execution(_, _, _, _), do: {:error, :run_admission_unavailable}

  @doc """
  Cancels or closes a reservation owned by the calling process.

  Use this after response commitment fails. Before transfer it releases the
  slot immediately. After transfer it requests execution-owner cancellation,
  retaining capacity until cleanup acknowledgement. Cancellation, expiry and
  caller death cannot release an active lease themselves. Repeated cancellation
  or use after completion returns `{:error, :run_admission_unavailable}`.
  Cancellation races with activation at the admission owner: cancellation
  before transfer prevents dispatch; after transfer execution may have begun.
  """
  @spec cancel(reservation()) :: :ok | {:error, :run_admission_unavailable}
  def cancel({__MODULE__, host, ref}), do: call(host, {:cancel, ref})
  def cancel(_), do: {:error, :run_admission_unavailable}

  @doc "Closes a reservation with the same ownership and cancellation semantics as cancel/1."
  @spec close(reservation()) :: :ok | {:error, :run_admission_unavailable}
  def close(reservation), do: cancel(reservation)

  @doc "Waits for the activated execution's sealed outcome and execution-owner cleanup."
  @spec await(execution()) :: {:ok, ExecutionOutcome.t()} | {:error, term()}
  def await({__MODULE__, caller, owner}) when caller == self(), do: await_execution(owner)
  def await(_), do: {:error, :execution_session_unavailable}

  @doc false
  @spec reservation_snapshot(reservation()) :: {:ok, snapshot()} | {:error, atom()}
  def reservation_snapshot({__MODULE__, host, _}), do: snapshot(host)

  @doc false
  @spec retain_publication(reservation()) :: :ok | {:error, atom()}
  def retain_publication({__MODULE__, host, ref}), do: call(host, {:retain_publication, ref})

  @doc false
  @spec finish_publication(reservation(), boolean()) :: :ok | {:error, atom()}
  def finish_publication({__MODULE__, host, ref}, clean?),
    do: call(host, {:finish_publication, ref, clean?})

  @doc false
  def transfer(host, ref, ticket, caller), do: call(host, {:transfer, ref, ticket, caller})

  @type snapshot :: %{
          capacity: pos_integer(),
          in_use: non_neg_integer(),
          status: :ready | :unavailable
        }

  @doc false
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  @doc "Starts one admission domain; only `:max_concurrent_runs` is accepted."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) == [:max_concurrent_runs] and
         is_integer(opts[:max_concurrent_runs]) and opts[:max_concurrent_runs] > 0 do
      GenServer.start_link(__MODULE__, opts[:max_concurrent_runs])
    else
      {:error, :invalid_run_admission}
    end
  end

  def start_link(_), do: {:error, :invalid_run_admission}

  @doc "Executes one provider-free preparation and waits for execution-owner cleanup."
  @spec execute(pid(), PreparedRun.t(), PublicationAuthority.t()) ::
          {:ok, ExecutionOutcome.t()} | {:error, term()}
  def execute(host, prepared, authority), do: do_execute(host, prepared, authority, nil)

  @doc "Executes one preparation using its bound catalog and host-owned runtime services."
  @spec execute(
          pid(),
          PreparedRun.t(),
          PublicationAuthority.t(),
          InstallationCatalog.t(),
          ProviderRuntimeServices.t()
        ) ::
          {:ok, ExecutionOutcome.t()} | {:error, term()}
  def execute(
        host,
        prepared,
        authority,
        catalog,
        %ProviderRuntimeServices{provider_application_mode: :host_owned} = services
      ) do
    with {:ok, execution} <- ProviderExecution.new(catalog, services, []) do
      do_execute(host, prepared, authority, execution)
    end
  end

  def execute(_, _, _, _, _), do: {:error, :invalid_provider_execution}

  defp do_execute(host, prepared, authority, execution) when is_pid(host) do
    with {:ok, owner} <-
           ExecutionSessionOwner.start_admitted(host, prepared, authority, self(), execution) do
      await_execution(owner)
    end
  end

  defp do_execute(_, _, _, _), do: {:error, :invalid_run_admission}

  defp await_execution(owner) do
    ref = Process.monitor(ExecutionSessionOwner.pid(owner))
    result = ExecutionSessionOwner.await(owner)

    receive do
      {:DOWN, ^ref, :process, _, :normal} ->
        result

      {:DOWN, ^ref, :process, _, :run_admission_unavailable} ->
        {:error, :run_admission_unavailable}

      {:DOWN, ^ref, :process, _, _} ->
        {:error, :execution_session_unavailable}
    end
  end

  @doc "Returns counts and readiness without exposing requests or provider configuration."
  @spec snapshot(pid()) :: {:ok, snapshot()} | {:error, :run_admission_unavailable}
  def snapshot(host), do: call(host, :snapshot)

  @doc false
  @spec admit(pid()) :: :ok | {:error, atom()}
  def admit(host), do: call(host, :admit)

  @doc false
  @spec complete(pid(), boolean()) :: :ok | {:error, atom()}
  def complete(host, clean?), do: call(host, {:complete, clean?})

  @impl true
  def init(capacity),
    do: {:ok, %{capacity: capacity, owners: %{}, reservations: %{}, status: :ready}}

  @impl true
  def handle_call(:snapshot, _, state) do
    state = fence_dead_owners(state)

    {:reply, {:ok, %{capacity: state.capacity, in_use: in_use(state), status: state.status}},
     state}
  end

  def handle_call({:reserve, deadline}, {caller, _}, state) do
    state = fence_dead_owners(state)

    cond do
      state.status == :unavailable or not deadline_live?(deadline) or not Process.alive?(caller) ->
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
          publication: :none
        }

        {:reply, {:ok, {__MODULE__, self(), ref}},
         %{state | reservations: Map.put(state.reservations, ref, reservation)}}
    end
  end

  def handle_call({:retain_publication, ref}, {caller, _}, state) do
    case state.reservations[ref] do
      %{caller: ^caller, owner: nil, ticket: nil, publication: :none} = reservation ->
        {:reply, :ok, put_reservation(state, ref, %{reservation | publication: :pending})}

      _ ->
        {:reply, {:error, :run_admission_unavailable}, state}
    end
  end

  def handle_call({:finish_publication, ref, clean?}, {caller, _}, state)
      when is_boolean(clean?) do
    case state.reservations[ref] do
      %{caller: ^caller, owner: nil, publication: publication} = reservation
      when publication in [:held, :pending] ->
        reply = if reservation.cancelled?, do: {:error, :call_cancelled}, else: :ok
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

  def handle_call({:begin_activation, ref}, {caller, _}, state) do
    state = fence_dead_owners(state)

    case state.reservations[ref] do
      %{caller: ^caller, owner: nil, ticket: nil} = reservation ->
        if state.status == :ready and deadline_live?(reservation.deadline) and
             Process.alive?(caller) and not reservation.cancelled? do
          ticket = make_ref()
          {:reply, {:ok, ticket}, put_reservation(state, ref, %{reservation | ticket: ticket})}
        else
          {:reply, {:error, :run_admission_unavailable}, cancel_reservation(state, ref)}
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
          {:reply, {:error, :run_admission_unavailable}, cancel_reservation(state, ref)}
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

  def handle_call(:admit, {owner, _}, state) do
    state = fence_dead_owners(state)

    cond do
      Map.has_key?(state.owners, owner) or not Process.alive?(owner) ->
        {:reply, {:error, :run_admission_unavailable}, state}

      state.status == :unavailable ->
        {:reply, {:error, :run_admission_unavailable}, state}

      in_use(state) >= state.capacity ->
        {:reply, {:error, :run_capacity_exhausted}, state}

      true ->
        {:reply, :ok, %{state | owners: Map.put(state.owners, owner, Process.monitor(owner))}}
    end
  end

  def handle_call({:complete, clean?}, {owner, _}, state) when is_boolean(clean?) do
    case Map.pop(state.owners, owner) do
      {nil, _} ->
        {:reply, {:error, :run_admission_unavailable}, state}

      {ref, owners} ->
        Process.demonitor(ref, [:flush])

        {:reply, :ok,
         %{
           complete_owner_reservation(state, owner, clean?)
           | owners: owners,
             status: if(clean?, do: state.status, else: :unavailable)
         }}
    end
  end

  def handle_call(_, _, state), do: {:reply, {:error, :run_admission_unavailable}, state}

  @impl true
  def handle_info({:DOWN, ref, :process, owner, _}, state) do
    if state.owners[owner] == ref do
      {:noreply,
       %{
         drop_owner_reservation(state, owner)
         | owners: Map.delete(state.owners, owner),
           status: :unavailable
       }}
    else
      next =
        Enum.reduce(state.reservations, state, fn
          {key, %{monitor: ^ref, caller: ^owner}}, acc -> cancel_reservation(acc, key)
          _, acc -> acc
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

  defp cancel_reservation(state, ref) do
    case state.reservations[ref] do
      nil ->
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

  defp drop_reservation(state, ref) do
    {reservation, reservations} = Map.pop(state.reservations, ref)
    if reservation.monitor, do: Process.demonitor(reservation.monitor, [:flush])
    if reservation.timer, do: Process.cancel_timer(reservation.timer)
    %{state | reservations: reservations}
  end

  defp complete_owner_reservation(state, owner, clean?) do
    Enum.reduce(state.reservations, state, fn
      {ref, %{owner: ^owner, publication: :pending} = reservation}, acc when clean? ->
        put_reservation(acc, ref, %{
          reservation
          | owner: nil,
            publication: :held,
            monitor: Process.monitor(reservation.caller)
        })

      {ref, %{owner: ^owner}}, acc ->
        drop_reservation(acc, ref)

      _, acc ->
        acc
    end)
  end

  defp drop_owner_reservation(state, owner) do
    Enum.reduce(state.reservations, state, fn
      {ref, %{owner: ^owner}}, acc -> drop_reservation(acc, ref)
      _, acc -> acc
    end)
  end

  defp fence_dead_owners(state) do
    state =
      Enum.reduce(state.reservations, state, fn {ref, reservation}, acc ->
        if not deadline_live?(reservation.deadline) or
             (is_nil(reservation.owner) and not Process.alive?(reservation.caller)),
           do: cancel_reservation(acc, ref),
           else: acc
      end)

    if Enum.any?(state.owners, fn {pid, _} -> not Process.alive?(pid) end),
      do: %{state | status: :unavailable},
      else: state
  end

  defp call(host, request) when is_pid(host) do
    GenServer.call(host, request, :infinity)
  catch
    :exit, _ -> {:error, :run_admission_unavailable}
  end

  defp call(_, _), do: {:error, :run_admission_unavailable}
end
