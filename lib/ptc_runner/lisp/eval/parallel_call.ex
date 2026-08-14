defmodule PtcRunner.Lisp.Eval.ParallelCall do
  @moduledoc """
  Dispatches indirect `pmap` and `pcalls` calls to the parallel evaluator.

  The adapter accepts already-evaluated arguments. Once a special builtin has
  been selected, it must not be resolved through the user namespace again:
  saved and namespace-qualified builtin values remain the builtin even when a
  same-named user definition exists.
  """

  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Eval.Parallel

  @pmap_arity_message "expected (pmap f coll) or (pmap f c1 c2 ...)"

  @type operation :: :pmap | :pcalls
  @type do_eval ::
          (term(), EvalContext.t() ->
             {:ok, term(), EvalContext.t()} | {:error, term()})

  @spec invoke(operation(), [term()], EvalContext.t(), do_eval()) ::
          {:ok, term(), EvalContext.t()} | {:error, term()}
  def invoke(:pmap, [function, collection | collections], %EvalContext{} = context, do_eval)
      when is_function(do_eval, 2) do
    Parallel.eval_pmap(function, [collection | collections], context, do_eval)
  end

  def invoke(:pmap, _arguments, %EvalContext{}, do_eval) when is_function(do_eval, 2) do
    {:error, {:invalid_arity, :pmap, @pmap_arity_message}}
  end

  def invoke(:pcalls, functions, %EvalContext{} = context, do_eval)
      when is_list(functions) and is_function(do_eval, 2) do
    Parallel.eval_pcalls(functions, context, do_eval)
  end
end
