defmodule PtcRunnerMcp.Sessions.Session do
  @moduledoc """
  Per-session GenServer for a bounded PTC-Lisp REPL environment.

  The GenServer owns committed session state only. Evaluation itself runs in
  the caller process via the `begin_eval/4` -> `PtcRunner.Lisp.run/2` ->
  `commit_eval/4` protocol so MCP routing can cancel the worker without
  killing the session process.
  """

  use GenServer

  alias PtcRunner.PtcToolProtocol
  alias PtcRunnerMcp.Limits, as: McpLimits
  alias PtcRunnerMcp.PayloadMetrics
  alias PtcRunnerMcp.Sessions.{Limits, Owner, Projection, Registry}

  @bytes_per_word :erlang.system_info(:wordsize)
  @min_max_heap_words 233

  defstruct [
    :id,
    :owner,
    :title,
    :mode,
    :created_at,
    :updated_at,
    :expires_at,
    :eval,
    :limits,
    :registry,
    ttl_timer: nil,
    idle_timer: nil,
    turn: 0,
    memory: %{},
    turn_history: [],
    prints: [],
    tool_calls: [],
    upstream_calls: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          owner: Owner.t(),
          title: String.t() | nil,
          mode: :read_only | :write_capable,
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          expires_at: DateTime.t(),
          turn: non_neg_integer(),
          memory: map(),
          turn_history: [term()],
          prints: [String.t()],
          tool_calls: [map()],
          upstream_calls: [map()],
          eval: nil | map(),
          limits: Limits.t()
        }

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @impl GenServer
  def init(opts) do
    now = DateTime.utc_now()
    ttl_ms = Keyword.fetch!(opts, :ttl_ms)
    expires_at = DateTime.add(now, ttl_ms, :millisecond)
    limits = Keyword.fetch!(opts, :limits)

    state = %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      owner: Keyword.fetch!(opts, :owner),
      title: Keyword.get(opts, :title),
      mode: Keyword.get(opts, :mode, :read_only),
      created_at: now,
      updated_at: now,
      expires_at: expires_at,
      limits: limits,
      registry: Keyword.get(opts, :registry, Registry)
    }

    {:ok, schedule_timers(state, ttl_ms)}
  end

  @doc "Return a start response for this session."
  @spec start_response(GenServer.server(), Owner.t()) :: {:ok, map()} | {:error, map()}
  def start_response(pid, owner) do
    GenServer.call(pid, {:start_response, owner})
  end

  @doc """
  Atomically reserve this session for eval and return committed state snapshot.
  """
  @spec begin_eval(GenServer.server(), Owner.t(), term(), map()) :: {:ok, map()} | {:error, map()}
  def begin_eval(pid, owner, request_id, opts \\ %{}) do
    GenServer.call(pid, {:begin_eval, owner, request_id, self(), opts})
  end

  @doc "Validate that an eval may start without reserving the session."
  @spec reserve_eval(GenServer.server(), Owner.t(), term(), map()) ::
          {:ok, map()} | {:error, map()}
  def reserve_eval(pid, owner, request_id, opts \\ %{}) do
    GenServer.call(pid, {:reserve_eval, owner, request_id, opts})
  end

  @doc "Attach the eval worker process to a previously reserved eval."
  @spec attach_eval_worker(GenServer.server(), Owner.t(), term(), pid()) :: :ok | {:error, map()}
  def attach_eval_worker(pid, owner, request_id, worker) when is_pid(worker) do
    GenServer.call(pid, {:attach_eval_worker, owner, request_id, worker})
  end

  @doc "Commit or reject an eval result produced from a prior snapshot."
  @spec commit_eval(GenServer.server(), Owner.t(), term(), {:ok, map()} | {:error, map()}, map()) ::
          {:ok, map()} | {:error, map()}
  def commit_eval(pid, owner, request_id, result, opts \\ %{}) do
    GenServer.call(pid, {:commit_eval, owner, request_id, result, opts}, :infinity)
  end

  @doc "Abort an in-flight eval without committing state."
  @spec abort_eval(GenServer.server(), Owner.t(), term(), term()) :: :ok | {:error, map()}
  def abort_eval(pid, owner, request_id, reason \\ :aborted) do
    GenServer.call(pid, {:abort_eval, owner, request_id, reason})
  end

  @doc "Inspect the last committed state."
  @spec inspect_view(GenServer.server(), Owner.t(), String.t()) :: {:ok, map()} | {:error, map()}
  def inspect_view(pid, owner, view \\ "overview") do
    GenServer.call(pid, {:inspect, owner, view})
  end

  @doc "Return metadata-only state summary without refreshing idle timers."
  @spec summary(GenServer.server(), Owner.t()) :: {:ok, map()} | {:error, map()}
  def summary(pid, owner) do
    GenServer.call(pid, {:summary, owner})
  end

  @doc "Forget bindings and/or clear bounded histories."
  @spec forget(GenServer.server(), Owner.t(), map()) :: {:ok, map()} | {:error, map()}
  def forget(pid, owner, opts) when is_map(opts) do
    GenServer.call(pid, {:forget, owner, opts})
  end

  @doc "Close the session. A running eval worker is killed."
  @spec close(GenServer.server(), Owner.t(), term()) :: {:ok, map()} | {:error, map()}
  def close(pid, owner, reason \\ "closed") do
    GenServer.call(pid, {:close, owner, reason})
  end

  @impl GenServer
  def handle_call({:start_response, owner}, _from, state) do
    case Owner.check(state.owner, owner) do
      :ok -> {:reply, {:ok, Projection.start(state)}, touch(state)}
      {:error, reason} -> {:reply, {:error, owner_error(reason)}, state}
    end
  end

  def handle_call({:begin_eval, owner, request_id, worker, opts}, _from, state) do
    reserve_eval(owner, request_id, opts, state, worker)
  end

  def handle_call({:reserve_eval, owner, request_id, opts}, _from, state) do
    reserve_eval(owner, request_id, opts, state, nil)
  end

  def handle_call({:attach_eval_worker, owner, request_id, worker}, _from, state) do
    with :ok <- Owner.check(state.owner, owner),
         {:ok, eval} <- matching_eval(state, request_id) do
      ref = Process.monitor(worker)
      state = %{state | eval: %{eval | worker: worker, monitor: ref}}
      {:reply, :ok, state}
    else
      {:error, :session_owner_mismatch} ->
        {:reply, {:error, owner_error(:session_owner_mismatch)}, state}

      {:error, :stale_eval} ->
        response = Projection.error(:session_not_found, "eval request is no longer active")
        {:reply, {:error, response}, state}
    end
  end

  def handle_call({:commit_eval, owner, request_id, result, opts}, _from, state) do
    with :ok <- Owner.check(state.owner, owner),
         {:ok, eval} <- matching_eval(state, request_id) do
      state = clear_eval_monitor(state, eval)
      previous = eval.snapshot

      case result do
        {:ok, step} ->
          commit_success(state, previous, step, opts)

        {:error, step} ->
          upstream_calls = Map.get(opts, :upstream_calls, [])

          response =
            Projection.eval_lisp_error(state, step)
            |> maybe_put_upstream_calls(upstream_calls)
            |> decorate_ptc_metrics(upstream_calls)

          :telemetry.execute([:ptc_runner_mcp, :session, :eval, :stop], %{turn: state.turn}, %{
            session_id: state.id,
            owner_hash: Owner.fingerprint(state.owner),
            mode: state.mode,
            reason: response["reason"]
          })

          {:reply, {:error, response}, touch(state)}
      end
    else
      {:error, :session_owner_mismatch} ->
        {:reply, {:error, owner_error(:session_owner_mismatch)}, state}

      {:error, :stale_eval} ->
        response = Projection.error(:session_not_found, "eval request is no longer active")
        {:reply, {:error, response}, state}
    end
  end

  def handle_call({:abort_eval, owner, request_id, reason}, _from, state) do
    with :ok <- Owner.check(state.owner, owner),
         {:ok, eval} <- matching_eval(state, request_id) do
      state = clear_eval_monitor(state, eval)

      :telemetry.execute([:ptc_runner_mcp, :session, :eval, :stop], %{turn: state.turn}, %{
        session_id: state.id,
        owner_hash: Owner.fingerprint(state.owner),
        mode: state.mode,
        reason: reason
      })

      {:reply, :ok, touch(state)}
    else
      {:error, :session_owner_mismatch} ->
        {:reply, {:error, owner_error(:session_owner_mismatch)}, state}

      {:error, :stale_eval} ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:inspect, owner, view}, _from, state) do
    case Owner.check(state.owner, owner) do
      :ok ->
        view = normalize_view(view)
        response = Projection.inspect_view(state, view)

        :telemetry.execute([:ptc_runner_mcp, :session, :inspect], %{turn: state.turn}, %{
          session_id: state.id,
          owner_hash: Owner.fingerprint(state.owner),
          mode: state.mode
        })

        {:reply, {:ok, response}, touch(state)}

      {:error, reason} ->
        {:reply, {:error, owner_error(reason)}, state}
    end
  end

  def handle_call({:summary, owner}, _from, state) do
    case Owner.check(state.owner, owner) do
      :ok -> {:reply, {:ok, Projection.session_summary(state)}, state}
      {:error, reason} -> {:reply, {:error, owner_error(reason)}, state}
    end
  end

  def handle_call({:forget, owner, opts}, _from, state) do
    with :ok <- Owner.check(state.owner, owner),
         :ok <- ensure_not_busy(state),
         {:ok, clear} <- parse_clear(Map.get(opts, "clear") || Map.get(opts, :clear)) do
      bindings = Map.get(opts, "bindings") || Map.get(opts, :bindings) || []
      binding_names = Enum.map(List.wrap(bindings), &to_string/1)
      memory = maybe_clear_memory(state.memory, clear)
      memory = Limits.drop_bindings(memory, binding_names)

      removed_bindings =
        state.memory
        |> Map.keys()
        |> Enum.map(&to_string/1)
        |> Enum.filter(&(&1 in binding_names))

      state =
        state
        |> Map.put(:memory, memory)
        |> maybe_clear_histories(clear)
        |> Map.put(:updated_at, DateTime.utc_now())
        |> reset_idle_timer()

      response = Projection.forget(state, removed_bindings, clear)

      :telemetry.execute([:ptc_runner_mcp, :session, :forget], %{turn: state.turn}, %{
        session_id: state.id,
        owner_hash: Owner.fingerprint(state.owner),
        mode: state.mode
      })

      {:reply, {:ok, response}, state}
    else
      {:error, :session_owner_mismatch} ->
        {:reply, {:error, owner_error(:session_owner_mismatch)}, state}

      {:error, :session_busy} ->
        {:reply, {:error, session_busy(state)}, state}

      {:error, :session_args_error} ->
        {:reply, {:error, args_error("invalid clear target")}, state}
    end
  end

  def handle_call({:close, owner, reason}, _from, state) do
    case Owner.check(state.owner, owner) do
      :ok ->
        cancel_worker(state.eval)
        Registry.mark_closed(state.id, reason, state.registry)
        response = Projection.close(state, reason)

        :telemetry.execute([:ptc_runner_mcp, :session, :close], %{turn: state.turn}, %{
          session_id: state.id,
          owner_hash: Owner.fingerprint(state.owner),
          mode: state.mode,
          reason: reason
        })

        {:stop, :normal, {:ok, response}, state}

      {:error, reason} ->
        {:reply, {:error, owner_error(reason)}, state}
    end
  end

  defp reserve_eval(owner, request_id, opts, state, worker) do
    with :ok <- Owner.check(state.owner, owner),
         :ok <- ensure_not_busy(state),
         :ok <- validate_program(Map.get(opts, :program)) do
      ref = if is_pid(worker), do: Process.monitor(worker)

      snapshot = %{
        session_id: state.id,
        request_id: request_id,
        memory: state.memory,
        turn_history: state.turn_history,
        turn: state.turn,
        mode: state.mode,
        limits: state.limits
      }

      eval = %{request_id: request_id, worker: worker, monitor: ref, snapshot: snapshot}
      state = state |> cancel_idle_timer() |> Map.put(:eval, eval)

      :telemetry.execute([:ptc_runner_mcp, :session, :eval, :start], %{turn: state.turn}, %{
        session_id: state.id,
        owner_hash: Owner.fingerprint(state.owner),
        mode: state.mode
      })

      {:reply, {:ok, snapshot}, state}
    else
      {:error, :session_owner_mismatch} ->
        {:reply, {:error, owner_error(:session_owner_mismatch)}, state}

      {:error, :session_busy} ->
        {:reply, {:error, session_busy(state)}, state}

      {:error, :session_args_error} ->
        {:reply, {:error, args_error("program must be a string")}, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{eval: %{monitor: ref}} = state) do
    :telemetry.execute([:ptc_runner_mcp, :session, :eval, :stop], %{turn: state.turn}, %{
      session_id: state.id,
      owner_hash: Owner.fingerprint(state.owner),
      mode: state.mode,
      reason: reason
    })

    {:noreply, %{state | eval: nil} |> reset_idle_timer()}
  end

  def handle_info(:ttl_expired, state) do
    cancel_worker(state.eval)
    Registry.mark_closed(state.id, :ttl_expired, state.registry)

    :telemetry.execute([:ptc_runner_mcp, :session, :evict], %{turn: state.turn}, %{
      session_id: state.id,
      owner_hash: Owner.fingerprint(state.owner),
      mode: state.mode,
      reason: :ttl_expired
    })

    {:stop, :normal, state}
  end

  def handle_info(:idle_expired, %{eval: eval} = state) when not is_nil(eval) do
    {:noreply, state}
  end

  def handle_info(:idle_expired, state) do
    Registry.mark_closed(state.id, :idle_expired, state.registry)

    :telemetry.execute([:ptc_runner_mcp, :session, :evict], %{turn: state.turn}, %{
      session_id: state.id,
      owner_hash: Owner.fingerprint(state.owner),
      mode: state.mode,
      reason: :idle_expired
    })

    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp commit_success(state, previous, step, opts) do
    # `(return v)` wraps step.return in a sentinel; in single-shot session
    # context that's identical to a final expression value. Unwrap once
    # here so everything downstream (turn history `*1`, the `result`
    # preview, signature validation) sees the actual value — mirrors the
    # stateless renderer in `PtcRunnerMcp.Sandbox.execute/4`.
    step = unwrap_return_sentinel(step)

    {turn_history, history_notices} =
      Limits.cap_turn_history(state.turn_history, step.return, state.limits)

    upstream_calls = Map.get(opts, :upstream_calls, [])

    candidate = %{
      memory: step.memory || %{},
      turn_history: turn_history,
      prints: Limits.append_prints(state.prints, step.prints || [], state.limits),
      tool_calls: Limits.append_tool_calls(state.tool_calls, step.tool_calls || [], state.limits),
      upstream_calls:
        Limits.append_upstream_calls(state.upstream_calls, upstream_calls, state.limits)
    }

    case Limits.validate_candidate(candidate, state.limits) do
      :ok ->
        parsed_signature = Map.get(opts, :parsed_signature)

        case validate_return_value(step.return, parsed_signature) do
          :no_contract ->
            committed =
              state
              |> Map.merge(candidate)
              |> Map.update!(:turn, &(&1 + 1))
              |> Map.put(:updated_at, DateTime.utc_now())
              |> reset_idle_timer()

            response =
              Projection.eval_success(previous, committed, step, history_notices)
              |> maybe_put_upstream_calls(upstream_calls)
              |> decorate_ptc_metrics(upstream_calls)

            :telemetry.execute(
              [:ptc_runner_mcp, :session, :eval, :stop],
              %{turn: committed.turn},
              %{
                session_id: committed.id,
                owner_hash: Owner.fingerprint(committed.owner),
                mode: committed.mode
              }
            )

            {:reply, {:ok, response}, committed}

          {:ok, validated} ->
            committed =
              state
              |> Map.merge(candidate)
              |> Map.update!(:turn, &(&1 + 1))
              |> Map.put(:updated_at, DateTime.utc_now())
              |> reset_idle_timer()

            # Always emit `validated` when a contract was supplied — even
            # when the value is `nil`. Mirrors the stateless renderer,
            # which surfaces "validated": null distinct from "no contract".
            response =
              Projection.eval_success(previous, committed, step, history_notices)
              |> Map.put("validated", validated)
              |> maybe_put_upstream_calls(upstream_calls)
              |> decorate_ptc_metrics(upstream_calls)

            :telemetry.execute(
              [:ptc_runner_mcp, :session, :eval, :stop],
              %{turn: committed.turn},
              %{
                session_id: committed.id,
                owner_hash: Owner.fingerprint(committed.owner),
                mode: committed.mode
              }
            )

            {:reply, {:ok, response}, committed}

          {:error, message} ->
            # Validation failure: the program executed cleanly but its
            # return value didn't match the caller-supplied schema. Treat
            # like `session_limit_exceeded` — reject the eval, do NOT
            # commit the candidate state. Side effects (upstream calls)
            # already happened and are surfaced as usual.
            response =
              Projection.error(
                :validation_error,
                message,
                %{session: Projection.inspect_view(state, "limits")["session"]}
              )
              |> maybe_put_upstream_calls(upstream_calls)
              |> decorate_ptc_metrics(upstream_calls)

            :telemetry.execute(
              [:ptc_runner_mcp, :session, :eval, :stop],
              %{turn: state.turn},
              %{
                session_id: state.id,
                owner_hash: Owner.fingerprint(state.owner),
                mode: state.mode,
                reason: :validation_error
              }
            )

            {:reply, {:error, response}, touch(state)}
        end

      {:error, detail} ->
        response =
          Projection.error(
            :session_limit_exceeded,
            "session persisted-state limit exceeded; eval was not committed",
            %{detail: detail, session: Projection.inspect_view(state, "limits")["session"]}
          )
          |> maybe_put_upstream_calls(upstream_calls)
          |> decorate_ptc_metrics(upstream_calls)

        :telemetry.execute([:ptc_runner_mcp, :session, :eval, :stop], %{turn: state.turn}, %{
          session_id: state.id,
          owner_hash: Owner.fingerprint(state.owner),
          mode: state.mode,
          reason: :session_limit_exceeded
        })

        {:reply, {:error, response}, touch(state)}
    end
  end

  defp clear_eval_monitor(state, eval) do
    if eval.monitor, do: Process.demonitor(eval.monitor, [:flush])
    %{state | eval: nil}
  end

  defp maybe_put_upstream_calls(payload, []), do: payload
  defp maybe_put_upstream_calls(payload, calls), do: Map.put(payload, "upstream_calls", calls)

  # `(return v)` is unwrapped at the top of commit_success so step.return
  # is already the raw value here — no extra unwrapping needed.
  defp unwrap_return_sentinel(%{return: {:__ptc_return__, value}} = step),
    do: %{step | return: value}

  defp unwrap_return_sentinel(step), do: step

  # No signature supplied — skip validation; commit_success won't emit a
  # `validated` field. Distinct from `{:ok, nil}` (a contract supplied
  # that validated to null, which DOES emit "validated": null).
  defp validate_return_value(_return, nil), do: :no_contract

  defp validate_return_value(return, {:signature, _params, return_type} = parsed_signature) do
    typed = PtcToolProtocol.atomize_value(return, return_type)
    definition = %{parsed_signature: parsed_signature}

    case PtcToolProtocol.validate_return(definition, typed) do
      :ok ->
        case PtcToolProtocol.to_json_value(typed) do
          {:ok, encoded} ->
            {:ok, encoded}

          {:error, reason} ->
            {:error, "validated value: #{reason}"}
        end

      {:error, errors} when is_list(errors) ->
        {:error, format_validation_errors(errors)}
    end
  end

  defp format_validation_errors(errors) do
    Enum.map_join(errors, "; ", fn
      %{path: path, message: message} ->
        path_str = if path == [], do: "return", else: "return." <> Enum.join(path, ".")
        "#{path_str}: #{message}"

      other ->
        inspect(other)
    end)
  end

  # Mirrors the stateless `ptc_lisp_execute` decoration in `Tools`: when the
  # eval made at least one upstream call, attach a per-eval `ptc_metrics`
  # block so session workflows have the same payload-reduction visibility
  # as one-shot programs. Non-aggregator runs drain to `[]` and skip this.
  defp decorate_ptc_metrics(payload, []), do: payload

  defp decorate_ptc_metrics(payload, entries) when is_map(payload) and is_list(entries) do
    Map.put(
      payload,
      "ptc_metrics",
      PayloadMetrics.build(result_field_bytes(payload), prints_field_bytes(payload), entries)
    )
  end

  defp result_field_bytes(%{"result" => r}) when is_binary(r), do: byte_size(r)
  defp result_field_bytes(_), do: 0

  defp prints_field_bytes(%{"prints" => p}) when is_list(p) do
    case Jason.encode(p) do
      {:ok, json} -> byte_size(json)
      {:error, _} -> 0
    end
  end

  defp prints_field_bytes(_), do: 0

  defp matching_eval(%{eval: %{request_id: request_id} = eval}, request_id), do: {:ok, eval}
  defp matching_eval(_state, _request_id), do: {:error, :stale_eval}

  defp ensure_not_busy(%{eval: nil}), do: :ok
  defp ensure_not_busy(_state), do: {:error, :session_busy}

  defp validate_program(program) when is_binary(program), do: :ok
  defp validate_program(_program), do: {:error, :session_args_error}

  defp owner_error(:session_owner_mismatch) do
    Projection.error(:session_owner_mismatch, "caller does not own this session")
  end

  defp args_error(message), do: Projection.error(:session_args_error, message)

  defp session_busy(state) do
    Projection.error(:session_busy, "an eval is already running for this session", %{
      session_id: state.id
    })
  end

  defp normalize_view(view)
       when view in ["overview", "memory", "prints", "tool_calls", "history", "limits"] do
    view
  end

  defp normalize_view(_view), do: "overview"

  defp parse_clear(nil), do: {:ok, []}

  defp parse_clear(values) when is_list(values) do
    clear = Enum.map(values, &to_string/1)
    valid = ["memory", "history", "prints", "tool_calls", "upstream_calls"]

    if Enum.all?(clear, &(&1 in valid)) do
      {:ok, clear}
    else
      {:error, :session_args_error}
    end
  end

  defp parse_clear(_other), do: {:error, :session_args_error}

  defp maybe_clear_memory(memory, clear) do
    if "memory" in clear, do: %{}, else: memory
  end

  defp maybe_clear_histories(state, clear) do
    state
    |> maybe_put_clear(:turn_history, "history", clear)
    |> maybe_put_clear(:prints, "prints", clear)
    |> maybe_put_clear(:tool_calls, "tool_calls", clear)
    |> maybe_put_clear(:upstream_calls, "upstream_calls", clear)
  end

  defp maybe_put_clear(state, field, target, clear) do
    if target in clear, do: Map.put(state, field, []), else: state
  end

  defp touch(state) do
    state
    |> Map.put(:updated_at, DateTime.utc_now())
    |> reset_idle_timer()
  end

  defp reset_idle_timer(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: Process.send_after(self(), :idle_expired, state.limits.max_idle_ms)}
  end

  defp cancel_idle_timer(%{idle_timer: nil} = state), do: state

  defp cancel_idle_timer(%{idle_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | idle_timer: nil}
  end

  defp schedule_timers(state, ttl_ms) do
    %{state | ttl_timer: Process.send_after(self(), :ttl_expired, ttl_ms)}
    |> reset_idle_timer()
  end

  defp cancel_worker(nil), do: :ok

  defp cancel_worker(%{worker: worker}) when is_pid(worker) do
    if Process.alive?(worker), do: Process.exit(worker, :kill)
    :ok
  end

  @doc false
  @spec lisp_opts(map(), String.t(), map()) :: keyword()
  def lisp_opts(snapshot, _program, opts) when is_map(snapshot) and is_map(opts) do
    [
      memory: snapshot.memory,
      turn_history: snapshot.turn_history,
      context: Map.get(opts, :context, %{}),
      tools: Map.get(opts, :tools, []),
      tool_cache: %{},
      caller: :mcp,
      profile: Map.get(opts, :profile, :mcp_no_tools),
      timeout: Map.get(opts, :timeout, McpLimits.program_timeout_ms()),
      max_heap:
        Map.get(
          opts,
          :max_heap,
          max(@min_max_heap_words, div(McpLimits.program_memory_limit_bytes(), @bytes_per_word))
        ),
      strict_data: true,
      link: true
    ]
    |> maybe_put(:catalog_exec, Map.get(opts, :catalog_exec))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
