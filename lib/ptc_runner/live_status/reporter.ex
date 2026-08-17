defmodule PtcRunner.LiveStatus.Reporter do
  @moduledoc false

  # Per-run live status reporter.
  #
  # Owns a poll timer and a set of telemetry subscriptions; every tick it
  # assembles one frame from public run state and POSTs it to the Viewer.
  # Reads only — `RunState.usage/1`, `ParallelBudget.held/available`, and
  # `Process.info(pid, :total_heap_size)` — so no second accounting exists.
  #
  # Heap is reported as observed samples plus a high-water mark, never a
  # fill fraction: BEAM heaps grow in generations and the max_heap_size
  # check runs only at GC, so the last observed sample before a kill can
  # sit far below the ceiling.

  use GenServer

  require Logger

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Lisp.Eval.ParallelBudget
  alias PtcRunner.LiveStatus.Target

  @tick_ms 300
  @activity_limit 40
  @heap_samples_limit 100
  @telemetry_events [
    [:ptc_runner, :sandbox, :armed],
    [:ptc_runner, :parallel, :budget],
    [:ptc_runner, :capability, :start],
    [:ptc_runner, :capability, :stop],
    [:ptc_runner, :lisp, :execute, :start],
    [:ptc_runner, :lisp, :execute, :stop]
  ]

  @spec start(term(), struct(), struct()) :: {:ok, pid()} | {:error, term()}
  def start(target, config, run_state) when is_binary(target) do
    GenServer.start(__MODULE__, %{target: target, config: config, run_state: run_state})
  end

  def start(target, config, run_state) do
    if Target.valid?(target),
      do: GenServer.start(__MODULE__, %{target: target, config: config, run_state: run_state}),
      else: {:error, :invalid_live_status_target}
  end

  @spec complete(pid(), atom(), term()) :: :ok
  def complete(pid, phase, reason) do
    GenServer.call(pid, {:complete, phase, reason}, 5_000)
  catch
    :exit, _reason -> :ok
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _reason -> :ok
  end

  @doc false
  def handle_telemetry(event, measurements, metadata, reporter) do
    case reporter do
      {reporter_pid, live_run} when is_pid(reporter_pid) and is_pid(live_run) ->
        if Map.get(metadata, :live_run) == live_run do
          send(
            reporter_pid,
            {:live_telemetry, event, measurements, Map.delete(metadata, :live_run)}
          )
        end

      _invalid ->
        :ok
    end

    :ok
  end

  @impl GenServer
  def init(args) do
    handler_id = {__MODULE__, self()}

    :telemetry.attach_many(
      handler_id,
      @telemetry_events,
      &__MODULE__.handle_telemetry/4,
      {self(), args.run_state.pid}
    )

    state = %{
      target: normalize_target(args.target),
      run_state: args.run_state,
      config: args.config,
      run_id: run_id(args.config),
      label: label(args.config, args.target),
      handler_id: handler_id,
      started_ms: System.monotonic_time(:millisecond),
      seq: 0,
      phase: "running",
      outcome_reason: nil,
      sandbox: nil,
      heap_peak: 0,
      heap_baseline: nil,
      heap_ceiling: nil,
      heap_samples: [],
      budget: nil,
      activity: [],
      last_usage: nil,
      post_failed?: false,
      viewer_token: viewer_token(args.target)
    }

    Process.send_after(self(), :tick, 0)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:complete, phase, reason}, _from, state) do
    state = %{
      state
      | phase: to_string(phase),
        outcome_reason: format_reason(reason)
    }

    state = state |> sample_heap() |> post_frame()
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    state = state |> sample_heap() |> post_frame()
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, state}
  end

  def handle_info({:live_telemetry, event, measurements, metadata}, state),
    do: {:noreply, apply_telemetry(state, event, measurements, metadata)}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{sandbox: %{pid: pid}} = state),
    do: {:noreply, %{state | sandbox: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  defp apply_telemetry(state, [:ptc_runner, :sandbox, :armed], measurements, metadata) do
    if state.sandbox, do: Process.demonitor(state.sandbox.ref, [:flush])
    ref = Process.monitor(metadata.pid)

    sandbox = %{
      pid: metadata.pid,
      ref: ref,
      baseline_words: measurements.baseline_words,
      ceiling_words: measurements.ceiling_words
    }

    # Ceiling/baseline survive the sandbox process so ended runs keep context.
    state = %{
      state
      | heap_baseline: measurements.baseline_words,
        heap_ceiling: measurements.ceiling_words
    }

    sample_heap(%{state | sandbox: sandbox})
  end

  defp apply_telemetry(state, [:ptc_runner, :parallel, :budget], _measurements, metadata),
    do: %{state | budget: metadata.budget}

  defp apply_telemetry(state, [:ptc_runner, :capability, :start], _measurements, metadata) do
    push_activity(state, %{
      kind: "capability",
      name: metadata.name,
      status: "start",
      duration_ms: nil
    })
  end

  defp apply_telemetry(state, [:ptc_runner, :capability, :stop], measurements, metadata) do
    push_activity(state, %{
      kind: "capability",
      name: metadata.name,
      status: to_string(metadata.status),
      duration_ms: measurements.duration_ms
    })
  end

  defp apply_telemetry(state, [:ptc_runner, :lisp, :execute, :start], _measurements, _metadata),
    do: push_activity(state, %{kind: "evaluation", name: nil, status: "start", duration_ms: nil})

  defp apply_telemetry(state, [:ptc_runner, :lisp, :execute, :stop], measurements, metadata) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    push_activity(state, %{
      kind: "evaluation",
      name: nil,
      status: to_string(Map.get(metadata, :outcome, :ok)),
      duration_ms: duration_ms
    })
  end

  defp apply_telemetry(state, _event, _measurements, _metadata), do: state

  defp push_activity(state, entry) do
    entry = Map.put(entry, :t, elapsed_ms(state))
    %{state | activity: Enum.take([entry | state.activity], @activity_limit)}
  end

  defp sample_heap(%{sandbox: nil} = state), do: state

  defp sample_heap(%{sandbox: sandbox} = state) do
    case Process.info(sandbox.pid, :total_heap_size) do
      {:total_heap_size, words} ->
        samples = Enum.take([words | state.heap_samples], @heap_samples_limit)
        %{state | heap_samples: samples, heap_peak: max(state.heap_peak, words)}

      nil ->
        state
    end
  end

  defp post_frame(state) do
    usage = safe_usage(state.run_state) || state.last_usage
    frame = frame(state, usage)
    state = %{state | seq: state.seq + 1, last_usage: usage}

    case request(state.target, state.run_id, frame, state.viewer_token) do
      :ok ->
        state

      :error ->
        unless state.post_failed? do
          Logger.warning("live status: configured Viewer target is unreachable")
        end

        %{state | post_failed?: true}
    end
  end

  defp request(%Target{} = target, run_id, frame, _viewer_token),
    do: Target.report(target, run_id, frame)

  defp request(viewer_url, run_id, frame, viewer_token) when is_binary(viewer_url) do
    url = viewer_url <> "/api/live/runs/" <> run_id

    case Req.post(url,
           json: frame,
           headers: authorization_headers(viewer_token),
           retry: false,
           connect_options: [timeout: 500],
           receive_timeout: 1_000
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      _other -> :error
    end
  rescue
    _exception -> :error
  end

  defp authorization_headers(token) when is_binary(token),
    do: [{"authorization", "Bearer " <> token}]

  defp authorization_headers(_token), do: []

  defp normalize_target(%Target{} = target), do: target
  defp normalize_target(viewer_url), do: String.trim_trailing(viewer_url, "/")

  defp viewer_token(%Target{}), do: nil
  defp viewer_token(_viewer_url), do: System.get_env("PTC_VIEWER_TOKEN")

  defp format_reason(nil), do: nil
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp frame(state, usage) do
    limits = state.config.limits

    %{
      run_id: state.run_id,
      label: state.label,
      seq: state.seq,
      phase: state.phase,
      outcome_reason: state.outcome_reason,
      elapsed_ms: elapsed_ms(state),
      remaining_ms: usage && Map.get(usage, :remaining_ms),
      limits: %{
        run_duration_ms: limits.run_duration_ms,
        workflow_timeout_ms: limits.workflow_timeout_ms,
        parallel_timeout_ms: limits.parallel_timeout_ms,
        subordinate_evaluations: limits.subordinate_evaluations,
        workflow_capability_calls: limits.workflow_capability_calls,
        workflow_capability_calls_per_name: limits.workflow_capability_calls_per_name,
        mission_capability_calls: limits.mission_capability_calls,
        evaluation_memory_bytes: limits.evaluation_memory_bytes,
        evaluation_history_bytes: limits.evaluation_history_bytes,
        live_provider_tasks: limits.live_provider_tasks
      },
      usage:
        usage &&
          Map.take(usage, [
            :subordinate_evaluations,
            :capability_calls,
            :evaluation_memory_bytes,
            :evaluation_history_bytes,
            :protocol_errors,
            :evaluation_busy?
          ]),
      heap: heap_frame(state),
      parallel: parallel_frame(state.budget),
      activity: state.activity
    }
  end

  defp heap_frame(%{heap_peak: 0}), do: nil

  defp heap_frame(state) do
    %{
      observed_words: List.first(state.heap_samples),
      peak_words: state.heap_peak,
      baseline_words: state.heap_baseline,
      ceiling_words: state.heap_ceiling,
      samples: Enum.reverse(state.heap_samples)
    }
  end

  defp parallel_frame(nil), do: nil

  defp parallel_frame(budget) do
    %{held: ParallelBudget.held(budget), capacity: budget.capacity}
  rescue
    _exception -> nil
  end

  defp safe_usage(run_state) do
    RunState.usage(run_state)
  catch
    :exit, _reason -> nil
  end

  defp elapsed_ms(state), do: System.monotonic_time(:millisecond) - state.started_ms

  defp run_id(config) do
    case EventSink.identity(config.event_sink) do
      {:ok, %{run_id: run_id}} -> run_id
      _error -> "run-live-" <> Integer.to_string(System.unique_integer([:positive]))
    end
  end

  defp label(config, target) do
    case target_label(target) do
      name when is_binary(name) and name != "" -> name
      _absent -> config_label(config)
    end
  end

  defp target_label(%Target{} = target), do: Target.label(target)
  defp target_label(_viewer_url), do: System.get_env("PTC_VIEWER_LABEL")

  defp config_label(config) do
    case config.labels do
      # Manifest names may already be privacy-hashed by the CLI path; a hash
      # is useless to a human, so fall back to the run id in that case.
      %{"name" => "sha256:" <> _hash} -> nil
      %{"name" => name} when is_binary(name) -> name
      _other -> nil
    end
  end
end
