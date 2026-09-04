defmodule PtcRunner.Kernel.RunState do
  @moduledoc """
  Internal single owner of mutable per-run resource state.

  One GenServer owns the deadline, open/closed status, workflow and mission
  capability counters, optional per-route call counters keyed by
  `{public name, route key}`, live provider-task count, protocol errors,
  payload-free capability-refusal counts, subordinate
  evaluation and source-check counts, terminal failure,
  evaluation-continuation lease and revision, and committed native evaluation
  memory/history.

  Reservations and commits are deliberately atomic owner operations. Callers
  must not recreate them as separate read and update steps. A routed LLM alias
  may carry `max_calls`; that per-alias cap is checked inside the same reserve,
  after the public total and per-name quotas, so a spent alias is named only
  when those shared buckets still have room. The opaque token
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
  reaches the caller unchanged. Provider and pre-dispatch validation processes
  atomically record terminal classifications against the active evaluation
  before publishing their results; those evaluation-scoped bits therefore
  survive a later sandbox timeout or heap kill and are cleared with the lease.
  """
  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction

  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.EventSinkState
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMReplayDiagnostic
  alias PtcRunner.Kernel.LLMUsage
  alias PtcRunner.Kernel.LLMUsageSummary
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ProviderTaskTracker
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.RetainedSize

  @history_depth 3
  @maximum_integer 9_007_199_254_740_991
  # Outcome proofs are Kernel bookkeeping, independent of evaluator-history
  # retention. The byte cap exceeds the largest admitted application document,
  # so one canonical proof always fits, while the count cap matches the shipped
  # maximum per-name workflow-call ceiling.
  @agent_outcome_failure_count 2_048
  @agent_outcome_failure_bytes 16_000_000

  # Each named mission owns an independent continuation and revision. The
  # active lease records its mission so reserve, commit, release, and source
  # checking cannot move memory or closures across mission boundaries.
  @workflow_continuation "$workflow"

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
  reservations carry no lease. When `route` is
  `%{route_key: alias, max_calls: n}` and `n` is stricter than the public
  per-name quota, the owner refuses that alias once it has spent `n` calls
  (`{:error, :route_call_limit}`) after the public total and per-name quotas.
  An alias cap at or above the per-name budget is ignored so omitted defaults
  keep today's public quota.   A named `max_calls` diagnostic is authenticated
  only after this owner has actually refused that alias. Public total and
  per-name quota refusals are authenticated the same way, keyed by the limit,
  capability name, and configured value that this owner actually refused.
  Aggregate `llm_total_tokens` and `llm_cost_microusd` reservation refusals
  are authenticated from the exact `limit`, `limit_value`, `requested`, and
  `remaining` this owner authored at refuse time.
  """
  @spec reserve_capability(t(), environment(), binary(), reference() | nil, map() | nil) ::
          {:ok, reference()} | {:error, atom()} | {:error, atom(), map()}
  def reserve_capability(state, environment, name, lease, route \\ nil) do
    safe_call(
      state,
      {:reserve_capability, environment, name, lease, route},
      {:error, :run_closed}
    )
  end

  @spec reserve_capability(t(), environment(), binary()) ::
          {:ok, reference()} | {:error, atom()} | {:error, atom(), map()}
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

  @public_quota_limits [
    :workflow_capability_calls,
    :workflow_capability_calls_per_name,
    :mission_capability_calls,
    :mission_capability_calls_per_name
  ]

  @spec max_calls_refusal?(t(), map()) :: boolean()
  @doc false
  def max_calls_refusal?(state, %{limit: :max_calls, alias: alias_name, limit_value: limit})
      when is_binary(alias_name) and is_integer(limit) and limit > 0,
      do: safe_call(state, {:max_calls_refusal?, alias_name, limit}, false)

  def max_calls_refusal?(_state, _details), do: false

  @spec named_quota_refusal?(t(), map()) :: boolean()
  @doc false
  def named_quota_refusal?(state, %{limit: :max_calls} = details),
    do: max_calls_refusal?(state, details)

  def named_quota_refusal?(state, %{limit: limit, name: name, limit_value: value})
      when limit in @public_quota_limits and is_binary(name) and is_integer(value) and
             value > 0,
      do: safe_call(state, {:quota_refusal?, limit, name, value}, false)

  def named_quota_refusal?(_state, _details), do: false

  @budget_limits [:llm_total_tokens, :llm_cost_microusd]

  @spec budget_refusal?(t(), map()) :: boolean()
  @doc false
  def budget_refusal?(
        state,
        %{limit: limit, limit_value: limit_value, requested: requested, remaining: remaining}
      )
      when limit in @budget_limits and is_integer(limit_value) and limit_value > 0 and
             is_integer(requested) and requested > remaining and is_integer(remaining) and
             remaining >= 0 and remaining <= limit_value,
      do: safe_call(state, {:budget_refusal?, limit, limit_value, requested, remaining}, false)

  def budget_refusal?(_state, _details), do: false

  @spec capability_quota_details(t(), environment(), binary()) :: map()
  @doc false
  def capability_quota_details(state, environment, name)
      when environment in [:workflow, :mission] and is_binary(name),
      do: safe_call(state, {:capability_quota_details, environment, name}, %{})

  @spec protocol_errors_details(t()) :: %{limit: :protocol_errors, limit_value: pos_integer()}
  @doc false
  def protocol_errors_details(state) do
    %{limit: :protocol_errors, limit_value: limits(state).protocol_errors}
  end

  @spec attach_provider(t(), reference(), pid()) ::
          :ok | {:error, :closed | :provider_down | :unknown_reservation}
  @doc "Attaches the caller's live provider process to its capability reservation."
  def attach_provider(%__MODULE__{} = state, reservation_id, provider)
      when is_reference(reservation_id) and is_pid(provider) do
    case ProviderTaskTracker.attach(state.provider_tracker, provider) do
      :ok ->
        # The external task owner can still accept an attachment while its
        # run-state death notification is queued. This call closes that window
        # and must report closure rather than exit.
        case safe_call(
               state,
               {:attach_provider, reservation_id, provider},
               {:error, :closed}
             ) do
          :ok ->
            :ok

          {:error, :closed} = error ->
            Process.exit(provider, :kill)
            error

          {:error, :unknown_reservation} = error ->
            Process.exit(provider, :kill)
            error
        end

      {:error, :closed} = error ->
        Process.exit(provider, :kill)
        error

      {:error, :provider_down} = error ->
        error
    end
  end

  @spec open_provider_gate(t(), reference(), pid(), reference()) ::
          :ok
          | {:error,
             :already_dispatched
             | :dispatch_unknown
             | :unknown_reservation
             | :run_closed
             | :provider_mismatch}
  @doc "Atomically records provider dispatch and sends its one-shot gate reference."
  def open_provider_gate(state, reservation_id, provider, gate)
      when is_reference(reservation_id) and is_pid(provider) and is_reference(gate),
      do:
        safe_call(
          state,
          {:open_provider_gate, reservation_id, provider, gate},
          {:error, :dispatch_unknown}
        )

  def open_provider_gate(_state, _reservation_id, _provider, _gate),
    do: {:error, :unknown_reservation}

  @type usage_evidence :: {:valid, map()} | :missing | :invalid
  @type settlement_evidence ::
          {:adapter_success, usage_evidence()}
          | {:adapter_error,
             :provider_error | :worker_exit | :timeout | :cancelled | :not_dispatched}

  @spec finish_provider(t(), reference(), settlement_evidence()) ::
          {:ok, :settled}
          | {:ok, {:overrun, [:total_tokens | :cost, ...]}}
          | {:error, :unknown_reservation}
  @doc "Settles one provider reservation from closed Dispatcher-owned evidence."
  def finish_provider(state, reservation_id, evidence) when is_reference(reservation_id) do
    if valid_settlement_evidence?(evidence) do
      safe_call(
        state,
        {:finish_provider, reservation_id, evidence},
        {:error, :unknown_reservation}
      )
    else
      {:error, :unknown_reservation}
    end
  end

  def finish_provider(_state, _reservation_id, _evidence),
    do: {:error, :unknown_reservation}

  @doc false
  @spec record_replay_miss(t(), binary()) :: :ok | {:error, :run_closed}
  def record_replay_miss(state, request_hash) when is_binary(request_hash) do
    if LLMReplayDiagnostic.valid_request_hash?(request_hash),
      do: safe_call(state, {:record_replay_miss, request_hash}, {:error, :run_closed}),
      else: {:error, :run_closed}
  end

  @doc false
  @spec record_llm_provider_failure(t(), ProviderError.t()) :: :ok | {:error, :run_closed}
  def record_llm_provider_failure(state, %ProviderError{} = error) do
    if ProviderError.valid?(error) do
      safe_call(state, {:record_llm_provider_failure, error}, {:error, :run_closed})
    else
      {:error, :run_closed}
    end
  end

  def record_llm_provider_failure(_state, _error), do: {:error, :run_closed}

  @doc false
  @spec record_llm_provider_failure(t(), :reservation_bound_exceeded, false) ::
          :ok | {:error, :run_closed}
  def record_llm_provider_failure(state, :reservation_bound_exceeded, false) do
    safe_call(
      state,
      {:record_llm_provider_failure, :reservation_bound_exceeded, false},
      {:error, :run_closed}
    )
  end

  def record_llm_provider_failure(_state, _kind, _retryable?), do: {:error, :run_closed}

  @doc false
  @spec replay_miss?(t(), binary()) :: boolean()
  def replay_miss?(state, request_hash) when is_binary(request_hash),
    do: safe_call(state, {:replay_miss?, request_hash}, false)

  def replay_miss?(_state, _request_hash), do: false

  @doc false
  @spec consume_llm_provider_failure(t(), ProviderError.kind(), boolean()) :: :ok | :error
  def consume_llm_provider_failure(state, kind, retryable?)
      when is_atom(kind) and is_boolean(retryable?),
      do: safe_call(state, {:consume_llm_provider_failure, kind, retryable?}, :error)

  def consume_llm_provider_failure(_state, _kind, _retryable?), do: :error

  @doc false
  @spec record_agent_outcome_failure(t(), binary(), map(), PtcRunner.Lisp.TrustedError.t()) ::
          :ok | {:error, :evidence_limit | :run_closed}
  def record_agent_outcome_failure(
        state,
        token,
        evidence,
        %PtcRunner.Lisp.TrustedError{} = failure
      )
      when is_binary(token) and is_map(evidence) do
    safe_call(
      state,
      {:record_agent_outcome_failure, token, evidence, failure},
      {:error, :run_closed}
    )
  end

  def record_agent_outcome_failure(_state, _token, _evidence, _failure),
    do: {:error, :run_closed}

  @doc false
  @spec consume_agent_outcome_failure(t(), binary(), map()) ::
          {:ok, PtcRunner.Lisp.TrustedError.t()} | :error
  def consume_agent_outcome_failure(state, token, evidence)
      when is_binary(token) and is_map(evidence),
      do: safe_call(state, {:consume_agent_outcome_failure, token, evidence}, :error)

  def consume_agent_outcome_failure(_state, _token, _evidence), do: :error

  @doc false
  @spec mark_evaluation_terminal_provider_failure(t()) :: :ok | {:error, :closed}
  def mark_evaluation_terminal_provider_failure(state),
    do: safe_call(state, :mark_evaluation_terminal_provider_failure, :ok)

  @doc false
  @spec mark_evaluation_terminal_host_failure(t(), reference()) :: :ok | {:error, :closed}
  def mark_evaluation_terminal_host_failure(state, evaluation_lease),
    do: safe_call(state, {:mark_evaluation_terminal_host_failure, evaluation_lease}, :ok)

  @doc false
  def reserve_workflow_evaluation(state),
    do: reserve_evaluation(state, @workflow_continuation, :fail_fast)

  @doc false
  @spec yield_workflow_evaluation(t(), reference()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def yield_workflow_evaluation(state, lease),
    do: call(state, {:yield_workflow_evaluation, lease})

  @doc false
  @spec resume_workflow_evaluation(t(), non_neg_integer()) ::
          {:ok, reference()} | {:error, atom()}
  def resume_workflow_evaluation(state, revision) when is_integer(revision) and revision >= 0,
    do: call(state, {:resume_workflow_evaluation, revision})

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
  @spec reserve_evaluation(t(), binary(), :fail_fast | :block) ::
          {:ok, map(), [term()], reference()} | {:error, atom()}
  def reserve_evaluation(state, mission_name, :fail_fast) when is_binary(mission_name),
    do: call(state, {:reserve_evaluation, mission_name})

  # The admission wait is bounded from the moment the caller asks, not the
  # moment the owner processes the request — time in the owner's mailbox
  # counts against the bound.
  def reserve_evaluation(state, mission_name, :block) when is_binary(mission_name) do
    requested_at = System.monotonic_time(:millisecond)
    call_blocking(state, {:reserve_evaluation, mission_name, :block, requested_at})
  end

  @doc false
  @spec reserve_evaluation_with_limit_proof(t(), binary(), :fail_fast | :block) ::
          {:ok, map(), [term()], reference()}
          | {:error, atom() | {:limit_exceeded, binary()}}
  def reserve_evaluation_with_limit_proof(state, mission_name, :fail_fast)
      when is_binary(mission_name),
      do: call(state, {:reserve_evaluation, mission_name, :with_limit_proof})

  def reserve_evaluation_with_limit_proof(state, mission_name, :block)
      when is_binary(mission_name) do
    requested_at = System.monotonic_time(:millisecond)

    call_blocking(
      state,
      {:reserve_evaluation, mission_name, :block, requested_at, :with_limit_proof}
    )
  end

  @doc false
  @spec consume_evaluation_limit_proof(t(), binary()) ::
          :ok | {:error, :invalid_evaluation_limit_proof}
  def consume_evaluation_limit_proof(state, proof) when is_binary(proof),
    do: call(state, {:consume_evaluation_limit_proof, proof})

  def consume_evaluation_limit_proof(_state, _proof),
    do: {:error, :invalid_evaluation_limit_proof}

  @doc false
  @spec reserve_source_check(t(), binary()) :: {:ok, map(), non_neg_integer()} | {:error, atom()}
  def reserve_source_check(state, mission_name) when is_binary(mission_name),
    do: call(state, {:reserve_source_check, mission_name})

  @doc false
  @spec finish_source_check(t(), binary(), non_neg_integer()) :: :ok | {:error, atom()}
  def finish_source_check(state, mission_name, revision)
      when is_binary(mission_name) and is_integer(revision) and revision >= 0,
      do: call(state, {:finish_source_check, mission_name, revision})

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
          {:ok,
           %{
             terminal_provider_failure?: boolean(),
             terminal_host_failure?: boolean()
           }}
          | {:error, atom()}
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

  @doc """
  Records one agent-loop protocol error without consuming a limit or closing the run.

  This is not `protocol_error/1`: that counter is the Kernel's recoverable
  capability-protocol budget and closes the run at its ceiling. The loop's
  count is attested through a private trusted tool and is observational.
  """
  @spec record_agent_protocol_error(t()) :: :ok | {:error, :closed}
  def record_agent_protocol_error(state), do: safe_call(state, :agent_protocol_error, :ok)

  @doc """
  Records one capability-callback error under its closed rejection class.

  The count is observational: it does not consume a budget or close the run.
  Keys are produced by `SafeMetadata.capability_refusal_key/2`. Distinct class
  keys are capped at `SafeMetadata.capability_refusal_map_limit/0`; further
  classes increment `$overflow`. Recording after the run has closed is
  intentional — `run_closed` refusals happen then.
  """
  @spec record_capability_refusal(t(), binary()) :: :ok
  def record_capability_refusal(state, key)
      when is_binary(key) and byte_size(key) in 1..192,
      do: safe_call(state, {:record_capability_refusal, key}, :ok)

  @doc false
  @spec record_llm_usage(t(), binary(), binary(), atom(), map() | nil) :: :ok | {:error, :closed}
  def record_llm_usage(state, alias_name, revision, status, usage)
      when is_binary(alias_name) and is_binary(revision) and is_atom(status) do
    safe_call(state, {:record_llm_usage, alias_name, revision, status, usage}, :ok)
  end

  # There is no failure left to record once the owner is gone. As above, the
  # declared :ok never covered the mismatched-token reply.
  @spec fail(t(), atom(), atom()) :: :ok | {:error, :closed}
  @doc "Records the first terminal failure and closes the run."
  def fail(state, kind, reason), do: safe_call(state, {:fail, kind, reason}, :ok)

  @doc false
  @spec fail_event_capture_limit(
          t(),
          :normal_event_count | :normal_event_bytes,
          pos_integer()
        ) :: :ok | {:error, :closed}
  def fail_event_capture_limit(state, limit, value)
      when limit in [:normal_event_count, :normal_event_bytes] and is_integer(value) and value > 0,
      do: safe_call(state, {:fail_event_capture_limit, limit, value}, :ok)

  @doc false
  @spec fail_once(t(), atom(), atom()) ::
          {:recorded, %{kind: atom(), reason: atom()}}
          | {:existing,
             %{kind: atom(), reason: atom()} | %{kind: atom(), reason: atom(), details: map()}}
  def fail_once(state, kind, reason) do
    safe_call(
      state,
      {:fail_once, kind, reason},
      {:existing, %{kind: :session_closed, reason: :run_closed}}
    )
  end

  @spec terminal_failure(t()) ::
          nil | %{kind: atom(), reason: atom(), details: map()} | %{kind: atom(), reason: atom()}
  @doc "Returns the first terminal failure, if any."
  def terminal_failure(state), do: call(state, :terminal_failure)

  @spec record_last_evaluator_failure(t(), map()) :: :ok
  def record_last_evaluator_failure(state, evidence) when is_map(evidence),
    do: call(state, {:record_last_evaluator_failure, evidence})

  @doc false
  @spec consume_evaluator_failure(t(), binary()) :: {:ok, map()} | :error
  def consume_evaluator_failure(state, evaluation_id) when is_binary(evaluation_id),
    do: call(state, {:consume_evaluator_failure, evaluation_id})

  @spec last_evaluator_failure(t()) :: {:ok, map()} | :error
  def last_evaluator_failure(state), do: call(state, :last_evaluator_failure)

  @spec clear_last_evaluator_failure(t()) :: :ok
  def clear_last_evaluator_failure(state), do: call(state, :clear_last_evaluator_failure)

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
       route_calls: %{workflow: %{}, mission: %{}},
       route_refusals: MapSet.new(),
       quota_refusals: MapSet.new(),
       budget_refusals: MapSet.new(),
       totals: %{workflow: 0, mission: 0},
       evaluations: 0,
       evaluations_by_mission: %{},
       source_checks: 0,
       protocol_errors: 0,
       agent_protocol_errors: 0,
       capability_refusals: %{},
       llm_budget: %{
         total_tokens: new_ledger(limits.llm_total_tokens),
         cost: new_ledger(limits.llm_cost_microusd)
       },
       llm_usage: %{},
       replay_misses: MapSet.new(),
       llm_provider_failures: MapSet.new(),
       agent_outcome_failures: %{},
       agent_outcome_failure_bytes: 0,
       terminal_failure: nil,
       last_evaluator_failure: nil,
       evaluator_failures: %{},
       continuations: %{},
       evaluation_lease: nil,
       evaluation_mission: nil,
       evaluation_release_waiter: nil,
       evaluation_terminal_provider_failure?: false,
       evaluation_terminal_host_failure?: false,
       admission_queue: :queue.new(),
       evaluation_limit_proofs: %{},
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
        {token, {:reserve_capability, environment, name, lease, route}},
        {caller, _tag},
        %{token: token} = state
      )
      when environment in [:workflow, :mission] do
    case reserve_capability_state(state, environment, name, caller, lease, route) do
      {:ok, reservation_id, state} -> {:reply, {:ok, reservation_id}, state}
      {:error, reason, details, state} -> {:reply, {:error, reason, details}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({token, {:mission_lease_current?, lease}}, _from, %{token: token} = state),
    do: {:reply, current_mission_lease?(state, lease), state}

  def handle_call(
        {token, {:max_calls_refusal?, alias_name, limit}},
        _from,
        %{token: token} = state
      )
      when is_binary(alias_name) and is_integer(limit) and limit > 0 do
    {:reply, matching_route_refusal?(state, alias_name, limit), state}
  end

  def handle_call(
        {token, {:quota_refusal?, limit, name, value}},
        _from,
        %{token: token} = state
      )
      when limit in @public_quota_limits and is_binary(name) and is_integer(value) and
             value > 0 do
    {:reply, matching_quota_refusal?(state, limit, name, value), state}
  end

  def handle_call(
        {token, {:capability_quota_details, environment, name}},
        _from,
        %{token: token} = state
      )
      when environment in [:workflow, :mission] and is_binary(name) do
    {:reply, quota_details_map(state, environment, name) || %{}, state}
  end

  def handle_call(
        {token, {:budget_refusal?, limit, limit_value, requested, remaining}},
        _from,
        %{token: token} = state
      )
      when limit in @budget_limits and is_integer(limit_value) and limit_value > 0 and
             is_integer(requested) and requested >= 0 and is_integer(remaining) and remaining >= 0 do
    {:reply, matching_budget_refusal?(state, limit, limit_value, requested, remaining), state}
  end

  def handle_call(
        {token, {:attach_provider, reservation_id, provider}},
        {caller, _tag},
        %{token: token} = state
      ) do
    if unavailable?(state) do
      Process.exit(provider, :kill)
      {:reply, {:error, :closed}, settle_reservation(state, reservation_id, :cleanup) |> elem(1)}
    else
      case state.reservations do
        %{^reservation_id => %{caller: ^caller} = reservation} ->
          reservation =
            reservation
            |> Map.put(:provider, provider)
            |> Map.put(:provider_ref, Process.monitor(provider))

          reservations = Map.put(state.reservations, reservation_id, reservation)
          {:reply, :ok, %{state | reservations: reservations}}

        _ ->
          Process.exit(provider, :kill)
          {:reply, {:error, :unknown_reservation}, state}
      end
    end
  end

  def handle_call(
        {token, {:open_provider_gate, reservation_id, provider, gate}},
        _from,
        %{token: token} = state
      )
      when is_reference(gate) do
    cond do
      unavailable?(state) ->
        {:reply, {:error, :run_closed}, state}

      not Map.has_key?(state.reservations, reservation_id) ->
        {:reply, {:error, :unknown_reservation}, state}

      get_in(state.reservations, [reservation_id, :provider]) != provider ->
        {:reply, {:error, :provider_mismatch}, state}

      get_in(state.reservations, [reservation_id, :dispatched?]) ->
        {:reply, {:error, :already_dispatched}, state}

      true ->
        send(provider, gate)
        {:reply, :ok, put_in(state.reservations[reservation_id].dispatched?, true)}
    end
  end

  def handle_call(
        {token, {:finish_provider, reservation_id, evidence}},
        _from,
        %{token: token} = state
      ) do
    if unavailable?(state) do
      {_cleanup_reply, state} = settle_reservation(state, reservation_id, :cleanup)
      {:reply, {:error, :unknown_reservation}, state}
    else
      {reply, state} = settle_reservation(state, reservation_id, evidence)
      {:reply, reply, state}
    end
  end

  def handle_call(
        {token, {:record_replay_miss, request_hash}},
        _from,
        %{token: token} = state
      ) do
    if unavailable?(state) do
      {:reply, {:error, :run_closed}, state}
    else
      {:reply, :ok, maybe_record_replay_miss(state, request_hash)}
    end
  end

  def handle_call({token, {:replay_miss?, request_hash}}, _from, %{token: token} = state),
    do: {:reply, MapSet.member?(state.replay_misses, request_hash), state}

  def handle_call(
        {token, {:record_llm_provider_failure, %ProviderError{} = error}},
        _from,
        %{token: token} = state
      ) do
    if unavailable?(state) do
      {:reply, {:error, :run_closed}, state}
    else
      evidence = {error.kind, error.retryable?}

      {:reply, :ok,
       %{state | llm_provider_failures: MapSet.put(state.llm_provider_failures, evidence)}}
    end
  end

  def handle_call(
        {token, {:record_llm_provider_failure, :reservation_bound_exceeded, false}},
        _from,
        %{token: token} = state
      ) do
    if unavailable?(state) do
      {:reply, {:error, :run_closed}, state}
    else
      evidence = {:reservation_bound_exceeded, false}

      {:reply, :ok,
       %{state | llm_provider_failures: MapSet.put(state.llm_provider_failures, evidence)}}
    end
  end

  def handle_call(
        {token, {:consume_llm_provider_failure, kind, retryable?}},
        _from,
        %{token: token} = state
      ) do
    evidence = {kind, retryable?}

    if MapSet.member?(state.llm_provider_failures, evidence) do
      {:reply, :ok,
       %{state | llm_provider_failures: MapSet.delete(state.llm_provider_failures, evidence)}}
    else
      {:reply, :error, state}
    end
  end

  def handle_call(
        {token,
         {:record_agent_outcome_failure, evidence_token, evidence,
          %PtcRunner.Lisp.TrustedError{} = failure}},
        _from,
        %{token: token} = state
      ) do
    if unavailable?(state) do
      {:reply, {:error, :run_closed}, state}
    else
      evidence_limit = @agent_outcome_failure_count
      byte_limit = @agent_outcome_failure_bytes
      expected = agent_outcome_failure_key(evidence)
      retained = RetainedSize.detach_binaries({expected, failure})

      case RetainedSize.bytes_with_cap(retained, byte_limit) do
        size
        when is_integer(size) and map_size(state.agent_outcome_failures) < evidence_limit and
               state.agent_outcome_failure_bytes + size <= byte_limit ->
          failures = Map.put(state.agent_outcome_failures, evidence_token, {retained, size})

          {:reply, :ok,
           %{
             state
             | agent_outcome_failures: failures,
               agent_outcome_failure_bytes: state.agent_outcome_failure_bytes + size
           }}

        _limit_reached ->
          {:reply, {:error, :evidence_limit}, state}
      end
    end
  end

  def handle_call(
        {token, {:consume_agent_outcome_failure, evidence_token, evidence}},
        _from,
        %{token: token} = state
      ) do
    expected = agent_outcome_failure_key(evidence)

    case Map.get(state.agent_outcome_failures, evidence_token) do
      {{^expected, failure}, size} ->
        failures = Map.delete(state.agent_outcome_failures, evidence_token)

        {:reply, {:ok, failure},
         %{
           state
           | agent_outcome_failures: failures,
             agent_outcome_failure_bytes: state.agent_outcome_failure_bytes - size
         }}

      _missing_or_mismatched ->
        {:reply, :error, state}
    end
  end

  def handle_call(
        {token, :mark_evaluation_terminal_provider_failure},
        {provider, _tag},
        %{token: token} = state
      ) do
    reservation_lease =
      Enum.find_value(state.reservations, fn
        {_reservation_id,
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

  def handle_call(
        {token, {:mark_evaluation_terminal_host_failure, evaluation_lease}},
        _from,
        %{token: token} = state
      ) do
    state =
      case state.evaluation_lease do
        {^evaluation_lease, _owner, _monitor_ref} when is_reference(evaluation_lease) ->
          %{state | evaluation_terminal_host_failure?: true}

        _other ->
          state
      end

    {:reply, :ok, state}
  end

  def handle_call(
        {token, {:reserve_evaluation, mission}},
        from,
        %{token: token} = state
      ),
      do: reserve_evaluation_now(state, mission, from, false)

  def handle_call(
        {token, {:reserve_evaluation, mission, :with_limit_proof}},
        from,
        %{token: token} = state
      ),
      do: reserve_evaluation_now(state, mission, from, true)

  def handle_call(
        {token, {:reserve_evaluation, mission, :block, requested_at}},
        from,
        %{token: token} = state
      )
      when is_integer(requested_at),
      do: reserve_evaluation_blocking(state, mission, requested_at, from, false)

  def handle_call(
        {token, {:reserve_evaluation, mission, :block, requested_at, :with_limit_proof}},
        from,
        %{token: token} = state
      )
      when is_integer(requested_at),
      do: reserve_evaluation_blocking(state, mission, requested_at, from, true)

  def handle_call(
        {token, {:yield_workflow_evaluation, lease}},
        {caller, _tag},
        %{token: token} = state
      ) do
    case {state.evaluation_lease, state.evaluation_mission} do
      {{^lease, ^caller, monitor_ref}, @workflow_continuation} ->
        Process.demonitor(monitor_ref, [:flush])
        revision = continuation(state, @workflow_continuation).revision
        {:reply, {:ok, revision}, clear_evaluation(state)}

      _other ->
        {:reply, {:error, :stale_lease}, state}
    end
  end

  def handle_call(
        {token, {:resume_workflow_evaluation, revision}},
        {caller, _tag},
        %{token: token} = state
      ) do
    cond do
      state.closed? ->
        {:reply, {:error, :run_closed}, state}

      deadline_expired?(state) ->
        {:reply, {:error, :deadline_expired}, state}

      not grantable?(state) or not :queue.is_empty(state.admission_queue) ->
        {:reply, {:error, :busy}, state}

      continuation(state, @workflow_continuation).revision != revision ->
        {:reply, {:error, :stale}, state}

      true ->
        lease = {make_ref(), caller, Process.monitor(caller)}

        {:reply, {:ok, elem(lease, 0)},
         %{
           state
           | evaluation_lease: lease,
             evaluation_mission: @workflow_continuation,
             evaluation_release_waiter: nil,
             evaluation_terminal_provider_failure?: false,
             evaluation_terminal_host_failure?: false
         }}
    end
  end

  def handle_call(
        {token, {:consume_evaluation_limit_proof, proof}},
        {caller, _tag},
        %{token: token} = state
      ) do
    case state.evaluation_limit_proofs do
      %{^caller => %{proof: ^proof, monitor_ref: monitor_ref}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:reply, :ok, drop_evaluation_limit_proof(state, caller)}

      _other ->
        {:reply, {:error, :invalid_evaluation_limit_proof}, state}
    end
  end

  def handle_call({token, {:reserve_source_check, mission}}, _from, %{token: token} = state) do
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
        continuation = continuation(state, mission)

        {:reply, {:ok, continuation.memory, continuation.revision},
         %{state | source_checks: state.source_checks + 1}}
    end
  end

  def handle_call(
        {token, {:finish_source_check, mission, revision}},
        _from,
        %{token: token} = state
      ) do
    cond do
      state.closed? -> {:reply, {:error, :run_closed}, state}
      deadline_expired?(state) -> {:reply, {:error, :deadline_expired}, state}
      continuation(state, mission).revision != revision -> {:reply, {:error, :stale}, state}
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

        mission = state.evaluation_mission

        # Per-mission bytes AND the run-wide total are both held under the same
        # ceiling. Enforcing only the per-mission figure would silently multiply
        # the run's retained heap by the number of missions.
        memory_bytes =
          mission_and_total_bytes(
            state.continuations,
            mission,
            :memory,
            memory,
            state.limits.evaluation_memory_bytes
          )

        history_bytes =
          mission_and_total_bytes(
            state.continuations,
            mission,
            :history,
            history,
            state.limits.evaluation_history_bytes
          )

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
            previous = continuation(state, mission)

            committed = %{
              memory: RetainedSize.detach_binaries(memory),
              history: RetainedSize.detach_binaries(history),
              revision: previous.revision + 1
            }

            {:reply, :ok,
             %{
               state
               | continuations: Map.put(state.continuations, mission, committed)
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
            terminal_failure: %{
              kind: :limit_exceeded,
              reason: :protocol_errors,
              details: %{
                limit: :protocol_errors,
                limit_value: state.limits.protocol_errors
              }
            }
        })
      end

    {:reply, reply, state}
  end

  def handle_call({token, :agent_protocol_error}, _from, %{token: token} = state) do
    {:reply, :ok, %{state | agent_protocol_errors: state.agent_protocol_errors + 1}}
  end

  def handle_call(
        {token, {:record_capability_refusal, key}},
        _from,
        %{token: token} = state
      )
      when is_binary(key) and byte_size(key) in 1..192 do
    {:reply, :ok,
     %{state | capability_refusals: put_capability_refusal(state.capability_refusals, key)}}
  end

  def handle_call(
        {token, {:record_llm_usage, alias_name, revision, status, usage}},
        _from,
        %{token: token} = state
      )
      when is_binary(alias_name) and is_binary(revision) and is_atom(status) do
    {:reply, :ok,
     %{
       state
       | llm_usage:
           LLMUsageSummary.accumulate(state.llm_usage, alias_name, revision, status, usage)
     }}
  end

  def handle_call({token, {:fail, kind, reason}}, _from, %{token: token} = state)
      when is_atom(kind) and is_atom(reason) do
    failure = state.terminal_failure || %{kind: kind, reason: reason}
    {:reply, :ok, admit_from_queue(%{state | closed?: true, terminal_failure: failure})}
  end

  def handle_call(
        {token, {:fail_event_capture_limit, limit, value}},
        _from,
        %{token: token} = state
      )
      when limit in [:normal_event_count, :normal_event_bytes] and is_integer(value) and value > 0 do
    failure =
      state.terminal_failure ||
        %{
          kind: :limit_exceeded,
          reason: :event_capture_limit_exceeded,
          details: %{limit: limit, limit_value: value}
        }

    {:reply, :ok, admit_from_queue(%{state | closed?: true, terminal_failure: failure})}
  end

  def handle_call({token, {:fail_once, kind, reason}}, _from, %{token: token} = state)
      when is_atom(kind) and is_atom(reason) do
    case state.terminal_failure do
      nil ->
        failure = %{kind: kind, reason: reason}

        {:reply, {:recorded, failure},
         admit_from_queue(%{state | closed?: true, terminal_failure: failure})}

      failure ->
        {:reply, {:existing, failure}, state}
    end
  end

  def handle_call({token, :terminal_failure}, _from, %{token: token} = state),
    do: {:reply, state.terminal_failure, state}

  def handle_call(
        {token, {:record_last_evaluator_failure, evidence}},
        _from,
        %{token: token} = state
      )
      when is_map(evidence) do
    failures =
      case Map.get(evidence, :evaluation_id) do
        evaluation_id when is_binary(evaluation_id) ->
          Map.put(state.evaluator_failures, evaluation_id, evidence)

        _missing ->
          state.evaluator_failures
      end

    {:reply, :ok, %{state | last_evaluator_failure: evidence, evaluator_failures: failures}}
  end

  def handle_call(
        {token, {:consume_evaluator_failure, evaluation_id}},
        _from,
        %{token: token} = state
      ) do
    case Map.fetch(state.evaluator_failures, evaluation_id) do
      {:ok, evidence} ->
        {:reply, {:ok, evidence},
         %{state | evaluator_failures: Map.delete(state.evaluator_failures, evaluation_id)}}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({token, :last_evaluator_failure}, _from, %{token: token} = state) do
    case state.last_evaluator_failure do
      %{} = evidence -> {:reply, {:ok, evidence}, state}
      nil -> {:reply, :error, state}
    end
  end

  def handle_call({token, :clear_last_evaluator_failure}, _from, %{token: token} = state),
    do: {:reply, :ok, %{state | last_evaluator_failure: nil}}

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
      # Workflow REPL memory is held in its own continuation, outside missions.
      do:
        {:reply, Lisp.externalize_memory(continuation(state, @workflow_continuation).memory),
         state}

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

  defp agent_outcome_failure_key(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      {agent_outcome_failure_map_key(key), agent_outcome_failure_key(item)}
    end)
  end

  defp agent_outcome_failure_key(value) when is_list(value),
    do: Enum.map(value, &agent_outcome_failure_key/1)

  defp agent_outcome_failure_key(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.replace("_", "-")

  defp agent_outcome_failure_key("invalid_return"), do: "invalid-return"
  defp agent_outcome_failure_key(value), do: value

  defp agent_outcome_failure_map_key(key) when is_atom(key),
    do: key |> Atom.to_string() |> String.replace("_", "-")

  defp agent_outcome_failure_map_key(key) when is_binary(key),
    do: String.replace(key, "_", "-")

  defp agent_outcome_failure_map_key(key), do: key

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{evaluation_lease: {_lease, _caller, ref}} = state
      ),
      do: {:noreply, clear_evaluation(state)}

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case reservation_by_caller_ref(state.reservations, ref) do
      {reservation_id, %{caller: ^pid, provider: provider} = reservation} ->
        if is_pid(provider) do
          Process.exit(provider, :kill)

          reservations =
            Map.put(state.reservations, reservation_id, %{reservation | caller_ref: nil})

          {:noreply, %{state | reservations: reservations}}
        else
          {_reply, state} = settle_reservation(state, reservation_id, :cleanup)
          {:noreply, state}
        end

      nil ->
        case reservation_by_provider_ref(state.reservations, ref) do
          {reservation_id, %{caller_ref: nil}} ->
            {_reply, state} = settle_reservation(state, reservation_id, :cleanup)
            {:noreply, state}

          {reservation_id, reservation} ->
            reservation = %{reservation | provider: nil, provider_ref: nil}
            {:noreply, put_in(state.reservations[reservation_id], reservation)}

          nil ->
            state =
              state
              |> drop_dead_admission_waiter(ref)
              |> drop_dead_evaluation_limit_proof(ref)

            {:noreply, state}
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
    providers =
      state.reservations
      |> Enum.flat_map(fn
        {_reservation_id, %{provider: provider}} when is_pid(provider) -> [provider]
        _reservation -> []
      end)
      |> Enum.uniq()

    state =
      state.reservations
      |> Map.keys()
      |> Enum.reduce(state, fn reservation_id, accumulated ->
        {_reply, settled} = settle_reservation(accumulated, reservation_id, :cleanup)
        settled
      end)

    providers
    |> kill_and_drain()

    %{state | closed?: true, provider_tasks: 0, reservations: %{}}
    |> maybe_complete_evaluation_release()
    |> admit_from_queue()
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

  defp reserve_capability_state(state, environment, name, caller, lease, route) do
    {_limit_total, limit_name} = capability_limits(state.limits, environment)
    count = get_in(state.calls, [environment, name]) || 0
    route_reservation = route_reservation(name, route, limit_name)

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

      is_map(quota_details = quota_details_map(state, environment, name)) ->
        {:error, :limit_exceeded, record_quota_refusal(state, quota_details)}

      route_spent?(state, environment, route_reservation) ->
        {:error, :route_call_limit, record_route_refusal(state, route_reservation)}

      reservation_for_caller?(state.reservations, caller) ->
        {:error, :reservation_held, state}

      llm_output_exceeded?(state, route) ->
        {:error, :llm_output_limit, state}

      llm_ledger_unavailable?(state, route, :total_tokens) ->
        {details, state} = refuse_budget(state, route, :total_tokens)
        {:error, :llm_total_tokens_limit, details, state}

      llm_ledger_unavailable?(state, route, :cost) ->
        {details, state} = refuse_budget(state, route, :cost)
        {:error, :llm_cost_limit, details, state}

      true ->
        reservation_id = make_ref()

        reservation = %{
          id: reservation_id,
          caller: caller,
          environment: environment,
          name: name,
          evaluation_lease: active_evaluation_lease(state, environment),
          caller_ref: Process.monitor(caller),
          provider: nil,
          provider_ref: nil,
          dispatched?: false,
          llm: llm_reservation(state, route)
        }

        state =
          state
          |> update_in([:calls, environment], &Map.put(&1, name, count + 1))
          |> increment_route_calls(environment, route_reservation)
          |> update_in([:totals, environment], &(&1 + 1))
          |> reserve_llm_ledgers(reservation.llm)

        {:ok, reservation_id,
         %{
           state
           | provider_tasks: state.provider_tasks + 1,
             reservations: Map.put(state.reservations, reservation_id, reservation)
         }}
    end
  end

  defp route_reservation(name, %{route_key: route_key, max_calls: max_calls}, limit_name)
       when is_binary(name) and is_binary(route_key) and is_integer(max_calls) and max_calls > 0 and
              is_integer(limit_name) and max_calls < limit_name,
       do: %{key: {name, route_key}, max_calls: max_calls}

  defp route_reservation(_name, _route, _limit_name), do: nil

  defp reservation_for_caller?(reservations, caller) do
    Enum.any?(reservations, fn {_id, reservation} -> reservation.caller == caller end)
  end

  defp llm_output_exceeded?(_state, %{source: "llm", output_tokens: output_tokens})
       when not is_integer(output_tokens),
       do: true

  defp llm_output_exceeded?(state, %{source: "llm", output_tokens: output_tokens}),
    do: output_tokens <= 0 or output_tokens > state.limits.llm_request_output_tokens

  defp llm_output_exceeded?(_state, _route), do: false

  defp llm_ledger_unavailable?(state, route, key) do
    case {Map.fetch!(state.llm_budget, key), llm_bound(route, key)} do
      {nil, _bound} -> false
      {%{state: :overrun}, _bound} -> true
      {_ledger, nil} -> live_llm_route?(route)
      {ledger, bound} -> bound > ledger_remaining(ledger)
    end
  end

  defp llm_bound(%{source: "llm", total_tokens: bound}, :total_tokens)
       when is_integer(bound) and bound in 0..@maximum_integer,
       do: bound

  defp llm_bound(%{source: "llm", cost_microusd: bound}, :cost)
       when is_integer(bound) and bound in 0..@maximum_integer,
       do: bound

  defp llm_bound(_route, _key), do: nil

  defp live_llm_route?(%{source: "llm"}), do: true
  defp live_llm_route?(_route), do: false

  defp llm_reservation(state, route) do
    if live_llm_route?(route) do
      %{
        total_tokens: enabled_bound(state.llm_budget.total_tokens, route, :total_tokens),
        cost: enabled_bound(state.llm_budget.cost, route, :cost)
      }
    end
  end

  defp enabled_bound(nil, _route, _key), do: nil
  defp enabled_bound(_ledger, route, key), do: llm_bound(route, key)

  defp reserve_llm_ledgers(state, nil), do: state

  defp reserve_llm_ledgers(state, reservation) do
    llm_budget =
      Enum.reduce([:total_tokens, :cost], state.llm_budget, fn key, budget ->
        case {Map.fetch!(budget, key), Map.fetch!(reservation, key)} do
          {nil, _amount} -> budget
          {_ledger, nil} -> budget
          {ledger, amount} -> Map.put(budget, key, %{ledger | reserved: ledger.reserved + amount})
        end
      end)

    %{state | llm_budget: llm_budget}
  end

  defp refuse_ledger(state, key) do
    update_in(state.llm_budget[key], fn
      nil -> nil
      ledger -> %{ledger | refused: min(ledger.refused + 1, @maximum_integer)}
    end)
  end

  defp refuse_budget(state, route, key) do
    ledger = Map.fetch!(state.llm_budget, key)
    remaining = ledger_remaining(ledger)
    limit = budget_limit_field(key)
    requested = llm_bound(route, key)

    details =
      %{limit: limit, limit_value: ledger.limit, remaining: remaining}
      |> maybe_put_requested(requested)

    state =
      state
      |> refuse_ledger(key)
      |> record_budget_refusal(details)

    {details, state}
  end

  defp budget_limit_field(:total_tokens), do: :llm_total_tokens
  defp budget_limit_field(:cost), do: :llm_cost_microusd

  defp maybe_put_requested(details, requested) when is_integer(requested) and requested >= 0,
    do: Map.put(details, :requested, requested)

  defp maybe_put_requested(details, _requested), do: details

  defp ledger_remaining(%{state: :overrun}), do: 0

  defp ledger_remaining(ledger),
    do: max(ledger.limit - ledger.charged - ledger.reserved, 0)

  defp route_spent?(_state, _environment, nil), do: false

  defp route_spent?(state, environment, %{key: key, max_calls: max_calls}) do
    (get_in(state.route_calls, [environment, key]) || 0) >= max_calls
  end

  defp increment_route_calls(state, _environment, nil), do: state

  defp increment_route_calls(state, environment, %{key: key}) do
    update_in(
      state,
      [:route_calls, environment],
      &Map.update(&1, key, 1, fn count -> count + 1 end)
    )
  end

  defp matching_route_refusal?(state, alias_name, limit) do
    MapSet.member?(state.route_refusals, {alias_name, limit})
  end

  defp matching_quota_refusal?(state, limit, name, value) do
    MapSet.member?(state.quota_refusals, {limit, name, value})
  end

  defp matching_budget_refusal?(state, limit, limit_value, requested, remaining) do
    MapSet.member?(state.budget_refusals, {limit, limit_value, requested, remaining})
  end

  defp record_route_refusal(state, %{key: {_name, alias_name}, max_calls: max_calls}) do
    %{state | route_refusals: MapSet.put(state.route_refusals, {alias_name, max_calls})}
  end

  defp record_quota_refusal(state, %{limit: limit, name: name, limit_value: value}) do
    %{state | quota_refusals: MapSet.put(state.quota_refusals, {limit, name, value})}
  end

  defp record_budget_refusal(
         state,
         %{limit: limit, limit_value: limit_value, requested: requested, remaining: remaining}
       )
       when limit in @budget_limits and is_integer(limit_value) and limit_value > 0 and
              is_integer(requested) and requested > remaining and is_integer(remaining) and
              remaining >= 0 and remaining <= limit_value do
    %{
      state
      | budget_refusals:
          MapSet.put(state.budget_refusals, {limit, limit_value, requested, remaining})
    }
  end

  defp record_budget_refusal(state, _details), do: state

  defp quota_details_map(state, environment, name) do
    {limit_total, limit_name} = capability_limits(state.limits, environment)
    count = get_in(state.calls, [environment, name]) || 0

    cond do
      count >= limit_name ->
        %{
          limit: quota_limit_field(environment, :per_name),
          name: name,
          limit_value: limit_name
        }

      Map.fetch!(state.totals, environment) >= limit_total ->
        %{
          limit: quota_limit_field(environment, :total),
          name: name,
          limit_value: limit_total
        }

      true ->
        nil
    end
  end

  defp quota_limit_field(:workflow, :total), do: :workflow_capability_calls
  defp quota_limit_field(:workflow, :per_name), do: :workflow_capability_calls_per_name
  defp quota_limit_field(:mission, :total), do: :mission_capability_calls
  defp quota_limit_field(:mission, :per_name), do: :mission_capability_calls_per_name

  defp settle_reservation(state, reservation_id, evidence) do
    case Map.pop(state.reservations, reservation_id) do
      {nil, _reservations} ->
        {{:error, :unknown_reservation}, state}

      {reservation, reservations} ->
        demonitor_reservation(reservation)

        {llm_budget, overruns} =
          settle_llm_budget(state.llm_budget, reservation, evidence)

        next = %{
          state
          | provider_tasks: max(state.provider_tasks - 1, 0),
            reservations: reservations,
            llm_budget: llm_budget
        }

        reply =
          case overruns do
            [] -> {:ok, :settled}
            ordered -> {:ok, {:overrun, ordered}}
          end

        {reply,
         next
         |> maybe_complete_evaluation_release()
         |> admit_from_queue()}
    end
  end

  defp demonitor_reservation(reservation) do
    if is_reference(reservation.caller_ref),
      do: Process.demonitor(reservation.caller_ref, [:flush])

    if is_reference(reservation.provider_ref),
      do: Process.demonitor(reservation.provider_ref, [:flush])
  end

  defp settle_llm_budget(budget, %{llm: nil}, _evidence), do: {budget, []}

  defp settle_llm_budget(budget, %{dispatched?: false, llm: reservation}, _evidence) do
    {release_llm_reservations(budget, reservation), []}
  end

  defp settle_llm_budget(budget, %{dispatched?: true, llm: reservation}, :cleanup) do
    {full_charge_llm_reservations(budget, reservation), []}
  end

  defp settle_llm_budget(
         budget,
         %{dispatched?: true, llm: reservation},
         {:adapter_error, :not_dispatched}
       ) do
    {release_llm_reservations(budget, reservation), []}
  end

  defp settle_llm_budget(
         budget,
         %{dispatched?: true, llm: reservation},
         {:adapter_error, _reason}
       ) do
    {full_charge_llm_reservations(budget, reservation), []}
  end

  defp settle_llm_budget(
         budget,
         %{dispatched?: true, llm: reservation},
         {:adapter_success, usage_evidence}
       ) do
    actuals = settlement_actuals(usage_evidence)

    Enum.reduce([:total_tokens, :cost], {budget, []}, fn key, {ledgers, overruns} ->
      case Map.fetch!(reservation, key) do
        nil ->
          {ledgers, overruns}

        reserved ->
          {ledger, overrun?} =
            settle_ledger(Map.fetch!(ledgers, key), reserved, Map.get(actuals, key))

          overruns = if overrun?, do: overruns ++ [key], else: overruns
          {Map.put(ledgers, key, ledger), overruns}
      end
    end)
  end

  defp settlement_actuals({:valid, usage}) do
    case canonical_usage(usage) do
      {:ok, canonical} ->
        %{
          total_tokens: actual_total_tokens(canonical),
          cost: actual_cost(canonical)
        }

      :error ->
        %{}
    end
  end

  defp settlement_actuals(_missing_or_invalid), do: %{}

  defp actual_total_tokens(%{"input" => input, "output" => output})
       when is_integer(input) and is_integer(output) do
    if input <= @maximum_integer - output, do: input + output, else: :overflow
  end

  defp actual_total_tokens(_usage), do: nil

  defp actual_cost(%{
         "total_cost" => %{"currency" => "USD", "microunits" => microunits}
       }),
       do: microunits

  defp actual_cost(_usage), do: nil

  defp canonical_usage(usage) when is_map(usage) and not is_struct(usage) do
    case LLMUsage.normalize(usage) do
      {:ok, canonical} -> if canonical == usage, do: {:ok, canonical}, else: :error
      {:error, :invalid_llm_usage} -> :error
    end
  end

  defp canonical_usage(_usage), do: :error

  defp settle_ledger(ledger, reserved, nil) do
    ledger = release_from_ledger(ledger, reserved)

    {%{
       ledger
       | charged: bounded_add(ledger.charged, reserved),
         state: if(ledger.state == :overrun, do: :overrun, else: :incomplete)
     }, false}
  end

  defp settle_ledger(ledger, reserved, :overflow) do
    ledger = release_from_ledger(ledger, reserved)
    {%{ledger | charged: @maximum_integer, state: :overrun}, true}
  end

  defp settle_ledger(ledger, reserved, actual) when is_integer(actual) and actual <= reserved do
    ledger = release_from_ledger(ledger, reserved)
    {%{ledger | charged: bounded_add(ledger.charged, actual)}, false}
  end

  defp settle_ledger(ledger, reserved, actual) when is_integer(actual) do
    ledger = release_from_ledger(ledger, reserved)
    {%{ledger | charged: bounded_add(ledger.charged, actual), state: :overrun}, true}
  end

  defp release_llm_reservations(budget, reservation) do
    Enum.reduce([:total_tokens, :cost], budget, fn key, ledgers ->
      case {Map.fetch!(ledgers, key), Map.fetch!(reservation, key)} do
        {nil, _amount} -> ledgers
        {_ledger, nil} -> ledgers
        {ledger, amount} -> Map.put(ledgers, key, release_from_ledger(ledger, amount))
      end
    end)
  end

  defp full_charge_llm_reservations(budget, reservation) do
    Enum.reduce([:total_tokens, :cost], budget, fn key, ledgers ->
      case {Map.fetch!(ledgers, key), Map.fetch!(reservation, key)} do
        {nil, _amount} ->
          ledgers

        {_ledger, nil} ->
          ledgers

        {ledger, amount} ->
          ledger = release_from_ledger(ledger, amount)

          Map.put(ledgers, key, %{
            ledger
            | charged: bounded_add(ledger.charged, amount),
              state: if(ledger.state == :overrun, do: :overrun, else: :incomplete)
          })
      end
    end)
  end

  defp release_from_ledger(ledger, amount),
    do: %{ledger | reserved: max(ledger.reserved - amount, 0)}

  defp bounded_add(left, right), do: min(left + right, @maximum_integer)

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
    %{
      terminal_provider_failure?: state.evaluation_terminal_provider_failure?,
      terminal_host_failure?: state.evaluation_terminal_host_failure?
    }
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

    %{
      state
      | evaluation_lease: nil,
        evaluation_mission: nil,
        evaluation_terminal_provider_failure?: false,
        evaluation_terminal_host_failure?: false
    }
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

  defp reserve_evaluation_now(state, mission, {caller, _tag}, with_limit_proof?) do
    cond do
      state.closed? ->
        {:reply, {:error, :run_closed}, state}

      deadline_expired?(state) ->
        {:reply, {:error, :deadline_expired}, state}

      not grantable?(state) or not :queue.is_empty(state.admission_queue) ->
        {:reply, {:error, :busy}, state}

      state.evaluations >= state.limits.subordinate_evaluations ->
        evaluation_limit_reply(state, caller, with_limit_proof?)

      true ->
        lease = {make_ref(), caller, Process.monitor(caller)}
        continuation = continuation(state, mission)

        {:reply, {:ok, continuation.memory, continuation.history, elem(lease, 0)},
         %{
           record_evaluation(state, mission)
           | evaluation_lease: lease,
             evaluation_mission: mission,
             evaluation_release_waiter: nil,
             evaluation_terminal_provider_failure?: false,
             evaluation_terminal_host_failure?: false
         }}
    end
  end

  defp reserve_evaluation_blocking(
         state,
         mission,
         requested_at,
         {caller, _tag} = from,
         with_limit_proof?
       ) do
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
        evaluation_limit_reply(state, caller, with_limit_proof?)

      grantable?(state) and :queue.is_empty(state.admission_queue) ->
        lease = {make_ref(), caller, Process.monitor(caller)}
        continuation = continuation(state, mission)

        {:reply, {:ok, continuation.memory, continuation.history, elem(lease, 0)},
         %{
           record_evaluation(state, mission)
           | evaluation_lease: lease,
             evaluation_mission: mission,
             evaluation_release_waiter: nil,
             evaluation_terminal_provider_failure?: false,
             evaluation_terminal_host_failure?: false
         }}

      true ->
        # admit_from_queue self-heals the (unreachable by invariant) state of
        # a grantable lease behind a non-empty queue: the FIFO head is
        # admitted, which may be this caller.
        {:noreply,
         admit_from_queue(
           enqueue_admission_waiter(
             state,
             from,
             caller,
             mission,
             admission_deadline,
             with_limit_proof?
           )
         )}
    end
  end

  # The admission bound counts from the caller's request time and is capped
  # by the run deadline.
  defp admission_deadline(state, requested_at) do
    min(
      requested_at + state.limits.evaluation_admission_timeout_ms,
      state.deadline_ms
    )
  end

  defp enqueue_admission_waiter(
         state,
         from,
         caller,
         mission_name,
         deadline_mono,
         with_limit_proof?
       ) do
    monitor_ref = Process.monitor(caller)
    delay = max(deadline_mono - System.monotonic_time(:millisecond), 0)
    timer_ref = Process.send_after(self(), {:admission_deadline, monitor_ref}, delay)

    # The absolute deadline is authoritative; the timer is only its wake-up.
    # A lease release already ahead of the timer message in the mailbox must
    # not grant an expired waiter, so every grant re-checks the deadline.
    waiter = %{
      from: from,
      caller: caller,
      mission_name: mission_name,
      monitor_ref: monitor_ref,
      timer_ref: timer_ref,
      deadline_mono: deadline_mono,
      with_limit_proof?: with_limit_proof?
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
            state = %{state | admission_queue: rest}

            state =
              if waiter.with_limit_proof? do
                {proof, state} =
                  put_evaluation_limit_proof(state, waiter.caller, waiter.monitor_ref)

                resolve_admission_waiter(
                  waiter,
                  {:error, {:limit_exceeded, proof}},
                  demonitor?: false
                )

                state
              else
                resolve_admission_waiter(waiter, {:error, :limit_exceeded})
                state
              end

            admit_from_queue(state)

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
    continuation = continuation(state, waiter.mission_name)

    GenServer.reply(
      waiter.from,
      {:ok, continuation.memory, continuation.history, elem(lease, 0)}
    )

    %{
      record_evaluation(state, waiter.mission_name)
      | evaluation_lease: lease,
        evaluation_mission: waiter.mission_name,
        evaluation_release_waiter: nil,
        evaluation_terminal_provider_failure?: false,
        evaluation_terminal_host_failure?: false
    }
  end

  defp resolve_admission_waiter(waiter, reply, opts \\ []) do
    Process.cancel_timer(waiter.timer_ref)

    if Keyword.get(opts, :demonitor?, true),
      do: Process.demonitor(waiter.monitor_ref, [:flush])

    GenServer.reply(waiter.from, reply)
  end

  defp evaluation_limit_reply(state, _caller, false),
    do: {:reply, {:error, :limit_exceeded}, state}

  defp evaluation_limit_reply(state, caller, true) do
    {proof, state} = put_evaluation_limit_proof(state, caller)
    {:reply, {:error, {:limit_exceeded, proof}}, state}
  end

  defp put_evaluation_limit_proof(state, caller, monitor_ref \\ nil) do
    state = drop_evaluation_limit_proof(state, caller, demonitor?: true)
    monitor_ref = monitor_ref || Process.monitor(caller)
    proof = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    proofs =
      Map.put(state.evaluation_limit_proofs, caller, %{
        proof: proof,
        monitor_ref: monitor_ref
      })

    {proof, %{state | evaluation_limit_proofs: proofs}}
  end

  defp drop_evaluation_limit_proof(state, caller, opts \\ []) do
    case Map.pop(state.evaluation_limit_proofs, caller) do
      {nil, _proofs} ->
        state

      {%{monitor_ref: monitor_ref}, proofs} ->
        if Keyword.get(opts, :demonitor?, false),
          do: Process.demonitor(monitor_ref, [:flush])

        %{state | evaluation_limit_proofs: proofs}
    end
  end

  defp drop_dead_evaluation_limit_proof(state, monitor_ref) do
    case Enum.find(state.evaluation_limit_proofs, fn
           {_caller, %{monitor_ref: ^monitor_ref}} -> true
           _entry -> false
         end) do
      {caller, _proof} -> drop_evaluation_limit_proof(state, caller)
      nil -> state
    end
  end

  defp take_admission_waiter(state, monitor_ref) do
    waiters = :queue.to_list(state.admission_queue)

    case Enum.split_with(waiters, &(&1.monitor_ref == monitor_ref)) do
      {[waiter], rest} -> {waiter, %{state | admission_queue: :queue.from_list(rest)}}
      {[], _waiters} -> {nil, state}
    end
  end

  defp reservation_by_provider_ref(reservations, ref) do
    Enum.find_value(reservations, fn {reservation_id, reservation} ->
      if reservation.provider_ref == ref, do: {reservation_id, reservation}
    end)
  end

  defp reservation_by_caller_ref(reservations, ref) do
    Enum.find_value(reservations, fn {reservation_id, reservation} ->
      if reservation.caller_ref == ref, do: {reservation_id, reservation}
    end)
  end

  defp continuation(state, mission_name),
    do: Map.get(state.continuations, mission_name, %{memory: %{}, history: [], revision: 0})

  defp record_evaluation(state, @workflow_continuation),
    do: %{state | evaluations: state.evaluations + 1}

  defp record_evaluation(state, mission_name) do
    %{
      state
      | evaluations: state.evaluations + 1,
        evaluations_by_mission:
          Map.update(state.evaluations_by_mission, mission_name, 1, &(&1 + 1))
    }
  end

  defp mission_and_total_bytes(continuations, mission_name, key, candidate, limit) do
    own = RetainedSize.bytes_with_cap(candidate, limit)

    others = continuations |> Map.delete(mission_name) |> continuations_total(key, limit)

    if is_integer(own) and is_integer(others), do: own + others, else: :oversized
  end

  defp continuations_total(continuations, key, limit) do
    Enum.reduce(continuations, 0, &add_retained_size(&1, &2, key, limit))
  end

  defp add_retained_size({_name, held}, acc, key, limit) do
    case {acc, RetainedSize.bytes_with_cap(Map.fetch!(held, key), limit)} do
      {left, right} when is_integer(left) and is_integer(right) -> left + right
      _ -> :oversized
    end
  end

  defp unavailable?(state),
    do: state.closed? or deadline_expired?(state)

  defp maybe_record_replay_miss(state, nil), do: state

  defp maybe_record_replay_miss(state, request_hash),
    do: %{state | replay_misses: MapSet.put(state.replay_misses, request_hash)}

  defp valid_settlement_evidence?({:adapter_success, {:valid, usage}}),
    do: is_map(usage) and not is_struct(usage)

  defp valid_settlement_evidence?({:adapter_success, evidence})
       when evidence in [:missing, :invalid],
       do: true

  defp valid_settlement_evidence?({:adapter_error, reason})
       when reason in [:provider_error, :worker_exit, :timeout, :cancelled, :not_dispatched],
       do: true

  defp valid_settlement_evidence?(_evidence), do: false

  defp deadline_expired?(state),
    do: System.monotonic_time(:millisecond) >= state.deadline_ms

  defp event_sink_ready?(nil), do: true
  defp event_sink_ready?(event_sink), do: EventSinkState.ready?(event_sink)

  defp capability_limits(limits, :workflow),
    do: {limits.workflow_capability_calls, limits.workflow_capability_calls_per_name}

  defp capability_limits(limits, :mission),
    do: {limits.mission_capability_calls, limits.mission_capability_calls_per_name}

  defp put_capability_refusal(refusals, key) do
    limit = SafeMetadata.capability_refusal_map_limit()

    cond do
      Map.has_key?(refusals, key) ->
        Map.update!(refusals, key, &(&1 + 1))

      map_size(Map.delete(refusals, "$overflow")) < limit ->
        Map.put(refusals, key, 1)

      true ->
        Map.update(refusals, "$overflow", 1, &(&1 + 1))
    end
  end

  defp usage_projection(state) do
    %{
      closed?: state.closed?,
      remaining_ms: max(state.deadline_ms - System.monotonic_time(:millisecond), 0),
      capability_calls: state.calls,
      subordinate_evaluations: state.evaluations,
      evaluations_by_mission: state.evaluations_by_mission |> Enum.sort() |> Map.new(),
      subordinate_source_checks: state.source_checks,
      protocol_errors: state.protocol_errors,
      agent_protocol_errors: state.agent_protocol_errors,
      capability_refusals: state.capability_refusals,
      llm_budget: llm_budget_projection(state.llm_budget),
      llm_spend: LLMUsageSummary.spend(state.llm_usage),
      evaluation_memory_bytes:
        continuations_total(state.continuations, :memory, state.limits.evaluation_memory_bytes),
      evaluation_history_bytes:
        continuations_total(state.continuations, :history, state.limits.evaluation_history_bytes),
      evaluation_continuation_bytes: continuation_bytes(state),
      evaluation_missions:
        state.continuations
        |> Map.keys()
        |> Enum.reject(&(&1 == @workflow_continuation))
        |> Enum.sort(),
      evaluation_busy?: not is_nil(state.evaluation_lease)
    }
  end

  defp new_ledger(nil), do: nil

  defp new_ledger(limit) when is_integer(limit) and limit in 1..@maximum_integer do
    %{limit: limit, reserved: 0, charged: 0, refused: 0, state: :available}
  end

  defp llm_budget_projection(budget) do
    %{
      "total_tokens" => total_tokens_projection(budget.total_tokens),
      "cost" => cost_projection(budget.cost)
    }
  end

  defp total_tokens_projection(nil), do: nil

  defp total_tokens_projection(ledger) do
    %{
      "state" => Atom.to_string(ledger.state),
      "limit" => ledger.limit,
      "reserved" => ledger.reserved,
      "charged" => ledger.charged,
      "remaining" => ledger_remaining(ledger),
      "refused" => ledger.refused
    }
  end

  defp cost_projection(nil), do: nil

  defp cost_projection(ledger) do
    %{
      "state" => Atom.to_string(ledger.state),
      "currency" => "USD",
      "limit_microusd" => ledger.limit,
      "reserved_microusd" => ledger.reserved,
      "charged_microusd" => ledger.charged,
      "remaining_microusd" => ledger_remaining(ledger),
      "refused" => ledger.refused
    }
  end

  defp continuation_summary(state) do
    memory_bytes =
      continuations_total(state.continuations, :memory, state.limits.evaluation_memory_bytes)

    history_bytes =
      continuations_total(state.continuations, :history, state.limits.evaluation_history_bytes)

    %{
      defined_count:
        Enum.reduce(state.continuations, 0, fn {_n, c}, acc -> acc + map_size(c.memory) end),
      history_count:
        Enum.reduce(state.continuations, 0, fn {_n, c}, acc -> acc + length(c.history) end),
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
