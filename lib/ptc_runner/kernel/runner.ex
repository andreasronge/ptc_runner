defmodule PtcRunner.Kernel.Runner do
  @moduledoc """
  Internal implementation of `PtcRunner.Kernel.run/2`.

  It owns run-state lifetime, workflow evaluation, runtime-tool wiring,
  subordinate-evaluation routing, canonical lifecycle events, public value
  projection, and terminal error normalization.
  """

  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.Error
  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Program
  alias PtcRunner.Kernel.Result
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Java.Project, as: JavaProject
  alias PtcRunner.Lisp.RetainedSize
  alias PtcRunner.Lisp.TrustedTool

  @spec run(binary(), RunConfig.t()) :: {:ok, Result.t()} | {:error, Error.t()}
  @doc "Executes one validated run configuration and always tears down run state."
  def run(entry_source, %RunConfig{} = config) when is_binary(entry_source) do
    with :ok <- entry_source_within_limit(entry_source, config.limits),
         {:ok, state} <- RunState.start(config.limits) do
      try do
        run_with_events(entry_source, config, state)
      after
        RunState.close(state)
        RunState.stop(state)
      end
    else
      {:error, reason} -> configuration_error(reason, %{})
    end
  after
    RunConfig.close_provider_resources(config)
  end

  defp run_with_events(entry_source, config, state) do
    case Events.emit(state, config.event_sink, "run-started", config.run_started_metadata) do
      :ok ->
        result = run_workflow(entry_source, config, state)
        result = apply_terminal_failure(result, state)
        _ = emit_dropped_summary(state, config.event_sink)
        usage = usage_with_events(state, config.event_sink)

        case Events.emit(state, config.event_sink, "run-stopped", %{
               outcome: outcome(result),
               reason: terminal_reason(result),
               usage: usage
             }) do
          :ok ->
            put_result_usage(result, usage_with_events(state, config.event_sink))

          {:error, :event_sink_error} ->
            event_sink_error(usage_with_events(state, config.event_sink))
        end

      {:error, :event_sink_error} ->
        event_sink_error(RunState.usage(state))
    end
  end

  defp run_workflow(entry_source, config, state) do
    timeout_ms = min(config.limits.workflow_timeout_ms, RunState.remaining_ms(state))
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    evaluation_id = Events.id("workflow-evaluation")
    started_ms = System.monotonic_time(:millisecond)

    case Events.emit(state, config.event_sink, "evaluation-started", %{
           evaluation_id: evaluation_id,
           environment: :workflow
         }) do
      :ok ->
        result = execute_workflow(entry_source, config, state, timeout_ms, deadline_ms)
        _ = maybe_emit_workflow_limit(state, config.event_sink, result)

        _ =
          Events.emit(state, config.event_sink, "evaluation-stopped", %{
            evaluation_id: evaluation_id,
            environment: :workflow,
            status: outcome(result),
            duration_ms: Events.duration_ms(started_ms)
          })

        result

      {:error, :event_sink_error} ->
        event_sink_error(RunState.usage(state))
    end
  end

  defp execute_workflow(entry_source, config, state, timeout_ms, deadline_ms) do
    opts = [
      context: config.input,
      tools: workflow_tools(config, state),
      prelude: bundle_prelude(config.workflow_environment),
      timeout: timeout_ms,
      compile_timeout: timeout_ms,
      run_deadline_ms: deadline_ms,
      max_heap: config.limits.workflow_heap_words,
      max_program_bytes: config.limits.entry_source_bytes,
      filter_context: false,
      caller: :kernel
    ]

    case Lisp.run_native(entry_source, opts) do
      {:ok, %{return: {:__ptc_fail__, _value}}} ->
        {:error,
         %Error{
           kind: :workflow_failed,
           reason: :explicit_failure,
           details: %{},
           usage: RunState.usage(state)
         }}

      {:ok, step} ->
        case JavaProject.project(kernel_return_value(step.return), :kernel_json) do
          {:ok, projected_java} ->
            value = project_kernel_value(projected_java)

            if terminal_result_within_limit?(value, config.limits.terminal_result_bytes) do
              {:ok,
               %Result{
                 value: value,
                 usage: RunState.usage(state),
                 evaluation_memory: RunState.evaluation_memory_summary(state)
               }}
            else
              {:error,
               %Error{
                 kind: :limit_exceeded,
                 reason: :terminal_result_exceeded,
                 details: %{},
                 usage: RunState.usage(state)
               }}
            end

          {:error, reason} ->
            {:error,
             %Error{
               kind: :workflow_failed,
               reason: :java_projection_error,
               details: %{projection_error: inspect(reason, limit: 10)},
               usage: RunState.usage(state)
             }}
        end

      {:error, step} ->
        {:error,
         %Error{
           kind: workflow_error_kind(step.fail.reason),
           reason: step.fail.reason,
           details: %{message: String.slice(step.fail.message || "workflow failed", 0, 4_096)},
           usage: RunState.usage(state)
         }}
    end
  end

  defp workflow_tools(config, state) do
    tools =
      Map.new(config.workflow_environment.capabilities, fn {name, _capability} ->
        {name,
         fn arguments ->
           Dispatcher.dispatch(
             state,
             :workflow,
             config.workflow_environment,
             name,
             arguments,
             config.limits.workflow_timeout_ms,
             config.event_sink,
             config.inspection_sink
           )
         end}
      end)

    tools
    |> Map.merge(
      RuntimeTools.tools(state, config.workflow_environment, config.event_sink, :workflow)
    )
    |> Map.put(
      "kernel-eval",
      RuntimeTools.instrument(
        state,
        config.event_sink,
        :workflow,
        "kernel-eval",
        RuntimeTools.kernel_eval(
          state,
          config.mission_environment,
          config.limits,
          config.event_sink,
          config.inspection_sink
        )
      )
    )
    |> Map.put(
      "kernel-mission-inventory",
      RuntimeTools.instrument(
        state,
        config.event_sink,
        :workflow,
        "kernel-mission-inventory",
        RuntimeTools.mission_inventory(state, config.mission_inventory.rendered)
      )
    )
    |> Map.put(
      "kernel-mission-model-context",
      RuntimeTools.instrument(
        state,
        config.event_sink,
        :workflow,
        "kernel-mission-model-context",
        RuntimeTools.mission_model_context(state, config.mission_inventory.model_rendered)
      )
    )
    |> Map.new(fn {name, callback} -> {name, %TrustedTool{function: callback}} end)
  end

  defp bundle_prelude(%{bundle: %{prelude: prelude}}), do: prelude
  defp bundle_prelude(_environment), do: nil

  defp entry_source_within_limit(source, limits) do
    if byte_size(source) <= limits.entry_source_bytes,
      do: :ok,
      else: {:error, :entry_source_exceeded}
  end

  defp kernel_return_value({:__ptc_return__, value}), do: value
  defp kernel_return_value(value), do: value

  defp project_kernel_value(%Program{} = program),
    do: %{program?: true, byte_size: program.byte_size, digest: program.digest}

  defp project_kernel_value(value) when is_list(value),
    do: Enum.map(value, &project_kernel_value/1)

  defp project_kernel_value(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, item} -> {project_kernel_value(key), project_kernel_value(item)} end)
  end

  defp project_kernel_value(value), do: Lisp.externalize_value(value)

  defp terminal_result_within_limit?(value, limit) do
    case {RetainedSize.bytes_with_cap(value, limit), safe_encoded_size(value)} do
      {bytes, encoded} when is_integer(bytes) and bytes <= limit and encoded <= limit -> true
      _ -> false
    end
  end

  defp safe_encoded_size(value) do
    :erlang.external_size(value)
  rescue
    _exception -> :infinity
  end

  defp outcome({:ok, _result}), do: :ok
  defp outcome({:error, _error}), do: :error
  defp terminal_reason({:ok, _result}), do: nil
  defp terminal_reason({:error, %Error{reason: reason}}), do: reason

  defp usage_with_events(state, sink),
    do: Map.put(RunState.usage(state), :events_dropped, EventSink.dropped(sink))

  defp put_result_usage({:ok, %Result{} = result}, usage), do: {:ok, %{result | usage: usage}}
  defp put_result_usage({:error, %Error{} = error}, usage), do: {:error, %{error | usage: usage}}

  defp event_sink_error(usage) do
    {:error,
     %Error{
       kind: :event_sink_error,
       reason: :event_sink_error,
       details: %{},
       usage: usage
     }}
  end

  defp apply_terminal_failure(result, state) do
    case RunState.terminal_failure(state) do
      nil ->
        result

      %{kind: :event_sink_error} ->
        event_sink_error(RunState.usage(state))

      %{kind: kind, reason: reason} ->
        {:error,
         %Error{
           kind: kind,
           reason: reason,
           details: %{},
           usage: RunState.usage(state)
         }}
    end
  end

  defp emit_dropped_summary(state, sink) do
    case EventSink.dropped(sink) do
      dropped when map_size(dropped) == 0 -> :ok
      dropped -> Events.emit(state, sink, "events-dropped", %{counts: dropped})
    end
  end

  defp maybe_emit_workflow_limit(
         state,
         sink,
         {:error, %Error{kind: :limit_exceeded, reason: reason}}
       ),
       do: Events.emit(state, sink, "limit-exceeded", %{reason: reason})

  defp maybe_emit_workflow_limit(_state, _sink, _result), do: :ok

  defp workflow_error_kind(reason)
       when reason in [:timeout, :memory_exceeded, :program_too_large], do: :limit_exceeded

  defp workflow_error_kind(_reason), do: :workflow_failed

  defp configuration_error(reason, usage),
    do: {:error, %Error{kind: :configuration_error, reason: reason, details: %{}, usage: usage}}
end
