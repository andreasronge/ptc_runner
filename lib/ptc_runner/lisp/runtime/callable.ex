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

  alias PtcRunner.Lisp.Runtime.Math

  @spec call(term(), [term()]) :: term()
  def call(f, args) when is_function(f), do: apply(f, args)
  def call({:normal, fun}, args), do: apply(fun, args)

  def call({:variadic, fun2, identity}, args) do
    case args do
      [] -> identity
      [x] -> if fun2 == (&Math.subtract/2), do: Math.subtract([x]), else: x
      [x, y] -> fun2.(x, y)
      [h | t] -> Enum.reduce(t, h, fn x, acc -> fun2.(acc, x) end)
    end
  end

  def call({:variadic_nonempty, name, fun2}, args) do
    case args do
      [] -> raise ArgumentError, "#{name} requires at least 1 argument"
      [x] -> x
      [x, y] -> fun2.(x, y)
      [h | t] -> Enum.reduce(t, h, fn x, acc -> fun2.(acc, x) end)
    end
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
end
