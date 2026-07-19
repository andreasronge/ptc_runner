defmodule PtcRunner.Kernel.RunState do
  @moduledoc """
  Internal single owner of mutable per-run resource state.

  One GenServer owns the deadline, open/closed status, workflow and mission
  capability counters, live provider-task count, protocol errors, subordinate
  evaluation count, terminal failure, evaluation-continuation lease, and
  committed native evaluation memory/history.

  Reservations and commits are deliberately atomic owner operations. Callers
  must not recreate them as separate read and update steps. The opaque token
  prevents messages that did not originate through the returned handle from
  mutating state. The process monitors the run owner and automatically exits
  with it.

  Each capability reservation also monitors the dispatching process. If that
  process dies mid-call (heap kill, timeout kill), the reservation is
  reclaimed only after the attached provider process has been killed and its
  `:DOWN` observed. Thus connector cleanup cannot begin while a callback from
  that run remains live. Shutdown — owner death or explicit stop — likewise
  kills and drains every still-attached provider before state terminates. A
  process holds at most one reservation at a time: dispatch is sequential per
  process, so a second reserve while one is active is a protocol violation and
  is rejected rather than silently replacing the tracked reservation.
  """
  use GenServer

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Lisp.RetainedSize

  @history_depth 3

  @enforce_keys [:pid, :token]
  defstruct [:pid, :token]

  @type environment :: :workflow | :mission
  @type t :: %__MODULE__{pid: pid(), token: reference()}

  @spec start(Limits.t(), keyword()) :: {:ok, t()}
  @doc "Starts run state with a deadline beginning at construction time."
  def start(%Limits{} = limits, opts \\ []) do
    token = make_ref()
    owner = Keyword.get(opts, :owner, self())
    {:ok, pid} = GenServer.start(__MODULE__, {limits, token, owner})
    {:ok, %__MODULE__{pid: pid, token: token}}
  end

  @spec reserve_capability(t(), environment(), binary()) :: :ok | {:error, atom()}
  @doc "Atomically reserves environment, per-name, and live-provider budgets."
  def reserve_capability(state, environment, name),
    do: call(state, {:reserve_capability, environment, name})

  @spec attach_provider(t(), pid()) :: :ok | {:error, :closed}
  @doc "Attaches the caller's live provider process to its capability reservation."
  def attach_provider(state, provider) when is_pid(provider),
    do: call(state, {:attach_provider, provider})

  @spec release_provider_slot(t()) :: :ok | {:error, :closed}
  @doc "Releases the caller's live provider slot without accepting a result."
  def release_provider_slot(state), do: call(state, :release_provider_slot)

  @spec finish_provider(t()) :: :ok | {:error, :run_closed}
  @doc "Releases a provider slot and accepts completion only while the run is open."
  def finish_provider(state), do: call(state, :finish_provider)

  @spec reserve_evaluation(t()) :: {:ok, map(), [term()], reference()} | {:error, atom()}
  @doc "Atomically reserves and returns native subordinate memory and turn history."
  def reserve_evaluation(state), do: call(state, :reserve_evaluation)

  @spec commit_evaluation(t(), reference(), map(), [term()]) :: :ok | {:error, atom()}
  @doc "Atomically commits one bounded native memory/history continuation candidate."
  def commit_evaluation(state, lease, memory, history)
      when is_map(memory) and is_list(history),
      do: call(state, {:commit_evaluation, lease, memory, history})

  @spec release_evaluation(t(), reference()) :: :ok | {:error, atom()}
  @doc "Releases the caller's evaluation lease without changing committed memory."
  def release_evaluation(state, lease), do: call(state, {:release_evaluation, lease})

  @spec protocol_error(t()) :: :ok | {:error, :protocol_error_limit}
  @doc "Records one protocol error and closes the run when its ceiling is exceeded."
  def protocol_error(state), do: call(state, :protocol_error)

  @spec fail(t(), atom(), atom()) :: :ok
  @doc "Records the first terminal failure and closes the run."
  def fail(state, kind, reason), do: call(state, {:fail, kind, reason})

  @spec terminal_failure(t()) :: nil | %{kind: atom(), reason: atom()}
  @doc "Returns the first terminal failure, if any."
  def terminal_failure(state), do: call(state, :terminal_failure)

  @spec close(t()) :: :ok
  @doc "Closes the run against further reservations and result commits."
  def close(state), do: call(state, :close)

  @spec stop(t()) :: :ok
  @doc "Stops the owner process after the run has closed."
  def stop(state), do: GenServer.stop(state.pid, :normal)

  @spec usage(t()) :: map()
  @doc "Returns a read-only bounded usage snapshot."
  def usage(state), do: call(state, :usage)

  @spec limits(t()) :: Limits.t()
  @doc "Returns the normalized limits owned by this run."
  def limits(state), do: call(state, :limits)

  @spec remaining_ms(t()) :: non_neg_integer()
  @doc "Returns non-negative wall time remaining before the run deadline."
  def remaining_ms(state), do: usage(state).remaining_ms

  @spec open?(t()) :: boolean()
  @doc "Returns whether the run is open and its deadline has not elapsed."
  def open?(state), do: call(state, :open?)

  @spec evaluation_memory_summary(t()) :: map()
  @doc "Returns bounded definition, history, and retained continuation byte counts."
  def evaluation_memory_summary(state), do: call(state, :evaluation_memory_summary)

  @impl GenServer
  def init({limits, token, owner}) do
    now = System.monotonic_time(:millisecond)

    {:ok,
     %{
       token: token,
       owner_ref: Process.monitor(owner),
       limits: limits,
       deadline_ms: now + limits.run_duration_ms,
       closed?: false,
       provider_tasks: 0,
       calls: %{workflow: %{}, mission: %{}},
       totals: %{workflow: 0, mission: 0},
       evaluations: 0,
       protocol_errors: 0,
       terminal_failure: nil,
       memory: %{},
       history: [],
       evaluation_lease: nil,
       reservations: %{}
     }}
  end

  @impl GenServer
  def handle_call(
        {token, {:reserve_capability, environment, name}},
        {caller, _tag},
        %{token: token} = state
      )
      when environment in [:workflow, :mission] do
    case reserve_capability_state(state, environment, name, caller) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({token, {:attach_provider, provider}}, {caller, _tag}, %{token: token} = state) do
    case state.reservations do
      %{^caller => reservation} ->
        reservation =
          reservation
          |> Map.put(:provider, provider)
          |> Map.put(:provider_ref, Process.monitor(provider))

        reservations = Map.put(state.reservations, caller, reservation)
        {:reply, :ok, %{state | reservations: reservations}}

      _ ->
        Process.exit(provider, :kill)
        {:reply, {:error, :closed}, state}
    end
  end

  def handle_call({token, :release_provider_slot}, {caller, _tag}, %{token: token} = state) do
    {:reply, :ok, release_reservation(state, caller)}
  end

  def handle_call({token, :finish_provider}, {caller, _tag}, %{token: token} = state) do
    state = release_reservation(state, caller)
    reply = if unavailable?(state), do: {:error, :run_closed}, else: :ok
    {:reply, reply, state}
  end

  def handle_call({token, :reserve_evaluation}, {caller, _tag}, %{token: token} = state) do
    cond do
      unavailable?(state) ->
        {:reply, {:error, :run_closed}, state}

      state.evaluation_lease != nil ->
        {:reply, {:error, :busy}, state}

      state.evaluations >= state.limits.subordinate_evaluations ->
        {:reply, {:error, :limit_exceeded}, state}

      true ->
        lease = {make_ref(), caller, Process.monitor(caller)}

        {:reply, {:ok, state.memory, state.history, elem(lease, 0)},
         %{state | evaluations: state.evaluations + 1, evaluation_lease: lease}}
    end
  end

  def handle_call(
        {token, {:commit_evaluation, lease, memory, history}},
        {caller, _tag},
        %{token: token} = state
      ) do
    case state.evaluation_lease do
      {^lease, ^caller, monitor_ref} ->
        Process.demonitor(monitor_ref, [:flush])

        memory_bytes =
          RetainedSize.bytes_with_cap(memory, state.limits.evaluation_memory_bytes)

        history_bytes =
          RetainedSize.bytes_with_cap(history, state.limits.evaluation_history_bytes)

        history_values_valid? =
          length(history) <= @history_depth and
            Enum.all?(history, fn value ->
              case RetainedSize.bytes_with_cap(value, state.limits.evaluation_history_bytes) do
                bytes when is_integer(bytes) ->
                  bytes <= state.limits.evaluation_history_bytes

                _ ->
                  false
              end
            end)

        cond do
          unavailable?(state) ->
            {:reply, {:error, :run_closed}, %{state | evaluation_lease: nil}}

          not (is_integer(memory_bytes) and
                   memory_bytes <= state.limits.evaluation_memory_bytes) ->
            {:reply, {:error, :memory_exceeded}, %{state | evaluation_lease: nil}}

          not (history_values_valid? and is_integer(history_bytes) and
                   history_bytes <= state.limits.evaluation_history_bytes) ->
            {:reply, {:error, :history_exceeded}, %{state | evaluation_lease: nil}}

          true ->
            {:reply, :ok, %{state | memory: memory, history: history, evaluation_lease: nil}}
        end

      _ ->
        {:reply, {:error, :stale_lease}, state}
    end
  end

  def handle_call({token, {:release_evaluation, lease}}, {caller, _tag}, %{token: token} = state) do
    case state.evaluation_lease do
      {^lease, ^caller, monitor_ref} ->
        Process.demonitor(monitor_ref, [:flush])
        {:reply, :ok, %{state | evaluation_lease: nil}}

      _ ->
        {:reply, {:error, :stale_lease}, state}
    end
  end

  def handle_call({token, :protocol_error}, _from, %{token: token} = state) do
    next = state.protocol_errors + 1
    reply = if next > state.limits.protocol_errors, do: {:error, :protocol_error_limit}, else: :ok

    state =
      if reply == :ok do
        %{state | protocol_errors: next}
      else
        %{
          state
          | protocol_errors: next,
            closed?: true,
            terminal_failure: %{kind: :limit_exceeded, reason: :protocol_errors}
        }
      end

    {:reply, reply, state}
  end

  def handle_call({token, {:fail, kind, reason}}, _from, %{token: token} = state)
      when is_atom(kind) and is_atom(reason) do
    failure = state.terminal_failure || %{kind: kind, reason: reason}
    {:reply, :ok, %{state | closed?: true, terminal_failure: failure}}
  end

  def handle_call({token, :terminal_failure}, _from, %{token: token} = state),
    do: {:reply, state.terminal_failure, state}

  def handle_call({token, :close}, _from, %{token: token} = state),
    do: {:reply, :ok, %{state | closed?: true}}

  def handle_call({token, :usage}, _from, %{token: token} = state),
    do: {:reply, usage_projection(state), state}

  def handle_call({token, :limits}, _from, %{token: token} = state),
    do: {:reply, state.limits, state}

  def handle_call({token, :open?}, _from, %{token: token} = state),
    do: {:reply, not unavailable?(state), state}

  def handle_call({token, :evaluation_memory_summary}, _from, %{token: token} = state),
    do: {:reply, continuation_summary(state), state}

  def handle_call(_request, _from, state), do: {:reply, {:error, :closed}, state}

  @impl GenServer
  def handle_cast(_request, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{evaluation_lease: {_lease, _caller, ref}} = state
      ),
      do: {:noreply, %{state | evaluation_lease: nil}}

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case state.reservations do
      %{^pid => %{caller_ref: ^ref, provider: provider} = reservation} ->
        if is_pid(provider) do
          Process.exit(provider, :kill)
          reservations = Map.put(state.reservations, pid, %{reservation | caller_ref: nil})
          {:noreply, %{state | reservations: reservations}}
        else
          {:noreply, release_reservation(state, pid)}
        end

      _ ->
        case reservation_by_provider_ref(state.reservations, ref) do
          {caller, %{caller_ref: nil}} ->
            {:noreply, release_reservation(state, caller)}

          {caller, reservation} ->
            reservation = %{reservation | provider: nil, provider_ref: nil}
            {:noreply, put_in(state.reservations[caller], reservation)}

          nil ->
            {:noreply, state}
        end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
    @impl GenServer
    def format_status(status), do: redact_status(status)
  else
    def format_status(status), do: redact_status(status)
  end

  @impl GenServer
  def format_status(_reason, _status), do: [data: [{~c"State", :redacted}]]

  @impl GenServer
  def terminate(_reason, state) do
    state.reservations
    |> Enum.flat_map(fn
      {_caller, %{provider: provider}} when is_pid(provider) -> [provider]
      _reservation -> []
    end)
    |> Enum.uniq()
    |> kill_and_drain()
  end

  defp kill_and_drain(providers) do
    refs = Map.new(providers, fn provider -> {Process.monitor(provider), provider} end)
    Enum.each(providers, &Process.exit(&1, :kill))
    drain_providers(refs)
  end

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end

  defp drain_providers(refs) when map_size(refs) == 0, do: :ok

  defp drain_providers(refs) do
    receive do
      {:DOWN, ref, :process, _pid, _reason} -> drain_providers(Map.delete(refs, ref))
    after
      1_000 ->
        Enum.each(Map.keys(refs), &Process.demonitor(&1, [:flush]))
        :ok
    end
  end

  defp reserve_capability_state(state, environment, name, caller) do
    {limit_total, limit_name} = capability_limits(state.limits, environment)
    count = get_in(state.calls, [environment, name]) || 0

    cond do
      unavailable?(state) ->
        {:error, :run_closed, state}

      state.provider_tasks >= state.limits.live_provider_tasks ->
        {:error, :live_task_limit, state}

      Map.fetch!(state.totals, environment) >= limit_total or count >= limit_name ->
        {:error, :limit_exceeded, state}

      Map.has_key?(state.reservations, caller) ->
        {:error, :reservation_held, state}

      true ->
        reservation = %{
          caller_ref: Process.monitor(caller),
          provider: nil,
          provider_ref: nil
        }

        state =
          state
          |> update_in([:calls, environment], &Map.put(&1, name, count + 1))
          |> update_in([:totals, environment], &(&1 + 1))

        {:ok,
         %{
           state
           | provider_tasks: state.provider_tasks + 1,
             reservations: Map.put(state.reservations, caller, reservation)
         }}
    end
  end

  # Drops the caller's reservation only after its provider is known to be down.
  defp release_reservation(state, caller) do
    {reservation, reservations} = Map.pop(state.reservations, caller)

    case reservation do
      %{caller_ref: caller_ref, provider_ref: provider_ref} ->
        if is_reference(caller_ref), do: Process.demonitor(caller_ref, [:flush])
        if is_reference(provider_ref), do: Process.demonitor(provider_ref, [:flush])

      nil ->
        :ok
    end

    if reservation do
      %{state | provider_tasks: max(state.provider_tasks - 1, 0), reservations: reservations}
    else
      state
    end
  end

  defp reservation_by_provider_ref(reservations, ref) do
    Enum.find_value(reservations, fn {caller, reservation} ->
      if reservation.provider_ref == ref, do: {caller, reservation}
    end)
  end

  defp unavailable?(state),
    do: state.closed? or System.monotonic_time(:millisecond) >= state.deadline_ms

  defp capability_limits(limits, :workflow),
    do: {limits.workflow_capability_calls, limits.workflow_capability_calls_per_name}

  defp capability_limits(limits, :mission),
    do: {limits.mission_capability_calls, limits.mission_capability_calls_per_name}

  defp usage_projection(state) do
    %{
      closed?: state.closed?,
      remaining_ms: max(state.deadline_ms - System.monotonic_time(:millisecond), 0),
      capability_calls: state.calls,
      subordinate_evaluations: state.evaluations,
      protocol_errors: state.protocol_errors,
      evaluation_memory_bytes:
        RetainedSize.bytes_with_cap(state.memory, state.limits.evaluation_memory_bytes),
      evaluation_history_bytes:
        RetainedSize.bytes_with_cap(state.history, state.limits.evaluation_history_bytes),
      evaluation_continuation_bytes: continuation_bytes(state),
      evaluation_busy?: not is_nil(state.evaluation_lease)
    }
  end

  defp continuation_summary(state) do
    memory_bytes =
      RetainedSize.bytes_with_cap(state.memory, state.limits.evaluation_memory_bytes)

    history_bytes =
      RetainedSize.bytes_with_cap(state.history, state.limits.evaluation_history_bytes)

    %{
      defined_count: map_size(state.memory),
      history_count: length(state.history),
      memory_bytes: memory_bytes,
      history_bytes: history_bytes,
      bytes: sum_retained_bytes(memory_bytes, history_bytes)
    }
  end

  defp continuation_bytes(state) do
    summary = continuation_summary(state)
    summary.bytes
  end

  defp sum_retained_bytes(left, right) when is_integer(left) and is_integer(right),
    do: left + right

  defp sum_retained_bytes(_left, _right), do: :oversized

  defp call(%__MODULE__{pid: pid, token: token}, request),
    do: GenServer.call(pid, {token, request})
end
