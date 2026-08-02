defmodule PtcRunner.Lisp.Runtime.Callable do
  @moduledoc """
  Dispatch helper for calling Lisp functions from Collection operations.

  This module provides a unified `call/2` function that correctly dispatches
  to all builtin types (normal, variadic, variadic_nonempty, multi_arity, collect)
  as well as plain Erlang functions.

  This solves the problem where `closure_to_fun` unwrapped variadic builtin tuples
  into raw 2-arity functions, causing HOFs to fail when calling functions with
  different arities:

      (map + [1 2] [10 20] [100 200])  ;; 3 args - now works
      (map + [[1 2] [3 4]])            ;; 1 arg via (apply + pair) - now works
      (filter + [0 1 2])               ;; 1 arg - now works
      (map range [1 2 3])              ;; multi_arity - now works
  """

  alias PtcRunner.Lisp.Env.Builtin
  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Eval.HostContext
  alias PtcRunner.Lisp.Introspection
  alias PtcRunner.Lisp.Java.Callable, as: JavaCallable
  alias PtcRunner.Lisp.Java.Condition, as: JavaCondition
  alias PtcRunner.Lisp.Java.Primitive, as: JavaPrimitive
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Runtime.Args
  alias PtcRunner.Lisp.Runtime.FlexAccess
  alias PtcRunner.Lisp.Runtime.Math
  alias PtcRunner.Lisp.Runtime.Predicates
  alias PtcRunner.Lisp.RuntimeCallable

  # Guard: true keywords (atoms that aren't nil, true, or false)
  defguardp is_keyword(k) when is_atom(k) and k != nil and k != true and k != false

  @spec call(term(), [term()]) :: term()
  def call(%Builtin{binding: {:multi_arity, _name, funs}} = builtin, args) do
    args = prepare_builtin_arguments!(builtin, args)
    arity = length(args)
    min_arity = :erlang.fun_info(elem(funs, 0), :arity) |> elem(1)
    idx = arity - min_arity

    if idx >= 0 and idx < tuple_size(funs) do
      Args.validate!(builtin, args)
    end

    call(Builtin.unwrap(builtin), args)
  end

  def call(%Builtin{} = builtin, args) do
    args = prepare_builtin_arguments!(builtin, args)
    Args.validate!(builtin, args)
    call(Builtin.unwrap(builtin), args)
  end

  def call(%RuntimeCallable{} = callable, args), do: RuntimeCallable.call(callable, args)

  # Prelude introspection builtins. Like `%RuntimeCallable{}`, these need the
  # evaluator context — for the attached prelude and the run's visibility
  # filter — so they stay binding tuples instead of being converted to BEAM
  # functions. Dispatching from `args` preserves `dir`'s zero- and one-argument
  # forms, and taking the context from `HostContext` resolves visibility
  # against the caller that is running the value, not whoever converted it.
  def call({:special, op}, args) when op in [:dir, :apropos, :doc, :export_meta] do
    case HostContext.current() do
      {%EvalContext{} = context, _do_eval} -> introspect(op, args, context)
      nil -> HostContext.error!({:type_error, "#{op} requires an evaluator context", args})
    end
  end

  def call(%JavaCallable{} = callable, args) do
    case JavaCallable.invoke(callable, args) do
      {:ok, value, _overload_id} -> value
      {:error, condition} -> HostContext.error!(JavaCondition.evaluator_error(condition))
    end
  end

  def call(f, args) when is_function(f), do: apply(f, args)

  def call(%MapSet{} = set, [arg]) do
    if(MapSet.member?(set, arg), do: arg, else: nil)
  end

  def call({:juxt_fn, fns}, args) when is_list(fns) do
    Enum.map(fns, &call(&1, args))
  end

  def call({:partial_fn, f, fixed}, args) when is_list(fixed), do: call(f, fixed ++ args)

  def call({:comp_fn, []}, args), do: call({:normal, &Predicates.identity/1}, args)

  def call({:comp_fn, fns}, args) when is_list(fns) do
    [last_fn | rest] = Enum.reverse(fns)
    initial = call(last_fn, args)
    Enum.reduce(rest, initial, fn f, acc -> call(f, [acc]) end)
  end

  def call({:complement_fn, f}, args), do: not truthy?(call(f, args))
  def call({:constantly_fn, value}, _args), do: value

  def call({:every_pred_fn, preds}, vals) when is_list(preds) do
    Enum.all?(preds, fn pred -> Enum.all?(vals, fn val -> truthy?(call(pred, [val])) end) end)
  end

  def call({:some_fn, fns}, vals) when is_list(fns) do
    Enum.reduce_while(fns, nil, fn f, last_result ->
      case some_fn_values(f, vals, last_result) do
        {:found, result} -> {:halt, result}
        last -> {:cont, last}
      end
    end)
  end

  def call({:fnil_fn, f, default}, args), do: call(f, substitute_nil(args, default))

  def call(%LispKeyword{} = k, [m]) when is_map(m) and not is_struct(m),
    do: FlexAccess.flex_get(m, k)

  def call(%LispKeyword{}, [nil]), do: nil
  def call(%LispKeyword{}, [_]), do: nil

  def call(%LispKeyword{} = k, [m, default]) when is_map(m) and not is_struct(m) do
    case FlexAccess.flex_fetch(m, k) do
      {:ok, val} -> val
      :error -> default
    end
  end

  def call(%LispKeyword{}, [nil, default]), do: default

  def call(m, [k]) when is_map(m) and not is_struct(m),
    do: FlexAccess.flex_get(m, k)

  def call(m, [k, default]) when is_map(m) and not is_struct(m) do
    case FlexAccess.flex_fetch(m, k) do
      {:ok, val} -> val
      :error -> default
    end
  end

  # Keyword as function: (:key map) → map lookup
  def call(k, [m]) when is_keyword(k) and is_map(m) and not is_struct(m),
    do: FlexAccess.flex_get(m, k)

  def call(k, [nil]) when is_keyword(k), do: nil
  def call(k, [_]) when is_keyword(k), do: nil

  def call(k, [m, default]) when is_keyword(k) and is_map(m) and not is_struct(m) do
    case FlexAccess.flex_fetch(m, k) do
      {:ok, val} -> val
      :error -> default
    end
  end

  def call(k, [nil, default]) when is_keyword(k), do: default

  def call({:normal, fun}, args), do: apply(fun, args)

  def call({:variadic, fun2, identity}, args) do
    case args do
      [] -> identity
      [x] -> Math.unary_variadic(fun2, x)
      [x, y] -> fun2.(x, y)
      [h | t] -> Enum.reduce(t, h, fn x, acc -> fun2.(acc, x) end)
    end
  rescue
    ArithmeticError ->
      raise_type_error_or_reraise(fun2, args, __STACKTRACE__)
  end

  def call({:variadic_nonempty, name, fun2}, args) do
    case args do
      [] -> raise ArgumentError, "#{name} requires at least 1 argument"
      [x] -> Math.unary_variadic_nonempty(name, fun2, x)
      [x, y] -> fun2.(x, y)
      [h | t] -> Enum.reduce(t, h, fn x, acc -> fun2.(acc, x) end)
    end
  rescue
    ArithmeticError ->
      raise_type_error_or_reraise(fun2, args, __STACKTRACE__)
  end

  def call({:multi_arity, name, funs}, args) do
    arity = length(args)
    min_arity = :erlang.fun_info(elem(funs, 0), :arity) |> elem(1)
    idx = arity - min_arity

    if idx >= 0 and idx < tuple_size(funs) do
      apply(elem(funs, idx), args)
    else
      raise ArgumentError, "#{name} arity mismatch: got #{arity} arguments"
    end
  end

  def call({:collect, fun}, args), do: fun.(args)

  defp prepare_builtin_arguments!(%Builtin{name: name}, args) do
    case JavaPrimitive.prepare_arguments(name, args) do
      {:ok, values} -> values
      {:error, :invalid_java_value} -> HostContext.error!({:invalid_java_value, :primitive})
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

  defp substitute_nil([nil | rest], default), do: [default | rest]
  defp substitute_nil(args, _default), do: args

  defp some_fn_values(f, vals, last_result) do
    Enum.reduce_while(vals, last_result, fn val, _acc ->
      result = call(f, [val])

      if truthy?(result), do: {:halt, {:found, result}}, else: {:cont, result}
    end)
  end

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true

  @spec raise_type_error_or_reraise(function(), [term()], Exception.stacktrace()) :: no_return()
  defp raise_type_error_or_reraise(fun2, args, stacktrace) do
    if Enum.all?(args, &is_number/1) do
      reraise ArithmeticError, [message: "bad argument in arithmetic expression"], stacktrace
    else
      {:type_error, message, error_args} = Helpers.type_error_for_args(fun2, args)
      HostContext.error!({:type_error, message, error_args})
    end
  end
end
