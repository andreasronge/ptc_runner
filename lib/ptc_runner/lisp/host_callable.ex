defmodule PtcRunner.Lisp.HostCallable do
  @moduledoc """
  Adapts evaluator-dependent callable values to plain host callbacks.

  Special operations resolve the active scoped host context, preserving its
  effects and authority. Errors use the same abort carrier as evaluator calls.
  """

  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Eval.HostContext
  alias PtcRunner.Lisp.Eval.ParallelCall
  alias PtcRunner.Lisp.Introspection
  alias PtcRunner.Lisp.Java.Callable, as: JavaCallable
  alias PtcRunner.Lisp.Java.Condition, as: JavaCondition
  alias PtcRunner.Lisp.SpecialBuiltin

  @introspection_specials SpecialBuiltin.names(:introspection)
  @parallel_specials SpecialBuiltin.names(:parallel)

  @spec error!(term()) :: no_return()
  def error!(reason), do: HostContext.error!(reason)

  @doc "Unwraps builtin results, preserving host exceptions outside evaluation."
  @spec builtin_result!(tuple(), {:ok, term()} | {:error, term()}) :: term()
  def builtin_result!(_binding, {:ok, value}), do: value

  # Host unary arithmetic has historically used the generic builtin diagnostic.
  def builtin_result!(
        {:variadic, fun, _identity},
        {:error, {:type_error, "expected number, got " <> _type, value}}
      ) do
    error!(Helpers.type_error_for_args(fun, [value]))
  end

  def builtin_result!(binding, {:error, reason}) do
    case HostContext.current() do
      nil -> raise_builtin_error(binding, reason)
      {_context, _do_eval} -> HostContext.error!(reason)
    end
  end

  @spec raise_builtin_error(tuple(), term()) :: no_return()
  defp raise_builtin_error(_binding, {:arithmetic_error, _token}) do
    raise ArithmeticError, "bad argument in arithmetic expression"
  end

  defp raise_builtin_error({:variadic_nonempty, name, _fun}, {:arity_error, %{actual: 0}}) do
    raise ArgumentError, "#{name} requires at least 1 argument"
  end

  defp raise_builtin_error({:multi_arity, name, _funs}, {:arity_error, %{actual: actual}}) do
    raise ArgumentError, "#{name} arity mismatch: got #{actual} arguments"
  end

  defp raise_builtin_error(_binding, reason), do: HostContext.error!(reason)

  @spec call(term(), [term()]) :: term()
  # Prelude introspection builtins. Like `%RuntimeCallable{}`, these need the
  # evaluator context — for the attached prelude and the run's visibility
  # filter — so they stay binding tuples instead of being converted to BEAM
  # functions. Dispatching from `args` preserves `dir`'s zero- and one-argument
  # forms, and taking the context from `HostContext` resolves visibility
  # against the caller that is running the value, not whoever converted it.
  def call({:special, op}, args) when op in @introspection_specials do
    case HostContext.current() do
      {%EvalContext{} = context, _do_eval} -> introspect(op, args, context)
      nil -> HostContext.error!({:type_error, "#{op} requires an evaluator context", args})
    end
  end

  def call({:special, operation}, args) when operation in @parallel_specials do
    case HostContext.current() do
      {%EvalContext{} = context, do_eval} ->
        HostContext.with_materialized_context(context, do_eval, fn materialized_context ->
          case ParallelCall.invoke(operation, args, materialized_context, do_eval) do
            {:ok, result, %EvalContext{}} -> result
            {:error, reason} -> HostContext.error!(reason)
          end
        end)

      nil ->
        HostContext.error!({:type_error, "#{operation} requires an evaluator context", args})
    end
  end

  def call(%JavaCallable{} = callable, args) do
    case JavaCallable.invoke(callable, args) do
      {:ok, value, _overload_id} -> value
      {:error, condition} -> HostContext.error!(JavaCondition.evaluator_error(condition))
    end
  end

  # A callable cannot return an error tuple, so an argument fault raises the
  # same canonical reason the direct dispatcher reports.
  defp introspect(op, args, context) do
    case Introspection.invoke(op, args, context) do
      {:ok, value} ->
        value

      {:print, text} ->
        _updated_context = EvalContext.append_print(context, text)
        nil

      {:error, reason} ->
        HostContext.error!(reason)
    end
  end
end
