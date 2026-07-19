defmodule PtcRunner.Lisp.Eval.HostContext do
  @moduledoc """
  Adapts plain host callbacks to evaluator context and effect semantics.

  Host functions cannot thread an `Eval.Context` through their return value.
  This module owns the scoped process-local binding that lets runtime helpers
  recover that context, and the capture brackets used when a host callback may
  evaluate Lisp. Expression evaluation, callable dispatch, and effect algebra
  remain owned by their respective evaluator modules.
  """

  alias PtcRunner.Lisp.Eval.Abort
  alias PtcRunner.Lisp.Eval.Capture
  alias PtcRunner.Lisp.Eval.Context
  alias PtcRunner.Lisp.Eval.Effects

  @key :__ptc_host_callback_context__

  @spec run_outcome(Context.t(), function(), (-> term())) :: term()
  def run_outcome(%Context{} = context, do_eval, fun)
      when is_function(do_eval, 2) and is_function(fun, 0) do
    Capture.run_outcome(context, fn -> with_context(context, do_eval, fun) end)
  end

  @spec run_value(Context.t(), function(), (-> term())) :: Capture.value_result()
  def run_value(%Context{} = context, do_eval, fun)
      when is_function(do_eval, 2) and is_function(fun, 0) do
    Capture.run_value(context, fn ->
      with_materialized_context(context, do_eval, fn _materialized_context -> fun.() end)
    end)
  end

  @spec capture_effects(Context.t(), function(), (-> term())) ::
          {:ok, term(), Effects.t()}
          | {:error, :error | :exit | :throw, term(), Exception.stacktrace(), Effects.t()}
  def capture_effects(%Context{} = context, do_eval, fun)
      when is_function(do_eval, 2) and is_function(fun, 0) do
    baseline = Capture.materialize_context(context)

    case run_value(baseline, do_eval, fun) do
      {:ok, value, final_context} ->
        {:ok, value, Context.parallel_effects(final_context, baseline)}

      {:raise, kind, reason, stacktrace, final_context} ->
        {:error, kind, reason, stacktrace, Context.parallel_effects(final_context, baseline)}
    end
  end

  @spec with_context(Context.t(), function(), (-> term())) :: term()
  def with_context(%Context{} = context, do_eval, fun)
      when is_function(do_eval, 2) and is_function(fun, 0) do
    previous = Process.get(@key, :none)
    Process.put(@key, {context, do_eval})

    try do
      fun.()
    after
      if previous == :none, do: Process.delete(@key), else: Process.put(@key, previous)
    end
  end

  @spec with_materialized_context(Context.t(), function(), (Context.t() -> term())) :: term()
  def with_materialized_context(%Context{} = context, do_eval, fun)
      when is_function(do_eval, 2) and is_function(fun, 1) do
    materialized_context = Capture.materialize_context(context)
    with_context(materialized_context, do_eval, fn -> fun.(materialized_context) end)
  end

  @spec without_context((-> term())) :: term()
  def without_context(fun) when is_function(fun, 0) do
    previous = Process.delete(@key)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous)
    end
  end

  @spec current() :: {Context.t(), function()} | nil
  def current do
    case Process.get(@key) do
      {%Context{} = context, do_eval} when is_function(do_eval, 2) -> {context, do_eval}
      _other -> nil
    end
  end

  @spec error!(term()) :: no_return()
  def error!(reason) do
    case current() do
      {%Context{} = context, _do_eval} -> Abort.error!(reason, context)
      nil -> raise ArgumentError, "evaluator host callback aborted: #{inspect(reason)}"
    end
  end
end
