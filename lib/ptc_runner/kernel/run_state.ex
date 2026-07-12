defmodule PtcRunner.Kernel.RunState do
  @moduledoc "The single owner of mutable per-run resource state."
  use GenServer

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Lisp.RetainedSize

  @enforce_keys [:pid, :token]
  defstruct [:pid, :token]

  @type environment :: :workflow | :mission
  @type t :: %__MODULE__{pid: pid(), token: reference()}

  @spec start(Limits.t(), keyword()) :: {:ok, t()}
  def start(%Limits{} = limits, opts \\ []) do
    token = make_ref()
    owner = Keyword.get(opts, :owner, self())
    {:ok, pid} = GenServer.start(__MODULE__, {limits, token, owner})
    {:ok, %__MODULE__{pid: pid, token: token}}
  end

  @spec reserve_capability(t(), environment(), binary()) :: :ok | {:error, atom()}
  def reserve_capability(state, environment, name),
    do: call(state, {:reserve_capability, environment, name})

  @spec release_provider_slot(t()) :: :ok | {:error, :closed}
  def release_provider_slot(state), do: call(state, :release_provider_slot)

  @spec finish_provider(t()) :: :ok | {:error, :run_closed}
  def finish_provider(state), do: call(state, :finish_provider)

  @spec reserve_evaluation(t()) :: {:ok, map(), reference()} | {:error, atom()}
  def reserve_evaluation(state), do: call(state, :reserve_evaluation)

  @spec commit_evaluation(t(), reference(), map()) :: :ok | {:error, atom()}
  def commit_evaluation(state, lease, memory) when is_map(memory),
    do: call(state, {:commit_evaluation, lease, memory})

  @spec release_evaluation(t(), reference()) :: :ok | {:error, atom()}
  def release_evaluation(state, lease), do: call(state, {:release_evaluation, lease})

  @spec protocol_error(t()) :: :ok | {:error, :protocol_error_limit}
  def protocol_error(state), do: call(state, :protocol_error)

  @spec close(t()) :: :ok
  def close(state), do: call(state, :close)

  @spec stop(t()) :: :ok
  def stop(state), do: GenServer.stop(state.pid, :normal)

  @spec usage(t()) :: map()
  def usage(state), do: call(state, :usage)

  @spec limits(t()) :: Limits.t()
  def limits(state), do: call(state, :limits)

  @spec remaining_ms(t()) :: non_neg_integer()
  def remaining_ms(state), do: usage(state).remaining_ms

  @spec open?(t()) :: boolean()
  def open?(state), do: call(state, :open?)

  @spec evaluation_memory_summary(t()) :: map()
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
       memory: %{},
       evaluation_lease: nil
     }}
  end

  @impl GenServer
  def handle_call(
        {token, {:reserve_capability, environment, name}},
        _from,
        %{token: token} = state
      )
      when environment in [:workflow, :mission] do
    case reserve_capability_state(state, environment, name) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({token, :release_provider_slot}, _from, %{token: token} = state) do
    {:reply, :ok, %{state | provider_tasks: max(state.provider_tasks - 1, 0)}}
  end

  def handle_call({token, :finish_provider}, _from, %{token: token} = state) do
    state = %{state | provider_tasks: max(state.provider_tasks - 1, 0)}
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

        {:reply, {:ok, state.memory, elem(lease, 0)},
         %{state | evaluations: state.evaluations + 1, evaluation_lease: lease}}
    end
  end

  def handle_call(
        {token, {:commit_evaluation, lease, memory}},
        {caller, _tag},
        %{token: token} = state
      ) do
    case state.evaluation_lease do
      {^lease, ^caller, monitor_ref} ->
        Process.demonitor(monitor_ref, [:flush])

        bytes = RetainedSize.bytes_with_cap(memory, state.limits.evaluation_memory_bytes)

        if is_integer(bytes) and bytes <= state.limits.evaluation_memory_bytes and
             not unavailable?(state) do
          {:reply, :ok, %{state | memory: memory, evaluation_lease: nil}}
        else
          {:reply, {:error, :memory_exceeded}, %{state | evaluation_lease: nil}}
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
    {:reply, reply, %{state | protocol_errors: next, closed?: state.closed? or reply != :ok}}
  end

  def handle_call({token, :close}, _from, %{token: token} = state),
    do: {:reply, :ok, %{state | closed?: true}}

  def handle_call({token, :usage}, _from, %{token: token} = state),
    do: {:reply, usage_projection(state), state}

  def handle_call({token, :limits}, _from, %{token: token} = state),
    do: {:reply, state.limits, state}

  def handle_call({token, :open?}, _from, %{token: token} = state),
    do: {:reply, not unavailable?(state), state}

  def handle_call({token, :evaluation_memory_summary}, _from, %{token: token} = state),
    do:
      {:reply,
       %{
         defined_count: map_size(state.memory),
         bytes: RetainedSize.bytes_with_cap(state.memory, state.limits.evaluation_memory_bytes)
       }, state}

  def handle_call({_token, _request}, _from, state), do: {:reply, {:error, :closed}, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{evaluation_lease: {_lease, _caller, ref}} = state
      ),
      do: {:noreply, %{state | evaluation_lease: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  defp reserve_capability_state(state, environment, name) do
    {limit_total, limit_name} = capability_limits(state.limits, environment)
    count = get_in(state.calls, [environment, name]) || 0

    cond do
      unavailable?(state) ->
        {:error, :run_closed, state}

      state.provider_tasks >= state.limits.live_provider_tasks ->
        {:error, :live_task_limit, state}

      Map.fetch!(state.totals, environment) >= limit_total or count >= limit_name ->
        {:error, :limit_exceeded, state}

      true ->
        state =
          state
          |> update_in([:calls, environment], &Map.put(&1, name, count + 1))
          |> update_in([:totals, environment], &(&1 + 1))

        {:ok, %{state | provider_tasks: state.provider_tasks + 1}}
    end
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
      evaluation_busy?: not is_nil(state.evaluation_lease)
    }
  end

  defp call(%__MODULE__{pid: pid, token: token}, request),
    do: GenServer.call(pid, {token, request})
end
