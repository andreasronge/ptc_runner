defmodule PtcRunner.Lisp.Eval.Parallel do
  @moduledoc """
  Evaluator-owned semantics for `pmap` and `pcalls`.

  This module adapts evaluated Lisp callables into worker callbacks, captures
  each worker's effects and child metadata, classifies evaluator failures, and
  assembles the outer parallel-operation record. Process scheduling, heap caps,
  deadlines, cancellation, and monitor cleanup belong to `ParallelRunner`.
  """

  alias PtcRunner.Lisp.ChildResult
  alias PtcRunner.Lisp.Eval.Abort
  alias PtcRunner.Lisp.Eval.Apply
  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Eval.Effects
  alias PtcRunner.Lisp.Eval.HostContext
  alias PtcRunner.Lisp.Eval.ParallelRunner
  alias PtcRunner.Lisp.Eval.ParallelRunner.Envelope
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Runtime.Callable
  alias PtcRunner.Lisp.Runtime.Collection.Normalize
  alias PtcRunner.Lisp.UntrustedRenderer

  @hof_callback_error :__ptc_hof_callback_error__

  @type do_eval ::
          (term(), EvalContext.t() ->
             {:ok, term(), EvalContext.t()}
             | {:error, term()}
             | {:error, term(), EvalContext.t()})

  @doc """
  Executes an already-evaluated `pmap` callable over evaluated collections.

  Type/shape validation performed before the runner starts returns an ordinary
  evaluator error and records no parallel call. Once scheduling begins, every
  success or failure appends one outer operation record.
  """
  @spec eval_pmap(term(), [term()], EvalContext.t(), do_eval()) :: term()
  def eval_pmap(fn_value, collection_values, %EvalContext{} = eval_context, do_eval)
      when is_function(do_eval, 2) do
    if keyword_runtime?(fn_value) and single_plain_map?(collection_values) do
      {:error,
       {:type_error, "pmap: keyword accessor requires a list of maps, got a single map",
        [fn_value, hd(collection_values)]}}
    else
      started_at = System.monotonic_time(:millisecond)
      timestamp = DateTime.utc_now()
      arguments = pmap_arguments(collection_values)
      deadline = parallel_deadline(eval_context)
      worker_context = %{eval_context | pmap_deadline: deadline}
      callable = pmap_callable(fn_value, worker_context, do_eval)

      run(
        :pmap,
        arguments,
        eval_context,
        deadline,
        started_at,
        timestamp,
        fn argument_list ->
          capture_worker(worker_context, do_eval, fn -> Callable.call(callable, argument_list) end)
        end
      )
    end
  end

  @doc """
  Executes already-evaluated zero-arity `pcalls` function values.

  Callable/arity validation is a preflight step and therefore records no
  parallel call when it fails.
  """
  @spec eval_pcalls([term()], EvalContext.t(), do_eval()) :: term()
  def eval_pcalls(function_values, %EvalContext{} = eval_context, do_eval)
      when is_function(do_eval, 2) do
    started_at = System.monotonic_time(:millisecond)
    timestamp = DateTime.utc_now()
    deadline = parallel_deadline(eval_context)
    worker_context = %{eval_context | pmap_deadline: deadline}

    try do
      thunks = Enum.map(function_values, &pcalls_thunk(&1, worker_context, do_eval))

      run(
        :pcalls,
        thunks,
        eval_context,
        deadline,
        started_at,
        timestamp,
        fn thunk -> capture_worker(worker_context, do_eval, thunk) end
      )
    rescue
      error in RuntimeError -> {:error, {:pcalls_error, Exception.message(error)}}
    end
  end

  defp run(
         type,
         work_items,
         %EvalContext{} = eval_context,
         deadline,
         started_at,
         timestamp,
         worker_fun
       ) do
    runner_result =
      ParallelRunner.run(work_items, worker_fun,
        worker_max_heap: eval_context.worker_max_heap,
        max_concurrency: bounded_concurrency(eval_context.pmap_max_concurrency),
        budget: eval_context.parallel_budget,
        deadline_mono: deadline
      )

    finalize(
      runner_result,
      type,
      length(work_items),
      timestamp,
      System.monotonic_time(:millisecond) - started_at,
      eval_context
    )
  end

  defp capture_worker(%EvalContext{} = context, do_eval, fun) do
    ChildResult.take()

    case HostContext.capture_effects(context, do_eval, fun) do
      {:ok, value, effects} ->
        success_envelope(value, effects)

      {:error, kind, reason, stacktrace, effects} ->
        failure_envelope(captured_failure(kind, reason, stacktrace), effects)
    end
  rescue
    error -> failure_envelope({:worker_message, Exception.message(error)}, Effects.empty())
  end

  # Merge every retained worker exactly once, then append the outer operation
  # record. `ParallelRunner` has already sorted the envelopes by input index.
  defp finalize(
         {status, envelopes},
         type,
         count,
         timestamp,
         duration_ms,
         %EvalContext{} = eval_context
       )
       when status in [:ok, :error] and is_list(envelopes) do
    successful = Enum.filter(envelopes, &Envelope.success?/1)
    success_count = length(successful)

    worker_effects =
      envelopes
      |> Enum.map(& &1.effects)
      |> Effects.merge_ordered()

    parallel_call = %{
      type: type,
      count: count,
      child_trace_ids: envelopes |> Enum.map(& &1.child_trace_id) |> Enum.reject(&is_nil/1),
      child_steps: envelopes |> Enum.map(& &1.child_step) |> Enum.reject(&is_nil/1),
      timestamp: timestamp,
      duration_ms: duration_ms,
      success_count: success_count,
      error_count: count - success_count
    }

    final_context =
      eval_context
      |> EvalContext.merge_parallel_effects(worker_effects)
      |> EvalContext.append_pmap_call(parallel_call)

    case status do
      :ok ->
        values = Enum.map(successful, fn %Envelope{outcome: {:ok, value}} -> value end)
        {:ok, values, final_context}

      :error ->
        %Envelope{index: index, outcome: {:error, worker_reason}} =
          Enum.find(envelopes, &(not Envelope.success?(&1)))

        reason =
          worker_reason
          |> classify_worker_failure(type, index)
          |> refresh_contract_capability_activity(final_context)

        Abort.error!(reason, final_context)
    end
  end

  defp refresh_contract_capability_activity(
         {:prelude_contract_error, message, details},
         %EvalContext{} = context
       )
       when is_binary(message) and is_map(details) do
    details = Map.put(details, :capability_activity?, EvalContext.tool_activity?(context))
    {:prelude_contract_error, message, details}
  end

  defp refresh_contract_capability_activity(reason, %EvalContext{}), do: reason

  defp classify_worker_failure({:worker_message, message}, type, index),
    do: parallel_worker_error(type, index, message)

  defp classify_worker_failure({:worker_abort, reason}, type, index) do
    reason
    |> parallel_abort_error(type, index)
    |> classify_runner_error(type, index)
  end

  defp classify_worker_failure({:worker_control, signal}, type, index),
    do: parallel_worker_error(type, index, "#{signal} called inside #{type}")

  defp classify_worker_failure(reason, type, index),
    do: classify_runner_error(reason, type, index)

  defp classify_runner_error(:memory_exceeded, _type, _index),
    do: {:memory_exceeded, "a parallel worker exceeded its per-worker heap cap", nil}

  defp classify_runner_error(:timeout, _type, _index),
    do: {:timeout, "the parallel operation exceeded its deadline", nil}

  defp classify_runner_error({:memory_exceeded, _detail}, _type, _index),
    do: {:memory_exceeded, "a parallel worker exceeded its per-worker heap cap", nil}

  defp classify_runner_error({:timeout, _detail}, _type, _index),
    do: {:timeout, "the parallel operation exceeded its deadline", nil}

  defp classify_runner_error({reason, _message, nil} = error, _type, _index)
       when reason in [:memory_exceeded, :timeout, :parallel_capacity_exceeded],
       do: error

  defp classify_runner_error(:parallel_capacity_exceeded, _type, _index),
    do:
      {:parallel_capacity_exceeded,
       "the parallel worker budget is exhausted; reduce nesting or collection size", nil}

  defp classify_runner_error({:parallel_capacity_exceeded, _message}, type, index),
    do: classify_runner_error(:parallel_capacity_exceeded, type, index)

  defp classify_runner_error({:runtime_error, detail}, type, index),
    do: {parallel_error_type(type), "parallel worker #{index} crashed: #{inspect(detail)}"}

  defp classify_runner_error(
         {:prelude_contract_error, _message, _details} = error,
         _type,
         _index
       ),
       do: error

  defp classify_runner_error({:pmap_error, _} = error, _type, _index), do: error
  defp classify_runner_error({:pcalls_error, _, _} = error, _type, _index), do: error

  defp classify_runner_error(other, type, _index),
    do: {parallel_error_type(type), inspect(other)}

  defp captured_failure(
         :error,
         %Abort{outcome: {:error, {:prelude_contract_error, _, _} = reason, _context}},
         _stacktrace
       ),
       do: reason

  defp captured_failure(
         :error,
         %Abort{outcome: {:error, {:tool_error, tool_name, message}, _context}},
         _stacktrace
       ),
       do: {:worker_message, UntrustedRenderer.tool_failure(tool_name, message)}

  defp captured_failure(
         :error,
         %Abort{outcome: {:error, reason, _context}},
         _stacktrace
       ),
       do: {:worker_abort, reason}

  defp captured_failure(
         :error,
         %Abort{outcome: {:control, signal, _value, _context}},
         _stacktrace
       ),
       do: {:worker_control, signal}

  defp captured_failure(:error, error, _stacktrace),
    do: {:worker_message, Exception.message(error)}

  defp captured_failure(:throw, signal, _stacktrace),
    do: {:worker_message, "worker threw #{inspect(signal)}"}

  defp captured_failure(kind, reason, _stacktrace),
    do: {:worker_message, "worker #{kind}: #{inspect(reason)}"}

  defp parallel_abort_error({reason, message, nil}, _type, _index)
       when reason in [:memory_exceeded, :timeout, :parallel_capacity_exceeded],
       do: {reason, message}

  defp parallel_abort_error({@hof_callback_error, message}, type, index)
       when is_binary(message),
       do: parallel_worker_error(type, index, message)

  defp parallel_abort_error({_reason, message, _data}, type, index) when is_binary(message),
    do: parallel_worker_error(type, index, message)

  defp parallel_abort_error({_reason, message}, type, index) when is_binary(message),
    do: parallel_worker_error(type, index, message)

  defp parallel_abort_error(reason, type, index),
    do: parallel_worker_error(type, index, inspect(reason))

  defp parallel_worker_error(:pmap, _index, message), do: {:pmap_error, message}
  defp parallel_worker_error(:pcalls, index, message), do: {:pcalls_error, index, message}

  defp parallel_error_type(:pmap), do: :pmap_error
  defp parallel_error_type(:pcalls), do: :pcalls_error

  defp success_envelope(value, %Effects{} = effects) do
    {trace_id, child_step} = take_child_result()
    Envelope.success(value, effects: effects, child_trace_id: trace_id, child_step: child_step)
  end

  defp failure_envelope(reason, %Effects{} = effects) do
    {trace_id, child_step} = take_child_result()
    Envelope.failure(reason, effects: effects, child_trace_id: trace_id, child_step: child_step)
  end

  defp take_child_result do
    case ChildResult.take() do
      {trace_id, child_step} -> {trace_id, child_step}
      nil -> {nil, nil}
    end
  end

  defp pmap_callable(value, %EvalContext{} = context, do_eval) do
    if keyword_runtime?(value), do: value, else: Apply.closure_to_fun(value, context, do_eval)
  end

  defp pcalls_thunk(
         {:closure, [], _body, _closure_env, _turn_history, _metadata} = closure,
         %EvalContext{} = context,
         do_eval
       ) do
    Apply.closure_to_fun(closure, context, do_eval)
  end

  defp pcalls_thunk(
         {:closure, params, _body, _closure_env, _turn_history, _metadata},
         %EvalContext{},
         _do_eval
       ) do
    raise "pcalls requires zero-arity thunks, got function with arity #{length(params)}"
  end

  defp pcalls_thunk(fun, %EvalContext{}, _do_eval) when is_function(fun, 0), do: fun

  defp pcalls_thunk(fun, %EvalContext{}, _do_eval) when is_function(fun) do
    {:arity, arity} = Function.info(fun, :arity)
    raise "pcalls requires zero-arity thunks, got function with arity #{arity}"
  end

  defp pcalls_thunk(value, %EvalContext{}, _do_eval) do
    raise "pcalls requires callable thunks, got: #{inspect(value)}"
  end

  defp pmap_arguments([collection]) do
    collection |> Normalize.to_seq() |> Enum.map(&[&1])
  end

  defp pmap_arguments(collections) do
    collections
    |> Enum.map(&Normalize.to_seq/1)
    |> Enum.zip_with(& &1)
  end

  defp bounded_concurrency(concurrency) when is_integer(concurrency) and concurrency > 0,
    do: concurrency

  defp bounded_concurrency(_concurrency), do: 1

  defp parallel_deadline(%EvalContext{pmap_deadline: deadline}) when is_integer(deadline),
    do: deadline

  defp parallel_deadline(%EvalContext{pmap_timeout: timeout}),
    do: System.monotonic_time(:millisecond) + timeout

  defp keyword_runtime?(value) when is_atom(value),
    do: not is_boolean(value) and not is_nil(value)

  defp keyword_runtime?(%LispKeyword{}), do: true
  defp keyword_runtime?(_value), do: false

  defp single_plain_map?([value]) when is_map(value), do: not is_struct(value)
  defp single_plain_map?(_values), do: false
end
