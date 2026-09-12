defmodule PtcRunner.Kernel.ProviderCallAdmission do
  @moduledoc """
  Explicit host-owned admission for aggregate live LLM requester calls.

  A host starts one domain for every provider transport shared by its hosted
  runtimes and passes the returned opaque handle through
  `PtcRunner.Kernel.ProviderRuntimeServices`. A slot covers the complete
  requester invocation, including sequential adapter retries, until its bound
  guardian proves completion or cancellation and drain.

  This owner is not a VM singleton. Command-owned one-shot runtimes, replay,
  direct `PtcRunner.LLM` calls, embeddings, and custom requesters which bypass
  runtime services are outside its guarantee and remain the host's
  responsibility to bound.

  Saturation is healthy. Cleanup uncertainty, an active guardian's death, or a
  lease protocol fault fences the domain. Its temporary child specification
  prevents capacity from resetting underneath surviving transport work.
  """

  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction

  @limit 65_535
  alias PtcRunner.Kernel.ProviderCallAdmission.Lease
  alias PtcRunner.Kernel.ProviderCallAdmission.Ticket

  @opaque t :: pid()
  @typep atomics_ref :: :atomics.atomics_ref()

  @type snapshot :: %{
          capacity: pos_integer(),
          active: non_neg_integer(),
          waiting: non_neg_integer(),
          status: :ready | :unavailable
        }

  @doc false
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  @doc "Starts one admission domain with a closed active and waiter capacity."
  @spec start_link(keyword()) :: GenServer.on_start() | {:error, :invalid_provider_call_admission}
  def start_link(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         [:max_active_calls, :max_waiters] <- opts |> Keyword.keys() |> Enum.sort(),
         active when active in 1..@limit <- opts[:max_active_calls],
         waiting when waiting in 0..@limit <- opts[:max_waiters] do
      GenServer.start_link(__MODULE__, {active, waiting})
    else
      _ -> {:error, :invalid_provider_call_admission}
    end
  end

  def start_link(_opts), do: {:error, :invalid_provider_call_admission}

  @doc "Claims admission for the calling guardian until the absolute monotonic deadline."
  @spec checkout(t(), integer()) ::
          {:ok, Lease.t()}
          | {:error,
             :provider_capacity_exhausted
             | :provider_admission_timeout
             | :provider_admission_unavailable}
  def checkout(admission, absolute_deadline_ms)
      when is_pid(admission) and is_integer(absolute_deadline_ms) do
    checkout_for(admission, self(), absolute_deadline_ms)
  end

  def checkout(_admission, _deadline), do: {:error, :provider_admission_unavailable}

  @doc false
  @spec checkout_for(t(), pid(), integer()) ::
          {:ok, Lease.t()}
          | {:error,
             :provider_capacity_exhausted
             | :provider_admission_timeout
             | :provider_admission_unavailable}
  def checkout_for(admission, guardian, absolute_deadline_ms)
      when is_pid(admission) and is_pid(guardian) and is_integer(absolute_deadline_ms) do
    now = System.monotonic_time(:millisecond)

    if absolute_deadline_ms <= now do
      {:error, :provider_admission_timeout}
    else
      with {:ok, token, tickets, ticket_limit} <- domain(admission),
           true <- claim_ticket(tickets, ticket_limit) do
        ticket = Ticket.new()

        call(
          admission,
          token,
          {:checkout, guardian, absolute_deadline_ms, ticket},
          {tickets, ticket}
        )
      else
        false -> {:error, :provider_capacity_exhausted}
        _ -> {:error, :provider_admission_unavailable}
      end
    end
  end

  def checkout_for(_admission, _guardian, _deadline),
    do: {:error, :provider_admission_unavailable}

  @doc false
  def begin_checkout(admission, absolute_deadline_ms)
      when is_pid(admission) and is_integer(absolute_deadline_ms) do
    now = now_ms()

    if absolute_deadline_ms <= now do
      {:error, :provider_admission_timeout}
    else
      with {:ok, token, tickets, ticket_limit} <- domain(admission),
           true <- claim_ticket(tickets, ticket_limit) do
        ticket = Ticket.new()
        request_ref = make_ref()

        send(
          admission,
          {token, {:checkout_async, self(), absolute_deadline_ms, ticket, request_ref}}
        )

        {:ok, request_ref}
      else
        false -> {:error, :provider_capacity_exhausted}
        _ -> {:error, :provider_admission_unavailable}
      end
    end
  end

  def begin_checkout(_admission, _deadline), do: {:error, :provider_admission_unavailable}

  @doc false
  def cancel_checkout(admission, request_ref)
      when is_pid(admission) and is_reference(request_ref) do
    case domain(admission) do
      {:ok, token, _tickets, _limit} ->
        send(admission, {token, {:cancel_checkout, self(), request_ref}})

      :error ->
        :ok
    end

    :ok
  end

  @doc "Consumes a single-use lease on behalf of its bound guardian."
  @spec complete(Lease.t(), :completed | :cancelled | :uncertain) ::
          :ok
          | {:error,
             :provider_cleanup_failed
             | :duplicate_completion
             | :invalid_lease
             | :not_lease_owner
             | :provider_admission_unavailable}
  def complete(%Lease{admission: admission, owner: owner} = lease, status)
      when is_pid(admission) and
             status in [:completed, :cancelled, :uncertain] do
    cond do
      owner != self() ->
        call(admission, lease_token(lease), {:fault, :not_lease_owner}, nil)

      not claim_completion(lease.completion) ->
        call(admission, lease_token(lease), {:fault, :duplicate_completion}, nil)

      true ->
        complete_call(admission, lease_token(lease), lease.reference, status)
    end
  end

  def complete(%Lease{admission: admission} = lease, _status) when is_pid(admission),
    do: call(admission, lease_token(lease), {:fault, :invalid_lease}, nil)

  def complete(_lease, _status), do: {:error, :invalid_lease}

  @doc "Returns bounded capacity health without exposing calls or leases."
  @spec snapshot(t()) :: {:ok, snapshot()} | {:error, :provider_admission_unavailable}
  def snapshot(admission) when is_pid(admission) do
    case domain(admission) do
      {:ok, token, _tickets, _limit} -> call(admission, token, :snapshot, nil)
      :error -> {:error, :provider_admission_unavailable}
    end
  end

  def snapshot(_admission), do: {:error, :provider_admission_unavailable}

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(admission) when is_pid(admission) do
    case domain(admission) do
      {:ok, token, _tickets, _limit} -> call(admission, token, :valid, nil) == :ok
      :error -> false
    end
  end

  def valid?(_), do: false

  @impl true
  def init({capacity, max_waiters}) do
    token = make_ref()
    tickets = :atomics.new(1, signed: false)
    :persistent_term.put({__MODULE__, self()}, {token, tickets, capacity + max_waiters})
    watch_persistent_handle(self())

    {:ok,
     %{
       token: token,
       tickets: tickets,
       capacity: capacity,
       max_waiters: max_waiters,
       active: %{},
       waiting: :queue.new(),
       waiting_by_ref: %{},
       status: :ready
     }}
  end

  @impl true
  def handle_call({token, :valid}, _from, %{token: token} = state), do: {:reply, :ok, state}

  def handle_call({token, :snapshot}, _from, %{token: token} = state) do
    {:reply,
     {:ok,
      %{
        capacity: state.capacity,
        active: map_size(state.active),
        waiting: map_size(state.waiting_by_ref),
        status: state.status
      }}, state}
  end

  def handle_call({token, {:checkout, owner, deadline, ticket}}, from, %{token: token} = state)
      when is_struct(ticket, Ticket) do
    cond do
      state.status == :unavailable or not Process.alive?(owner) ->
        release_ticket(state, ticket)
        {:reply, {:error, :provider_admission_unavailable}, state}

      deadline <= now_ms() ->
        release_ticket(state, ticket)
        {:reply, {:error, :provider_admission_timeout}, state}

      map_size(state.active) < state.capacity and :queue.is_empty(state.waiting) ->
        release_ticket(state, ticket)
        {lease, state} = grant(owner, state)
        {:reply, {:ok, lease}, state}

      map_size(state.waiting_by_ref) >= state.max_waiters ->
        release_ticket(state, ticket)
        {:reply, {:error, :provider_capacity_exhausted}, state}

      true ->
        request_ref = make_ref()
        monitor = Process.monitor(owner)
        caller_monitor = Process.monitor(elem(from, 0))
        timer = Process.send_after(self(), {:expire, request_ref}, max(deadline - now_ms(), 1))

        entry = %{
          from: from,
          owner: owner,
          monitor: monitor,
          caller_monitor: caller_monitor,
          timer: timer,
          deadline: deadline,
          ticket: ticket
        }

        {:noreply,
         %{
           state
           | waiting: :queue.in(request_ref, state.waiting),
             waiting_by_ref: Map.put(state.waiting_by_ref, request_ref, entry)
         }}
    end
  end

  def handle_call({token, {:complete, lease_ref, status}}, {owner, _}, %{token: token} = state) do
    case state.active[lease_ref] do
      %{owner: ^owner} when state.status == :unavailable ->
        {:reply, {:error, :provider_admission_unavailable}, state}

      %{owner: ^owner} = active when state.status == :ready ->
        case status do
          :uncertain ->
            Process.demonitor(active.monitor, [:flush])
            state = %{state | active: Map.delete(state.active, lease_ref)}
            {:reply, {:error, :provider_cleanup_failed}, fence(state)}

          _settled ->
            receipt = make_ref()
            active = Map.put(active, :completion_receipt, receipt)
            {:reply, {:completion_ack, receipt}, put_in(state.active[lease_ref], active)}
        end

      %{owner: _other} ->
        {:reply, {:error, :not_lease_owner}, fence(state)}

      nil when state.status == :unavailable ->
        {:reply, {:error, :provider_admission_unavailable}, state}

      nil ->
        {:reply, {:error, :invalid_lease}, fence(state)}
    end
  end

  def handle_call({token, {:fault, fault}}, _from, %{token: token} = state)
      when fault in [:duplicate_completion, :invalid_lease, :not_lease_owner],
      do: {:reply, {:error, fault}, fence(state)}

  def handle_call(
        {token, {:completion_received, owner, lease_ref, receipt}},
        {owner, _},
        %{token: token} = state
      ) do
    case state.active[lease_ref] do
      %{owner: ^owner, completion_receipt: ^receipt} = active when state.status == :ready ->
        Process.demonitor(active.monitor, [:flush])
        state = %{state | active: Map.delete(state.active, lease_ref)}
        {state, replies} = promote(state)
        Enum.each(replies, fn {from, reply} -> reply_waiter(from, reply) end)
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :provider_admission_unavailable}, fence(state)}
    end
  end

  def handle_call(_request, _from, state),
    do: {:reply, {:error, :provider_admission_unavailable}, state}

  @impl true
  def handle_info(
        {token, {:checkout_async, owner, deadline, ticket, request_ref}},
        %{token: token} = state
      ) do
    {reply, state} = admit_async(owner, deadline, ticket, request_ref, state)
    if reply, do: send(owner, {:provider_admission_checkout, request_ref, reply})
    {:noreply, state}
  end

  def handle_info({token, {:cancel_checkout, owner, request_ref}}, %{token: token} = state) do
    case state.waiting_by_ref[request_ref] do
      %{owner: ^owner} = entry ->
        {_entry, state} = pop_waiter(state, request_ref)
        release_ticket(state, entry.ticket)

        send(
          owner,
          {:provider_admission_checkout, request_ref, {:error, :provider_admission_timeout}}
        )

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:expire, request_ref}, state) do
    case pop_waiter(state, request_ref) do
      {nil, state} ->
        {:noreply, state}

      {entry, state} ->
        release_ticket(state, entry.ticket)
        reply_waiter(entry.from, {:error, :provider_admission_timeout})
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    case active_by_monitor(state.active, monitor, owner) do
      {:ok, _lease_ref} ->
        {:noreply, fence(state)}

      :error ->
        case waiter_by_monitor(state.waiting_by_ref, monitor, owner) do
          {:ok, request_ref} ->
            {entry, state} = pop_waiter(state, request_ref)
            release_ticket(state, entry.ticket)
            {:noreply, state}

          :error ->
            {:noreply, state}
        end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    :persistent_term.erase({__MODULE__, self()})
    :ok
  end

  defp grant(owner, state) do
    lease_ref = make_ref()
    completion = :atomics.new(1, signed: false)
    monitor = Process.monitor(owner)

    lease = %Lease{
      admission: self(),
      reference: lease_ref,
      owner: owner,
      completion: completion
    }

    {lease,
     %{state | active: Map.put(state.active, lease_ref, %{owner: owner, monitor: monitor})}}
  end

  defp promote(%{status: :unavailable} = state), do: {state, []}

  defp promote(state) when map_size(state.active) >= state.capacity, do: {state, []}

  defp promote(state) do
    case :queue.out(state.waiting) do
      {:empty, _queue} ->
        {state, []}

      {{:value, request_ref}, queue} ->
        state = %{state | waiting: queue}

        case Map.pop(state.waiting_by_ref, request_ref) do
          {nil, waiting_by_ref} ->
            promote(%{state | waiting_by_ref: waiting_by_ref})

          {entry, waiting_by_ref} ->
            cancel_waiter_monitor(entry)
            release_ticket(state, entry.ticket)
            state = %{state | waiting_by_ref: waiting_by_ref}

            cond do
              entry.deadline <= now_ms() ->
                {state, replies} = promote(state)
                {state, [{entry.from, {:error, :provider_admission_timeout}} | replies]}

              not Process.alive?(entry.owner) ->
                promote(state)

              true ->
                {lease, state} = grant(entry.owner, state)
                {state, replies} = promote(state)
                {state, [{entry.from, {:ok, lease}} | replies]}
            end
        end
    end
  end

  defp pop_waiter(state, request_ref) do
    case Map.pop(state.waiting_by_ref, request_ref) do
      {nil, waiting_by_ref} ->
        {nil, %{state | waiting_by_ref: waiting_by_ref}}

      {entry, waiting_by_ref} ->
        cancel_waiter_monitor(entry)

        {entry,
         %{
           state
           | waiting_by_ref: waiting_by_ref,
             waiting: :queue.delete(request_ref, state.waiting)
         }}
    end
  end

  defp cancel_waiter_monitor(entry) do
    Process.demonitor(entry.monitor, [:flush])
    Process.demonitor(entry.caller_monitor, [:flush])
    Process.cancel_timer(entry.timer, async: true, info: false)
  end

  defp fence(%{status: :unavailable} = state), do: state

  defp fence(state) do
    Enum.each(state.waiting_by_ref, fn {_ref, entry} ->
      cancel_waiter_monitor(entry)
      release_ticket(state, entry.ticket)
      reply_waiter(entry.from, {:error, :provider_admission_unavailable})
    end)

    %{state | waiting: :queue.new(), waiting_by_ref: %{}, status: :unavailable}
  end

  defp active_by_monitor(active, monitor, owner) do
    Enum.find_value(active, :error, fn
      {lease_ref, %{monitor: ^monitor, owner: ^owner}} -> {:ok, lease_ref}
      _ -> nil
    end)
  end

  defp reply_waiter({:async, owner, request_ref}, reply),
    do: send(owner, {:provider_admission_checkout, request_ref, reply})

  defp reply_waiter(from, reply), do: GenServer.reply(from, reply)

  defp waiter_by_monitor(waiting, monitor, owner) do
    Enum.find_value(waiting, :error, fn
      {request_ref, %{monitor: ^monitor, owner: ^owner}} -> {:ok, request_ref}
      {request_ref, %{caller_monitor: ^monitor}} -> {:ok, request_ref}
      _ -> nil
    end)
  end

  defp admit_async(owner, deadline, ticket, request_ref, state) do
    cond do
      state.status == :unavailable or not Process.alive?(owner) ->
        release_ticket(state, ticket)
        {{:error, :provider_admission_unavailable}, state}

      deadline <= now_ms() ->
        release_ticket(state, ticket)
        {{:error, :provider_admission_timeout}, state}

      map_size(state.active) < state.capacity and :queue.is_empty(state.waiting) ->
        release_ticket(state, ticket)
        {lease, state} = grant(owner, state)
        {{:ok, lease}, state}

      map_size(state.waiting_by_ref) >= state.max_waiters ->
        release_ticket(state, ticket)
        {{:error, :provider_capacity_exhausted}, state}

      true ->
        monitor = Process.monitor(owner)
        timer = Process.send_after(self(), {:expire, request_ref}, max(deadline - now_ms(), 1))

        entry = %{
          from: {:async, owner, request_ref},
          owner: owner,
          monitor: monitor,
          caller_monitor: monitor,
          timer: timer,
          deadline: deadline,
          ticket: ticket
        }

        {nil,
         %{
           state
           | waiting: :queue.in(request_ref, state.waiting),
             waiting_by_ref: Map.put(state.waiting_by_ref, request_ref, entry)
         }}
    end
  end

  @spec claim_ticket(atomics_ref(), pos_integer()) :: boolean()
  defp claim_ticket(tickets, limit) do
    current = :atomics.get(tickets, 1)

    cond do
      current >= limit -> false
      :atomics.compare_exchange(tickets, 1, current, current + 1) == :ok -> true
      true -> claim_ticket(tickets, limit)
    end
  end

  @spec release_ticket(map(), term()) :: integer() | :ok
  defp release_ticket(state, ticket), do: release_ticket_once(state.tickets, ticket)

  @spec claim_completion(atomics_ref()) :: boolean()
  defp claim_completion(completion),
    do: :atomics.compare_exchange(completion, 1, 0, 1) == :ok

  defp call(admission, token, request, ticket_witness) do
    GenServer.call(admission, {token, request}, :infinity)
  catch
    :exit, _reason ->
      case ticket_witness do
        {tickets, ticket} -> release_ticket_once(tickets, ticket)
        _ -> :ok
      end

      {:error, :provider_admission_unavailable}
  end

  defp complete_call(admission, token, lease_ref, status) do
    case call(admission, token, {:complete, lease_ref, status}, nil) do
      {:completion_ack, receipt} ->
        call(
          admission,
          token,
          {:completion_received, self(), lease_ref, receipt},
          nil
        )

      result ->
        result
    end
  end

  @spec release_ticket_once(atomics_ref(), term()) :: integer() | :ok
  defp release_ticket_once(tickets, ticket) do
    Ticket.release(ticket, tickets)
  end

  @spec domain(t()) :: {:ok, reference(), atomics_ref(), pos_integer()} | :error
  defp domain(admission) do
    if Process.alive?(admission) do
      case :persistent_term.get({__MODULE__, admission}, nil) do
        {token, tickets, limit}
        when is_reference(token) and is_integer(limit) and limit > 0 ->
          {:ok, token, tickets, limit}

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp lease_token(%Lease{admission: admission}) do
    case domain(admission) do
      {:ok, token, _tickets, _limit} -> token
      _ -> make_ref()
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp watch_persistent_handle(admission) do
    spawn(fn ->
      monitor = Process.monitor(admission)

      receive do
        {:DOWN, ^monitor, :process, ^admission, _reason} ->
          :persistent_term.erase({__MODULE__, admission})
      end
    end)
  end
end
