defmodule PtcRunner.Lisp.Runtime.Callable do
  @moduledoc """
  Dispatch helper for calling Lisp functions from Collection operations.

  This module provides a unified `call/2` function that correctly dispatches
  to all builtin types (normal, variadic, variadic_nonempty, multi_arity, collect)
  as well as plain Erlang functions. Builtin binding interpretation belongs to
  `PtcRunner.Lisp.BuiltinInvocation`; this host adapter unwraps tagged results.
  Evaluator-dependent operations use `PtcRunner.Lisp.HostCallable` to recover
  scoped context without handling evaluator state here.

  This solves the problem where `closure_to_fun` unwrapped variadic builtin tuples
  into raw 2-arity functions, causing HOFs to fail when calling functions with
  different arities:

      (map + [1 2] [10 20] [100 200])  ;; 3 args - now works
      (map + [[1 2] [3 4]])            ;; 1 arg via (apply + pair) - now works
      (filter + [0 1 2])               ;; 1 arg - now works
      (map range [1 2 3])              ;; multi_arity - now works
  """

  alias PtcRunner.Lisp.BuiltinInvocation
  alias PtcRunner.Lisp.Env.Builtin
  alias PtcRunner.Lisp.HostCallable
  alias PtcRunner.Lisp.Java.Callable, as: JavaCallable
  alias PtcRunner.Lisp.Java.Primitive, as: JavaPrimitive
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Runtime.Args
  alias PtcRunner.Lisp.Runtime.FlexAccess
  alias PtcRunner.Lisp.Runtime.Predicates
  alias PtcRunner.Lisp.RuntimeCallable
  alias PtcRunner.Lisp.SpecialBuiltin

  @introspection_specials SpecialBuiltin.names(:introspection)
  @parallel_specials SpecialBuiltin.names(:parallel)

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

  def call({:special, op} = callable, args)
      when op in @introspection_specials or op in @parallel_specials,
      do: HostCallable.call(callable, args)

  def call(%JavaCallable{} = callable, args), do: HostCallable.call(callable, args)

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

  def call({tag, _} = binding, args) when tag in [:normal, :collect],
    do: invoke_builtin!(binding, args)

  def call({tag, _, _} = binding, args)
      when tag in [:variadic, :variadic_nonempty, :multi_arity],
      do: invoke_builtin!(binding, args)

  defp invoke_builtin!(binding, args) do
    HostCallable.builtin_result!(binding, BuiltinInvocation.invoke(binding, args))
  end

  defp prepare_builtin_arguments!(%Builtin{name: name}, args) do
    case JavaPrimitive.prepare_arguments(name, args) do
      {:ok, values} -> values
      {:error, :invalid_java_value} -> HostCallable.error!({:invalid_java_value, :primitive})
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
end
