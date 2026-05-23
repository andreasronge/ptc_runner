defmodule PtcRunner.Lisp.RuntimeCallable do
  @moduledoc """
  Runtime callable for effectful qualified Lisp symbols.

  Values such as `tool/search` are not plain functions: they need an evaluator
  context to enforce limits, record traces, and call the configured runtime
  executor. The persisted value only carries the qualified name. A short-lived
  bound form is created at application time for higher-order runtime calls.
  """

  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.ExecutionError

  defstruct [:namespace, :name, :eval_ctx, :do_eval]

  @type namespace :: :tool
  @type t :: %__MODULE__{
          namespace: namespace(),
          name: atom(),
          eval_ctx: EvalContext.t() | nil,
          do_eval:
            (term(), EvalContext.t() -> {:ok, term(), EvalContext.t()} | {:error, term()})
            | nil
        }

  @spec new(namespace(), atom()) :: t()
  def new(namespace, name) do
    %__MODULE__{namespace: namespace, name: name}
  end

  @spec bind(t(), EvalContext.t(), function()) :: t()
  def bind(%__MODULE__{} = callable, %EvalContext{} = eval_ctx, do_eval)
      when is_function(do_eval, 2) do
    %{callable | eval_ctx: eval_ctx, do_eval: do_eval}
  end

  @spec label(t()) :: String.t()
  def label(%__MODULE__{namespace: namespace, name: name}), do: "#{namespace}/#{name}"

  @spec invoke(t(), [term()], EvalContext.t()) ::
          {:ok, term(), EvalContext.t()} | {:error, term()}
  def invoke(%__MODULE__{} = callable, args, %EvalContext{} = eval_ctx) do
    with {:ok, ast} <- core_call(callable, args) do
      callable.do_eval.(ast, eval_ctx)
    end
  end

  @spec call(t(), [term()]) :: term()
  def call(%__MODULE__{eval_ctx: %EvalContext{}, do_eval: do_eval} = callable, args)
      when is_function(do_eval, 2) do
    call_with_context(callable, args, callable.eval_ctx, do_eval)
  end

  def call(%__MODULE__{} = callable, args) do
    case Process.get(:__ptc_runtime_callable_context) do
      {%EvalContext{} = eval_ctx, do_eval} when is_function(do_eval, 2) ->
        call_with_context(callable, args, eval_ctx, do_eval)

      _ ->
        raise ExecutionError,
          reason: :runtime_error,
          message: "#{label(callable)} is not bound to the current evaluation context"
    end
  end

  @spec with_context(EvalContext.t(), function(), (-> term())) :: term()
  def with_context(%EvalContext{} = eval_ctx, do_eval, fun)
      when is_function(do_eval, 2) and is_function(fun, 0) do
    previous = Process.get(:__ptc_runtime_callable_context, :__ptc_no_context)
    Process.put(:__ptc_runtime_callable_context, {eval_ctx, do_eval})

    try do
      fun.()
    after
      case previous do
        :__ptc_no_context ->
          Process.delete(:__ptc_runtime_callable_context)

        context ->
          Process.put(:__ptc_runtime_callable_context, context)
      end
    end
  end

  defp call_with_context(%__MODULE__{} = callable, args, %EvalContext{} = base_ctx, do_eval)
       when is_function(do_eval, 2) do
    eval_ctx = context_with_hof_side_effects(base_ctx)
    callable = bind(callable, eval_ctx, do_eval)

    case invoke(callable, args, eval_ctx) do
      {:ok, result, final_ctx} ->
        stash_hof_side_effects(final_ctx, base_ctx)
        result

      {:error, reason} ->
        raise_error(reason)
    end
  end

  @spec serializable?(term()) :: boolean()
  def serializable?(%__MODULE__{}), do: false
  def serializable?(_), do: true

  defp core_call(%__MODULE__{namespace: :tool, name: name}, args) do
    {:ok, {:tool_call, name, literal_args(args)}}
  end

  defp core_call(%__MODULE__{} = callable, _args) do
    {:error, {:invalid_form, "Unknown runtime callable: #{label(callable)}"}}
  end

  defp literal_args(args), do: Enum.map(args, &{:literal, &1})

  defp raise_error({reason, message, data}) when is_atom(reason) and is_binary(message) do
    raise ExecutionError, reason: reason, message: message, data: data
  end

  defp raise_error({reason, message}) when is_atom(reason) and is_binary(message) do
    raise ExecutionError, reason: reason, message: message
  end

  defp raise_error({reason, _} = error) when is_atom(reason) do
    raise ExecutionError, reason: reason, message: Helpers.format_closure_error(error)
  end

  defp raise_error(reason) do
    raise ExecutionError, reason: :runtime_error, message: Helpers.format_closure_error(reason)
  end

  defp context_with_hof_side_effects(%EvalContext{} = eval_ctx) do
    case Process.get(:__ptc_hof_stack, []) do
      [top | _rest] ->
        %{
          eval_ctx
          | tool_calls: Map.get(top, :tool_calls, []) ++ eval_ctx.tool_calls,
            prints: Map.get(top, :prints, []) ++ eval_ctx.prints,
            catalog_ops: Map.get(top, :catalog_ops, []) ++ eval_ctx.catalog_ops,
            tool_cache: Map.merge(eval_ctx.tool_cache, Map.get(top, :tool_cache, %{}))
        }

      [] ->
        eval_ctx
    end
  end

  defp stash_hof_side_effects(%EvalContext{} = ctx, %EvalContext{} = base_ctx) do
    case Process.get(:__ptc_hof_stack, []) do
      [top | rest] ->
        updated = %{
          top
          | tool_calls: strip_baseline_suffix(ctx.tool_calls, base_ctx.tool_calls),
            prints: strip_baseline_suffix(ctx.prints, base_ctx.prints),
            catalog_ops: strip_baseline_suffix(ctx.catalog_ops, base_ctx.catalog_ops),
            tool_cache: ctx.tool_cache
        }

        Process.put(:__ptc_hof_stack, [updated | rest])

      [] ->
        :ok
    end
  end

  defp strip_baseline_suffix(values, []), do: values

  defp strip_baseline_suffix(values, baseline) do
    count = length(values) - length(baseline)

    if count >= 0 and Enum.drop(values, count) == baseline do
      Enum.take(values, count)
    else
      values
    end
  end
end
