defmodule PtcRunner.Kernel.RunState do
  @moduledoc """
  Internal single owner of mutable per-run resource state.

  One GenServer owns the deadline, open/closed status, workflow and mission
  capability counters, live provider-task count, protocol errors, subordinate
  evaluation and source-check counts, terminal failure,
  evaluation-continuation lease and revision, and committed native evaluation
  memory/history.

  Reservations and commits are deliberately atomic owner operations. Callers
  must not recreate them as separate read and update steps. The opaque token
  prevents messages that did not originate through the returned handle from
  mutating state. The process monitors the run owner and automatically exits
  with it. Owner checks compare the actual `GenServer.call/3` caller inside this
  process. Ordinary and standalone-REPL state cannot transfer ownership; only
  co-hosted session construction receives a one-shot transfer.

  Each capability reservation monitors the dispatching process. Every attached
  provider is also registered with the run's one provider-task owner, an
  internal process external to both this process and the provider session. It
  monitors both, so it untrappably kills every attached callback when either
  lifecycle disappears — including a session terminated at its cleanup
  deadline, where `terminate/2` cannot run. If the
  dispatching process dies mid-call (heap kill, timeout kill), the reservation
  is reclaimed only after the attached provider process has been killed and
  its `:DOWN` observed. Thus connector cleanup cannot begin while a callback
  from that run remains live. Shutdown — owner death or explicit stop —
  likewise kills and drains every still-attached provider before state
  terminates. A process holds at most one reservation at a time: dispatch is
  sequential per process, so a second reserve while one is active is a protocol
  violation and is rejected rather than silently replacing the tracked
  reservation.

  A dispatching process routinely races that shutdown, so the calls it makes
  here report closure rather than propagating the owner's exit, each answering
  with the value that fails closed for its own caller. `usage/1` and `limits/1`
  are the deliberate exceptions: invented limits would widen the ceilings a
  caller is about to enforce and an invented usage snapshot would misreport the
  budget, so exiting with the owner is the safe outcome and they stay unguarded.
  What is reported is the same for any exit, including a call timeout; a reply
  the owner actually sent is always passed through, so a mismatched token still
  reaches the caller unchanged. A provider process atomically records terminal policy
  classification against the active evaluation before publishing its result;
  that evaluation-scoped bit therefore survives a later sandbox timeout or heap
  kill and is cleared with the lease.
  """
  use GenServer

  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.EventSinkState
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ProviderTaskTracker
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.RetainedSize

  @history_depth 3

  @enforce_keys [:pid, :token, :provider_tracker]
  defstruct [:pid, :token, :provider_tracker]

  @type environment :: :workflow | :mission

  @typedoc """
  Opaque handle to the one process that owns this run's provider tasks.

  Its shape is an implementation detail: callers receive it inside `t:t/0` and
  hand it back to the Kernel rather than inspecting it. Declaring it here keeps
  the public struct from depending on an internal module's documentation, and
  `pid()` would be inaccurate because the handle also carries an ownership
  token.
  """
  @type provider_tracker :: %{:__struct__ => module(), :pid => pid(), :token => reference()}

  @type t :: %__MODULE__{
          pid: pid(),
          token: reference(),
          provider_tracker: provider_tracker()
        }

  @spec start(Limits.t(), keyword()) :: {:ok, t()} | {:error, term()}
  @doc "Starts run state, preserving a supplied active-run deadline when present."
  def start(%Limits{} = limits, opts \\ []) do
    token = make_ref()
    owner = Keyword.get(opts, :owner, self())
    provider_session = Keyword.get(opts, :provider_session)
    run_deadline = Keyword.get(opts, :run_deadline)

    if Keyword.keys(opts) -- [:owner, :provider_session, :run_deadline] == [] and
         valid_provider_session?(provider_session) and valid_run_deadline?(run_deadline) do
      start_state({limits, token, owner, nil, false, nil, run_deadline})
    else
      {:error, :invalid_run_state}
    end
  end

  @doc false
  def start_repl(%Limits{} = limits, %EventSink{} = event_sink, inspection_sink, opts \\ []) do
    with true <- EventSink.owner?(event_sink),
         true <- inspection_owner?(inspection_sink),
         true <- Keyword.keyword?(opts),
         true <- Keyword.keys(opts) -- [:owner, :run_deadline] == [],
         owner = Keyword.get(opts, :owner, self()),
         true <- is_pid(owner) and Process.alive?(owner),
         run_deadline = Keyword.get(opts, :run_deadline),
         true <- valid_run_deadline?(run_deadline),
         token = make_ref(),
         {:ok, state} <-
           start_state(
             {limits, token, owner, nil, false, {event_sink, inspection_sink}, run_deadline}
           ) do
      {:ok, state}
    else
      _ -> {:error, :session_owner_mismatch}
    end
  end

  @doc false
  def start_with_event_sink(%Limits{} = limits, sink_opts, opts \\ []) do
    token = make_ref()
    owner = Keyword.get(opts, :owner, self())

    with true <- Keyword.keys(opts) -- [:owner] == [],
         {:ok, event_sink, handle} <- EventSink.prepare(:normal, limits, sink_opts),
         {:ok, state} <-
           start_state({limits, token, owner, event_sink, true, nil, nil}) do
      {:ok, state, struct!(EventSink, Map.put(handle, :pid, state.pid))}
    else
      _ -> {:error, :invalid_run_state}
    end
  end

  @doc """
  Reserves a capability slot, authenticating mission calls by lease.

  A mission reservation must present the lease of the evaluation whose tool
  grant issued the call; a lease that is no longer current answers
  `{:error, :stale_evaluation}`. This closes the window where a dead
  evaluation's lingering sandbox reserves after the next evaluation was
  admitted and has its late call attributed to the new lease. Workflow
  reservations carry no lease.
  """
  @spec reserve_capability(t(), environment(), binary(), reference() | nil) ::
          :ok | {:error, atom()}
  def reserve_capability(state, environment, name, lease),
    do: safe_call(state, {:reserve_capability, environment, name, lease}, {:error, :run_closed})

  @spec reserve_capability(t(), environment(), binary()) :: :ok | {:error, atom()}
  @doc "Atomically reserves environment, per-name, and live-provider budgets."
  def reserve_capability(state, environment, name),
    do: reserve_capability(state, environment, name, nil)

  @doc """
  Checks whether a mission lease is still the current evaluation lease.

  Advisory pre-authentication for dispatch: a stale evaluation's call is
  turned away before it can run argument validators or spend the shared
  protocol-error budget. The atomic recheck inside `reserve_capability/4`
  remains authoritative.
  """
  @spec mission_lease_current?(t(), reference() | nil) :: boolean()
  def mission_lease_current?(state, lease),
    do: safe_call(state, {:mission_lease_current?, lease}, false)

  @spec attach_provider(t(), pid()) :: :ok | {:error, :closed | :provider_down}
  @doc "Attaches the caller's live provider process to its capability reservation."
  def attach_provider(%__MODULE__{} = state, provider) when is_pid(provider) do
    case ProviderTaskTracker.attach(state.provider_tracker, provider) do
      :ok ->
        # The external task owner can still accept an attachment while its
        # run-state death notification is queued. This call closes that window
        # and must report closure rather than exit.
        case safe_call(state, {:attach_provider, provider}, {:error, :closed}) do
          :ok ->
            :ok

          {:error, :closed} = error ->
            Process.exit(provider, :kill)
            error
        end

      {:error, :closed} = error ->
        Process.exit(provider, :kill)
        _ = release_provider_slot(state)
        error

      {:error, :provider_down} = error ->
        _ = release_provider_slot(state)
        error
    end
  end

  # Returning a slot is best effort. The tracker refuses an attachment exactly
  # when it has stopped, which is what it does once the owner goes down, so this
  # release routinely races the owner's exit. The budget dies with the owner
  # either way; an exiting call here would instead take the dispatching process
  # with it.
  @spec release_provider_slot(t()) :: :ok | {:error, :closed}
  @doc "Releases the caller's live provider slot without accepting a result."
  def release_provider_slot(state),
    do: safe_call(state, :release_provider_slot, {:error, :closed})

  # A provider result can arrive after the owner is gone, which is the same race
  # release_provider_slot/1 answers. Only the exit becomes :run_closed; a reply
  # the owner actually sent is passed through, so a bad token still reaches the
  # caller as the unhandled :closed it has always been.
  @spec finish_provider(t()) :: :ok | {:error, :run_closed}
  @doc "Releases a provider slot and accepts completion only while the run is open."
  def finish_provider(state), do: safe_call(state, :finish_provider, {:error, :run_closed})

  @doc false
  @spec mark_evaluation_terminal_provider_failure(t()) :: :ok | {:error, :closed}
  def mark_evaluation_terminal_provider_failure(state),
    do: safe_call(state, :mark_evaluation_terminal_provider_failure, :ok)

  @spec reserve_evaluation(t()) :: {:ok, map(), [term()], reference()} | {:error, atom()}
  @doc "Atomically reserves and returns native subordinate memory and turn history."
  def reserve_evaluation(state), do: reserve_evaluation(state, :fail_fast)

  @doc """
  Reserves the evaluation lease with the chosen admission mode.

  `:fail_fast` answers `{:error, :busy}` while another evaluation holds the
  lease (or its provider reservations are still draining). `:block` parks the
  caller in a FIFO admission queue instead; the reply arrives when the lease
  frees, or as `{:error, :admission_timeout}` /
  `{:error, :deadline_expired}` when the bounded wait ends first. The wait is
  bounded server-side by `evaluation_admission_timeout_ms` and the run
  deadline, so the blocking call itself uses an infinite client timeout.
  """
  @spec reserve_evaluation(t(), :fail_fast | :block) ::
          {:ok, map(), [term()], reference()} | {:error, atom()}
  def reserve_evaluation(state, :fail_fast), do: call(state, :reserve_evaluation)

  # The admission wait is bounded from the moment the caller asks, not the
  # moment the owner processes the request — time in the owner's mailbox
  # counts against the bound.
  def reserve_evaluation(state, :block) do
    requested_at = System.monotonic_time(:millisecond)
    call_blocking(state, {:reserve_evaluation, :block, requested_at})
  end

  @doc false
  @spec reserve_source_check(t()) :: {:ok, map(), non_neg_integer()} | {:error, atom()}
  def reserve_source_check(state), do: call(state, :reserve_source_check)

  @doc false
  @spec finish_source_check(t(), non_neg_integer()) :: :ok | {:error, atom()}
  def finish_source_check(state, revision) when is_integer(revision) and revision >= 0,
    do: call(state, {:finish_source_check, revision})

  @spec commit_evaluation(t(), reference(), map(), [term()]) :: :ok | {:error, atom()}
  @doc "Atomically commits one bounded native memory/history continuation candidate."
  def commit_evaluation(state, lease, memory, history)
      when is_map(memory) and is_list(history),
      do: call(state, {:commit_evaluation, lease, memory, history})

  @spec release_evaluation(t(), reference()) :: :ok | {:error, atom()}
  @doc "Releases the caller's evaluation lease without changing committed memory."
  def release_evaluation(state, lease), do: call(state, {:release_evaluation, lease})

  @doc false
  @spec release_evaluation_status(t(), reference()) ::
          {:ok, %{terminal_provider_failure?: boolean()}} | {:error, atom()}
  def release_evaluation_status(state, lease),
    do: call(state, {:release_evaluation_status, lease})

  @spec protocol_error(t()) :: :ok | {:error, :protocol_error_limit}
  @doc "Records one protocol error and closes the run when its ceiling is exceeded."
  def protocol_error(state), do: safe_call(state, :protocol_error, :ok)

  @doc """
  Records one protocol error after atomically authenticating the mission lease.

  Authentication and accounting are one owner operation: an advisory check
  followed by a separate `protocol_error/1` would let an evaluation that died
  mid-validation spend the next evaluation's shared protocol-error budget.
  A stale mission lease answers `{:error, :stale_evaluation}` and records
  nothing. Workflow calls carry no lease and are always recorded.
  """
  @spec protocol_error(t(), environment(), reference() | nil) ::
          :ok | {:error, :protocol_error_limit | :stale_evaluation}
  def protocol_error(state, environment, lease),
    do: safe_call(state, {:protocol_error, environment, lease}, :ok)

  # There is no failure left to record once the owner is gone. As above, the
  # declared :ok never covered the mismatched-token reply.
  @spec fail(t(), atom(), atom()) :: :ok | {:error, :closed}
  @doc "Records the first terminal failure and closes the run."
  def fail(state, kind, reason), do: safe_call(state, {:fail, kind, reason}, :ok)

  @spec terminal_failure(t()) :: nil | %{kind: atom(), reason: atom()}
  @doc "Returns the first terminal failure, if any."
  def terminal_failure(state), do: call(state, :terminal_failure)

  @spec close(t()) :: :ok
  @doc "Closes the run against further reservations and result commits."
  def close(state), do: call(state, :close)

  @doc false
  @spec close_and_drain(t()) :: :ok
  def close_and_drain(%__MODULE__{} = state) do
    call(state, :close_and_drain)
  after
    ProviderTaskTracker.drain_provider_tasks(state.provider_tracker)
  end

  @spec stop(t()) :: :ok
  @doc "Stops the owner process after the run has closed."
  def stop(%__MODULE__{} = state) do
    GenServer.stop(state.pid, :normal)
  after
    ProviderTaskTracker.drain_provider_tasks(state.provider_tracker)
  end

  # These two answer with the owner's data, and there is no substitute that
  # fails closed: invented limits would widen the byte ceilings a caller is
  # about to enforce, and an invented usage snapshot would misreport the budget.
  # Exiting with the dead owner is the safe outcome, so they stay unguarded.
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

  @doc false
  @spec closed?(t()) :: boolean()
  def closed?(state), do: call(state, :closed?)

  @doc false
  @spec owner?(t()) :: boolean()
  def owner?(state), do: call(state, :owner?) == true

  @doc false
  @spec repl_owner?(t(), EventSink.t(), InspectionSink.t() | nil, Limits.t()) :: boolean()
  def repl_owner?(state, event_sink, inspection_sink, limits),
    do: call(state, {:repl_owner?, event_sink, inspection_sink, limits}) == true

  @doc false
  @spec repl_resources?(t(), EventSink.t(), InspectionSink.t() | nil, Limits.t()) :: boolean()
  def repl_resources?(state, event_sink, inspection_sink, limits),
    do: call(state, {:repl_resources?, event_sink, inspection_sink, limits}) == true

  @spec evaluation_memory_summary(t()) :: map()
  @doc "Returns bounded definition, history, and retained continuation byte counts."
  def evaluation_memory_summary(state), do: call(state, :evaluation_memory_summary)

  @doc false
  @spec evaluation_memory_observation(t()) ::
          map()
          | {:error,
             :session_owner_mismatch
             | {:java_projection_error
                | :lisp_value_projection_error
                | :projection_error
                | :symbol_ref_projection_error, term()}}
  def evaluation_memory_observation(state), do: call(state, :evaluation_memory_observation)

  @doc false
  def transfer_owner(state, owner) when is_pid(owner), do: call(state, {:transfer_owner, owner})

  # Task ownership does not move with the session: the one tracker keeps it and
  # starts monitoring the session when execution binds its lifecycle. This only
  # refuses a session that could never be bound.
  @doc false
  @spec use_provider_session(t(), ProviderSession.t() | nil) ::
          {:ok, t()} | {:error, :invalid_run_state}
  def use_provider_session(%__MODULE__{} = state, nil), do: {:ok, state}

  def use_provider_session(%__MODULE__{} = state, session) do
    if ProviderSession.valid?(session),
      do: {:ok, state},
      else: {:error, :invalid_run_state}
  end

  def use_provider_session(_state, _session), do: {:error, :invalid_run_state}

  @impl GenServer
  def init({limits, token, owner, event_sink, owner_transferable?, repl_resources, run_deadline}) do
    deadline_ms =
      if Deadline.valid?(run_deadline),
        do: Deadline.expires_at(run_deadline),
        else: System.monotonic_time(:millisecond) + limits.run_duration_ms

    {:ok,
     %{
       token: token,
       owner: owner,
       owner_ref: Process.monitor(owner),
       owner_transferable?: owner_transferable?,
       event_sink: event_sink,
       repl_resources: repl_resources,
       limits: limits,
       deadline_ms: deadline_ms,
       closed?: false,
       provider_tasks: 0,
       calls: %{workflow: %{}, mission: %{}},
       totals: %{workflow: 0, mission: 0},
       evaluations: 0,
       source_checks: 0,
       protocol_errors: 0,
       terminal_failure: nil,
       memory: %{},
       history: [],
       continuation_revision: 0,
       evaluation_lease: nil,
       evaluation_release_waiter: nil,
       evaluation_terminal_provider_failure?: false,
       admission_queue: :queue.new(),
       reservations: %{}
     }}
  end

  @impl GenServer
  def handle_call(
        {event_token, :owner},
        _from,
        %{event_sink: %{token: event_token}, owner: owner} = state
      ),
      do: {:reply, {:ok, owner}, state}

  def handle_call(
        {event_token, :owner?},
        {caller, _tag},
        %{event_sink: %{token: event_token}, owner: owner} = state
      ),
      do: {:reply, caller == owner, state}

  def handle_call(
        {event_token, _request} = request,
        _from,
        %{event_sink: %{token: event_token}} = state
      ) do
    {reply, event_sink} = EventSinkState.handle(request, state.event_sink)
    {:reply, reply, %{state | event_sink: event_sink}}
  end

  def handle_call(
        {token, {:reserve_capability, environment, name, lease}},
        {caller, _tag},
        %{token: token} = state
      )
      when environment in [:workflow, :mission] do
    case reserve_capability_state(state, environment, name, caller, lease) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({token, {:mission_lease_current?, lease}}, _from, %{token: token} = state),
    do: {:reply, current_mission_lease?(state, lease), state}

  def handle_call({token, {:attach_provider, provider}}, {caller, _tag}, %{token: token} = state) do
    if unavailable?(state) do
      Process.exit(provider, :kill)
      {:reply, {:error, :closed}, release_reservation(state, caller)}
    else
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
  end

  def handle_call({token, :release_provider_slot}, {caller, _tag}, %{token: token} = state) do
    {:reply, :ok, release_reservation(state, caller)}
  end

  def handle_call({token, :finish_provider}, {caller, _tag}, %{token: token} = state) do
    state = release_reservation(state, caller)
    reply = if unavailable?(state), do: {:error, :run_closed}, else: :ok
    {:reply, reply, state}
  end

  def handle_call(
        {token, :mark_evaluation_terminal_provider_failure},
        {provider, _tag},
        %{token: token} = state
      ) do
    reservation_lease =
      Enum.find_value(state.reservations, fn
        {_caller,
         %{environment: :mission, provider: ^provider, evaluation_lease: evaluation_lease}} ->
          evaluation_lease

        _reservation ->
          nil
      end)

    current_lease? =
      case state.evaluation_lease do
        {^reservation_lease, _owner, _monitor_ref} when is_reference(reservation_lease) -> true
        _other -> false
      end

    state =
      if current_lease?,
        do: %{state | evaluation_terminal_provider_failure?: true},
        else: state

    {:reply, :ok, state}
  end

  def handle_call({token, :reserve_evaluation}, {caller, _tag}, %{token: token} = state) do
    cond do
      state.closed? ->
        {:reply, {:error, :run_closed}, state}

      deadline_expired?(state) ->
        {:reply, {:error, :deadline_expired}, state}

      not grantable?(state) or not :queue.is_empty(state.admission_queue) ->
        {:reply, {:error, :busy}, state}

      state.evaluations >= state.limits.subordinate_evaluations ->
        {:reply, {:error, :limit_exceeded}, state}

      true ->
        lease = {make_ref(), caller, Process.monitor(caller)}

        {:reply, {:ok, state.memory, state.history, elem(lease, 0)},
         %{
           state
           | evaluations: state.evaluations + 1,
             evaluation_lease: lease,
             evaluation_release_waiter: nil,
             evaluation_terminal_provider_failure?: false
         }}
    end
  end

  def handle_call(
        {token, {:reserve_evaluation, :block, requested_at}},
        {caller, _tag} = from,
        %{token: token} = state
      )
      when is_integer(requested_at) do
    admission_deadline = admission_deadline(state, requested_at)

    cond do
      state.closed? ->
        {:reply, {:error, :run_closed}, state}

      deadline_expired?(state) ->
        {:reply, {:error, :deadline_expired}, state}

      # The bound counts from the caller's request, so a message that sat in
      # the owner's mailbox past its whole admission window is refused even
      # when the lease happens to be free.
      System.monotonic_time(:millisecond) >= admission_deadline ->
        {:reply, {:error, :admission_timeout}, state}

      state.evaluations >= state.limits.subordinate_evaluations ->
        {:reply, {:error, :limit_exceeded}, state}

      grantable?(state) and :queue.is_empty(state.admission_queue) ->
        lease = {make_ref(), caller, Process.monitor(caller)}

        {:reply, {:ok, state.memory, state.history, elem(lease, 0)},
         %{
           state
           | evaluations: state.evaluations + 1,
             evaluation_lease: lease,
             evaluation_release_waiter: nil,
             evaluation_terminal_provider_failure?: false
         }}

      true ->
        # admit_from_queue self-heals the (unreachable by invariant) state of
        # a grantable lease behind a non-empty queue: the FIFO head is
        # admitted, which may be this caller.
        {:noreply,
         admit_from_queue(enqueue_admission_waiter(state, from, caller, admission_deadline))}
    end
  end

  def handle_call({token, :reserve_source_check}, _from, %{token: token} = state) do
    cond do
      state.closed? ->
        {:reply, {:error, :run_closed}, state}

      deadline_expired?(state) ->
        {:reply, {:error, :deadline_expired}, state}

      not grantable?(state) or not :queue.is_empty(state.admission_queue) ->
        {:reply, {:error, :busy}, state}

      state.source_checks >= state.limits.subordinate_source_checks ->
        {:reply, {:error, :limit_exceeded}, state}

      true ->
        {:reply, {:ok, state.memory, state.continuation_revision},
         %{state | source_checks: state.source_checks + 1}}
    end
  end

  def handle_call(
        {token, {:finish_source_check, revision}},
        _from,
        %{token: token} = state
      ) do
    cond do
      state.closed? -> {:reply, {:error, :run_closed}, state}
      deadline_expired?(state) -> {:reply, {:error, :deadline_expired}, state}
      state.continuation_revision != revision -> {:reply, {:error, :stale}, state}
      true -> {:reply, :ok, state}
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
            {:reply, {:error, :run_closed}, clear_evaluation(state)}

          not event_sink_ready?(state.event_sink) ->
            failure =
              state.terminal_failure || %{kind: :event_sink_error, reason: :event_sink_error}

            next = %{
              state
              | closed?: true,
                terminal_failure: failure
            }

            next = clear_evaluation(next)

            {:reply, {:error, :run_closed}, next}

          not (is_integer(memory_bytes) and
                   memory_bytes <= state.limits.evaluation_memory_bytes) ->
            {:reply, {:error, :memory_exceeded}, clear_evaluation(state)}

          not (history_values_valid? and is_integer(history_bytes) and
                   history_bytes <= state.limits.evaluation_history_bytes) ->
            {:reply, {:error, :history_exceeded}, clear_evaluation(state)}

          true ->
            {:reply, :ok,
             %{
               state
               | memory: RetainedSize.detach_binaries(memory),
                 history: RetainedSize.detach_binaries(history),
                 continuation_revision: state.continuation_revision + 1
             }
             |> clear_evaluation()}
        end

      _ ->
        {:reply, {:error, :stale_lease}, state}
    end
  end

  def handle_call({token, {:release_evaluation, lease}}, {caller, _tag}, %{token: token} = state) do
    case state.evaluation_lease do
      {^lease, ^caller, monitor_ref} ->
        Process.demonitor(monitor_ref, [:flush])
        {:reply, :ok, clear_evaluation(state)}

      _ ->
        {:reply, {:error, :stale_lease}, state}
    end
  end

  def handle_call(
        {token, {:release_evaluation_status, lease}},
        {caller, _tag} = from,
        %{token: token} = state
      ) do
    case state.evaluation_lease do
      # Dispatch is sequential per process, so a second status request while
      # one is parked is a protocol violation; overwriting would drop the
      # first waiter's `from`. Reject rather than replace, like a double
      # capability reserve.
      {^lease, ^caller, _monitor_ref} when state.evaluation_release_waiter != nil ->
        {:reply, {:error, :release_pending}, state}

      {^lease, ^caller, monitor_ref} ->
        if evaluation_reservations?(state, lease) do
          {:noreply, %{state | evaluation_release_waiter: {from, lease}}}
        else
          Process.demonitor(monitor_ref, [:flush])
          {:reply, {:ok, evaluation_status(state)}, clear_evaluation(state)}
        end

      _ ->
        {:reply, {:error, :stale_lease}, state}
    end
  end

  def handle_call(
        {token, {:protocol_error, environment, lease}},
        from,
        %{token: token} = state
      )
      when environment in [:workflow, :mission] do
    if environment == :mission and not current_mission_lease?(state, lease) do
      {:reply, {:error, :stale_evaluation}, state}
    else
      handle_call({token, :protocol_error}, from, state)
    end
  end

  def handle_call({token, :protocol_error}, _from, %{token: token} = state) do
    next = state.protocol_errors + 1
    reply = if next > state.limits.protocol_errors, do: {:error, :protocol_error_limit}, else: :ok

    state =
      if reply == :ok do
        %{state | protocol_errors: next}
      else
        admit_from_queue(%{
          state
          | protocol_errors: next,
            closed?: true,
            terminal_failure: %{kind: :limit_exceeded, reason: :protocol_errors}
        })
      end

    {:reply, reply, state}
  end

  def handle_call({token, {:fail, kind, reason}}, _from, %{token: token} = state)
      when is_atom(kind) and is_atom(reason) do
    failure = state.terminal_failure || %{kind: kind, reason: reason}
    {:reply, :ok, admit_from_queue(%{state | closed?: true, terminal_failure: failure})}
  end

  def handle_call({token, :terminal_failure}, _from, %{token: token} = state),
    do: {:reply, state.terminal_failure, state}

  def handle_call({token, :close}, _from, %{token: token} = state),
    do: {:reply, :ok, admit_from_queue(%{state | closed?: true})}

  def handle_call({token, :close_and_drain}, _from, %{token: token} = state),
    do: {:reply, :ok, close_and_drain_state(state)}

  def handle_call({token, :usage}, _from, %{token: token} = state),
    do: {:reply, usage_projection(state), state}

  def handle_call({token, :limits}, _from, %{token: token} = state),
    do: {:reply, state.limits, state}

  def handle_call({token, :open?}, _from, %{token: token} = state),
    do: {:reply, not unavailable?(state), state}

  def handle_call({token, :closed?}, _from, %{token: token} = state),
    do: {:reply, state.closed?, state}

  def handle_call({token, :owner?}, {caller, _tag}, %{token: token} = state),
    do: {:reply, caller == state.owner, state}

  def handle_call(
        {token, {:repl_owner?, event_sink, inspection_sink, limits}},
        {caller, _tag},
        %{token: token} = state
      ) do
    owner? =
      caller == state.owner and
        state.repl_resources === {event_sink, inspection_sink} and
        state.limits === limits

    {:reply, owner?, state}
  end

  def handle_call(
        {token, {:repl_resources?, event_sink, inspection_sink, limits}},
        _from,
        %{token: token} = state
      ) do
    resources? =
      state.repl_resources === {event_sink, inspection_sink} and
        state.limits === limits

    {:reply, resources?, state}
  end

  def handle_call({token, :evaluation_memory_summary}, _from, %{token: token} = state),
    do: {:reply, continuation_summary(state), state}

  def handle_call(
        {token, :evaluation_memory_observation},
        {caller, _tag},
        %{token: token, owner: caller} = state
      ),
      do: {:reply, Lisp.externalize_memory(state.memory), state}

  def handle_call(
        {token, :evaluation_memory_observation},
        _from,
        %{token: token} = state
      ),
      do: {:reply, {:error, :session_owner_mismatch}, state}

  def handle_call(
        {token, {:transfer_owner, owner}},
        {caller, _tag},
        %{token: token, owner: caller, owner_transferable?: true} = state
      )
      when is_pid(owner) do
    if Process.alive?(owner) do
      Process.demonitor(state.owner_ref, [:flush])

      {:reply, :ok,
       %{
         state
         | owner: owner,
           owner_ref: Process.monitor(owner),
           owner_transferable?: false
       }}
    else
      {:reply, {:error, :closed}, state}
    end
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :closed}, state}

  defp inspection_owner?(nil), do: true
  defp inspection_owner?(sink), do: InspectionSink.owner?(sink)

  @impl GenServer
  def handle_cast(_request, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{evaluation_lease: {_lease, _caller, ref}} = state
      ),
      do: {:noreply, clear_evaluation(state)}

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
            {:noreply, drop_dead_admission_waiter(state, ref)}
        end
    end
  end

  def handle_info({:admission_deadline, monitor_ref}, state) do
    case take_admission_waiter(state, monitor_ref) do
      {nil, state} ->
        {:noreply, state}

      {waiter, state} ->
        Process.demonitor(waiter.monitor_ref, [:flush])

        reply =
          if deadline_expired?(state),
            do: {:error, :deadline_expired},
            else: {:error, :admission_timeout}

        GenServer.reply(waiter.from, reply)
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp drop_dead_admission_waiter(state, monitor_ref) do
    case take_admission_waiter(state, monitor_ref) do
      {nil, state} ->
        state

      {waiter, state} ->
        Process.cancel_timer(waiter.timer_ref)
        state
    end
  end

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

  defp close_and_drain_state(state) do
    state.reservations
    |> Enum.flat_map(fn
      {_caller, %{provider: provider}} when is_pid(provider) -> [provider]
      _reservation -> []
    end)
    |> Enum.uniq()
    |> kill_and_drain()

    Enum.each(state.reservations, fn {_caller, reservation} ->
      if is_reference(reservation.caller_ref),
        do: Process.demonitor(reservation.caller_ref, [:flush])

      if is_reference(reservation.provider_ref),
        do: Process.demonitor(reservation.provider_ref, [:flush])
    end)

    %{state | closed?: true, provider_tasks: 0, reservations: %{}}
    |> maybe_complete_evaluation_release()
    |> admit_from_queue()
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

  defp reserve_capability_state(state, environment, name, caller, lease) do
    {limit_total, limit_name} = capability_limits(state.limits, environment)
    count = get_in(state.calls, [environment, name]) || 0

    cond do
      unavailable?(state) ->
        {:error, :run_closed, state}

      # A mission call is authenticated by the lease of the evaluation whose
      # tool grant issued it. A stale lease means the originating evaluation
      # already ended: attributing the call to the current lease (or to no
      # lease) would let a dead evaluation's lingering sandbox overlap the
      # next evaluation's external effects and mislabel provider provenance.
      environment == :mission and not current_mission_lease?(state, lease) ->
        {:error, :stale_evaluation, state}

      state.provider_tasks >= state.limits.live_provider_tasks ->
        {:error, :live_task_limit, state}

      Map.fetch!(state.totals, environment) >= limit_total or count >= limit_name ->
        {:error, :limit_exceeded, state}

      Map.has_key?(state.reservations, caller) ->
        {:error, :reservation_held, state}

      true ->
        reservation = %{
          environment: environment,
          evaluation_lease: active_evaluation_lease(state, environment),
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

    next =
      if reservation do
        %{state | provider_tasks: max(state.provider_tasks - 1, 0), reservations: reservations}
      else
        state
      end

    next
    |> maybe_complete_evaluation_release()
    |> admit_from_queue()
  end

  defp active_evaluation_lease(state, :mission) do
    case state.evaluation_lease do
      {lease, _owner, _monitor_ref} -> lease
      nil -> nil
    end
  end

  defp active_evaluation_lease(_state, :workflow), do: nil

  defp current_mission_lease?(state, lease) when is_reference(lease) do
    match?({^lease, _owner, _monitor_ref}, state.evaluation_lease)
  end

  defp current_mission_lease?(_state, _lease), do: false

  defp evaluation_reservations?(state, lease) do
    Enum.any?(state.reservations, fn
      {_caller, %{evaluation_lease: ^lease}} -> true
      _reservation -> false
    end)
  end

  defp evaluation_status(state) do
    %{terminal_provider_failure?: state.evaluation_terminal_provider_failure?}
  end

  defp maybe_complete_evaluation_release(%{evaluation_release_waiter: nil} = state), do: state

  defp maybe_complete_evaluation_release(%{evaluation_release_waiter: {_from, lease}} = state) do
    case state.evaluation_lease do
      {^lease, _owner, monitor_ref} ->
        if evaluation_reservations?(state, lease) do
          state
        else
          Process.demonitor(monitor_ref, [:flush])
          clear_evaluation(state)
        end

      # The waiter's lease is already gone, so no provider provenance is
      # pending for it; clearing resolves it.
      _other ->
        clear_evaluation(state)
    end
  end

  # A parked release-status waiter is resolved — never dropped — by every
  # path that clears the lease, including a commit or release the lease
  # owner issued asynchronously after parking. The reply carries the status
  # bits as they stand at resolution, before the clear resets them.
  defp resolve_release_waiter(%{evaluation_release_waiter: nil} = state), do: state

  defp resolve_release_waiter(%{evaluation_release_waiter: {from, _lease}} = state) do
    GenServer.reply(from, {:ok, evaluation_status(state)})
    %{state | evaluation_release_waiter: nil}
  end

  defp clear_evaluation(state) do
    state = resolve_release_waiter(state)

    %{state | evaluation_lease: nil, evaluation_terminal_provider_failure?: false}
    |> admit_from_queue()
  end

  # Grants require a free lease AND no reservation still tied to a dead
  # evaluation's lease: the lease-owner :DOWN path frees the lease while that
  # evaluation's provider tasks may still be live, and granting before their
  # reservations drain would overlap two evaluations' external effects.
  defp grantable?(state) do
    state.evaluation_lease == nil and not stale_lease_reservations?(state)
  end

  defp stale_lease_reservations?(state) do
    Enum.any?(state.reservations, fn
      {_caller, %{evaluation_lease: lease}} -> is_reference(lease)
      _reservation -> false
    end)
  end

  # The admission bound counts from the caller's request time and is capped
  # by the run deadline.
  defp admission_deadline(state, requested_at) do
    min(
      requested_at + state.limits.evaluation_admission_timeout_ms,
      state.deadline_ms
    )
  end

  defp enqueue_admission_waiter(state, from, caller, deadline_mono) do
    monitor_ref = Process.monitor(caller)
    delay = max(deadline_mono - System.monotonic_time(:millisecond), 0)
    timer_ref = Process.send_after(self(), {:admission_deadline, monitor_ref}, delay)

    # The absolute deadline is authoritative; the timer is only its wake-up.
    # A lease release already ahead of the timer message in the mailbox must
    # not grant an expired waiter, so every grant re-checks the deadline.
    waiter = %{
      from: from,
      caller: caller,
      monitor_ref: monitor_ref,
      timer_ref: timer_ref,
      deadline_mono: deadline_mono
    }

    %{state | admission_queue: :queue.in(waiter, state.admission_queue)}
  end

  # The single admission point. Pops waiters until it grants one or runs out:
  # a waiter that fails the preflight re-check gets its typed error and the
  # loop continues, because no future lease-clear is guaranteed to occur.
  defp admit_from_queue(state) do
    case :queue.out(state.admission_queue) do
      {:empty, _queue} ->
        state

      {{:value, waiter}, rest} ->
        cond do
          state.closed? ->
            resolve_admission_waiter(waiter, {:error, :run_closed})
            admit_from_queue(%{state | admission_queue: rest})

          deadline_expired?(state) ->
            resolve_admission_waiter(waiter, {:error, :deadline_expired})
            admit_from_queue(%{state | admission_queue: rest})

          System.monotonic_time(:millisecond) >= waiter.deadline_mono ->
            resolve_admission_waiter(waiter, {:error, :admission_timeout})
            admit_from_queue(%{state | admission_queue: rest})

          state.evaluations >= state.limits.subordinate_evaluations ->
            resolve_admission_waiter(waiter, {:error, :limit_exceeded})
            admit_from_queue(%{state | admission_queue: rest})

          not grantable?(state) ->
            state

          true ->
            grant_admission(%{state | admission_queue: rest}, waiter)
        end
    end
  end

  # The waiter's caller monitor becomes the lease monitor, so only the timer
  # needs cancelling; a timer message already in flight misses its queue
  # lookup and is ignored.
  defp grant_admission(state, waiter) do
    Process.cancel_timer(waiter.timer_ref)
    lease = {make_ref(), waiter.caller, waiter.monitor_ref}
    GenServer.reply(waiter.from, {:ok, state.memory, state.history, elem(lease, 0)})

    %{
      state
      | evaluations: state.evaluations + 1,
        evaluation_lease: lease,
        evaluation_release_waiter: nil,
        evaluation_terminal_provider_failure?: false
    }
  end

  defp resolve_admission_waiter(waiter, reply) do
    Process.cancel_timer(waiter.timer_ref)
    Process.demonitor(waiter.monitor_ref, [:flush])
    GenServer.reply(waiter.from, reply)
  end

  defp take_admission_waiter(state, monitor_ref) do
    waiters = :queue.to_list(state.admission_queue)

    case Enum.split_with(waiters, &(&1.monitor_ref == monitor_ref)) do
      {[waiter], rest} -> {waiter, %{state | admission_queue: :queue.from_list(rest)}}
      {[], _waiters} -> {nil, state}
    end
  end

  defp reservation_by_provider_ref(reservations, ref) do
    Enum.find_value(reservations, fn {caller, reservation} ->
      if reservation.provider_ref == ref, do: {caller, reservation}
    end)
  end

  defp unavailable?(state),
    do: state.closed? or deadline_expired?(state)

  defp deadline_expired?(state),
    do: System.monotonic_time(:millisecond) >= state.deadline_ms

  defp event_sink_ready?(nil), do: true
  defp event_sink_ready?(event_sink), do: EventSinkState.ready?(event_sink)

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
      subordinate_source_checks: state.source_checks,
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

  defp start_state(args) do
    case GenServer.start(__MODULE__, args) do
      {:ok, pid} ->
        case ProviderTaskTracker.start(pid) do
          {:ok, provider_tracker} ->
            token = elem(args, 1)
            {:ok, %__MODULE__{pid: pid, token: token, provider_tracker: provider_tracker}}

          {:error, reason} ->
            GenServer.stop(pid, :normal)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_provider_session?(nil), do: true
  defp valid_provider_session?(session), do: ProviderSession.valid?(session)

  defp valid_run_deadline?(nil), do: true
  defp valid_run_deadline?(deadline), do: Deadline.valid?(deadline)

  defp call(%__MODULE__{pid: pid, token: token}, request),
    do: GenServer.call(pid, {token, request})

  # Blocking admission is bounded server-side (admission timer + run
  # deadline), so the client timeout is infinite: a finite one would race the
  # server's own timers and turn a legitimate reply into a caller exit.
  defp call_blocking(%__MODULE__{pid: pid, token: token}, request),
    do: GenServer.call(pid, {token, request}, :infinity)

  defp safe_call(state, request, on_exit) do
    call(state, request)
  catch
    :exit, _reason -> on_exit
  end
end
