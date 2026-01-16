defmodule PtcRunner.Lisp.Runtime.Predicates do
  @moduledoc """
  Type predicates, numeric predicates, and logic operations for PTC-Lisp runtime.

  Provides type checking functions (nil?, string?, map?, etc.) and numeric predicates
  (zero?, pos?, neg?, even?, odd?).
  """

  # ============================================================
  # Logic
  # ============================================================

  def not_(x), do: not truthy?(x)

  @doc """
  Identity function: returns its argument unchanged.
  Useful as a default function argument or for composition.
  """
  def identity(x), do: x

  @doc """
  Returns a function that replaces nil first argument with a default value.

  Automatically detects arity of the wrapped function and returns a function
  with matching arity. Supports plain functions and builtin tuples.

  Commonly used with update: `(update m :count (fnil inc 0))` or
  `(update m :count (fnil + 0) 5)` to provide default values for nil.

  ## Examples

      iex> f = PtcRunner.Lisp.Runtime.Predicates.fnil(&Kernel.+/2, 0)
      iex> f.(nil, 5)
      5
      iex> f.(3, 5)
      8

      iex> f = PtcRunner.Lisp.Runtime.Predicates.fnil(&(&1 + 1), 0)
      iex> f.(nil)
      1
      iex> f.(5)
      6
  """
  alias PtcRunner.Lisp.Runtime.Callable

  # Plain 1-arity function
  def fnil(f, default) when is_function(f, 1) do
    fn
      nil -> f.(default)
      arg -> f.(arg)
    end
  end

  # Plain 2-arity function
  def fnil(f, default) when is_function(f, 2) do
    fn
      nil, arg2 -> f.(default, arg2)
      arg1, arg2 -> f.(arg1, arg2)
    end
  end

  # Builtin tuple {:normal, fun} - detect arity from the function
  def fnil({:normal, fun} = callable, default) when is_function(fun) do
    case :erlang.fun_info(fun, :arity) do
      {:arity, 1} ->
        fn
          nil -> Callable.call(callable, [default])
          arg -> Callable.call(callable, [arg])
        end

      {:arity, 2} ->
        fn
          nil, arg2 -> Callable.call(callable, [default, arg2])
          arg1, arg2 -> Callable.call(callable, [arg1, arg2])
        end

      {:arity, _n} ->
        # For higher arities, use {:collect, fn} so evaluator passes args as list
        {:collect, fn args -> Callable.call(callable, substitute_nil(args, default)) end}
    end
  end

  # Variadic, multi-arity, and collect builtins - all use {:collect, fn} wrapper
  def fnil({tag, _, _} = callable, default)
      when tag in [:variadic, :variadic_nonempty, :multi_arity] do
    {:collect, fn args -> Callable.call(callable, substitute_nil(args, default)) end}
  end

  def fnil({:collect, _fun} = callable, default) do
    {:collect, fn args -> Callable.call(callable, substitute_nil(args, default)) end}
  end

  # Substitute nil first argument with default, safely handling empty lists
  defp substitute_nil([nil | rest], default), do: [default | rest]
  defp substitute_nil(args, _default), do: args

  alias PtcRunner.Lisp.Runtime.SpecialValues

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true

  # ============================================================
  # Type Predicates
  # ============================================================

  def nil?(x), do: is_nil(x)
  def some?(x), do: not is_nil(x)
  def boolean?(x), do: is_boolean(x)

  def number?(x), do: is_number(x) or SpecialValues.special?(x)

  def string?(x), do: is_binary(x)

  def keyword?(x),
    do: is_atom(x) and not is_nil(x) and not is_boolean(x) and not SpecialValues.special?(x)

  def vector?(x), do: is_list(x)
  def char?(x), do: is_binary(x) and String.length(x) == 1

  def set?(x), do: is_struct(x, MapSet)

  def regex?(x), do: is_tuple(x) and elem(x, 0) == :re_mp

  def map?(x), do: is_map(x) and not is_struct(x, MapSet)

  def coll?(x), do: is_list(x)

  @doc "Convert collection to set"
  def set(coll) when is_list(coll), do: MapSet.new(coll)
  def set(%MapSet{} = set), do: set

  @doc "Convert collection to vector (list)"
  def vec(nil), do: nil
  def vec(coll) when is_list(coll), do: coll
  def vec(%MapSet{} = set), do: MapSet.to_list(set)
  def vec(s) when is_binary(s), do: String.graphemes(s)
  def vec(m) when is_map(m), do: Enum.map(m, fn {k, v} -> [k, v] end)

  # ============================================================
  # Numeric Predicates
  # ============================================================

  def zero?(x), do: x == 0

  def pos?(x) do
    cond do
      is_number(x) -> x > 0
      SpecialValues.pos_infinite?(x) -> true
      true -> false
    end
  end

  def neg?(x) do
    cond do
      is_number(x) -> x < 0
      SpecialValues.neg_infinite?(x) -> true
      true -> false
    end
  end

  def even?(x) do
    if is_number(x), do: rem(x, 2) == 0, else: false
  end

  def odd?(x) do
    if is_number(x), do: rem(x, 2) != 0, else: false
  end
end
