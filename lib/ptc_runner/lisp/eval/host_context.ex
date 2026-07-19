defmodule PtcRunner.Lisp.Eval.HostContext do
  @moduledoc false

  alias PtcRunner.Lisp.Eval.Abort
  alias PtcRunner.Lisp.Eval.Context

  @key :__ptc_host_callback_context__

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
