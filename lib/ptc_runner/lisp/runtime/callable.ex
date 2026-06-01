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
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Runtime.Args
  alias PtcRunner.Lisp.Runtime.FlexAccess
  alias PtcRunner.Lisp.Runtime.Math
  alias PtcRunner.Lisp.RuntimeCallable
  alias PtcRunner.Lisp.TypeError

  # Guard: true keywords (atoms that aren't nil, true, or false)
  defguardp is_keyword(k) when is_atom(k) and k != nil and k != true and k != false

  @spec call(term(), [term()]) :: term()
  def call(%Builtin{binding: {:multi_arity, _name, funs}} = builtin, args) do
    arity = length(args)
    min_arity = :erlang.fun_info(elem(funs, 0), :arity) |> elem(1)
    idx = arity - min_arity

    if idx >= 0 and idx < tuple_size(funs) do
      Args.validate!(builtin, args)
    end

    call(Builtin.unwrap(builtin), args)
  end

  def call(%Builtin{} = builtin, args) do
    Args.validate!(builtin, args)
    call(Builtin.unwrap(builtin), args)
  end

  def call(%RuntimeCallable{} = callable, args), do: RuntimeCallable.call(callable, args)

  def call(f, args) when is_function(f), do: apply(f, args)

  def call(%LispKeyword{} = k, [m]) when is_map(m), do: FlexAccess.flex_get(m, k)
  def call(%LispKeyword{}, [nil]), do: nil
  def call(%LispKeyword{}, [_]), do: nil

  def call(%LispKeyword{} = k, [m, default]) when is_map(m) do
    case FlexAccess.flex_fetch(m, k) do
      {:ok, val} -> val
      :error -> default
    end
  end

  def call(%LispKeyword{}, [nil, default]), do: default

  # Keyword as function: (:key map) → map lookup
  def call(k, [m]) when is_keyword(k) and is_map(m), do: FlexAccess.flex_get(m, k)
  def call(k, [nil]) when is_keyword(k), do: nil
  def call(k, [_]) when is_keyword(k), do: nil

  def call(k, [m, default]) when is_keyword(k) and is_map(m) do
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

  defp raise_type_error_or_reraise(fun2, args, stacktrace) do
    if Enum.all?(args, &is_number/1) do
      reraise ArithmeticError, [message: "bad argument in arithmetic expression"], stacktrace
    else
      {:type_error, message, _args} = Helpers.type_error_for_args(fun2, args)
      raise TypeError, message: message
    end
  end
end
