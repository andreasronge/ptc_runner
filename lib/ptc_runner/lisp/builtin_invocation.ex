defmodule PtcRunner.Lisp.BuiltinInvocation do
  @moduledoc """
  Invokes builtin bindings with tagged success and error results.

  Arguments must already be prepared and validated. Evaluator adapters own
  closure conversion, effect capture, and control carriers; this module leaves
  those carriers untouched. Failures carry a canonical evaluator reason and,
  when caught, the original host exception and stacktrace. Evaluator adapters
  project the reason; host adapters can re-raise the original exception.
  """

  import PtcRunner.Lisp.Helpers, only: [lisp_name: 1]

  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Runtime.Math

  @typedoc "A canonical evaluator reason with optional original host exception evidence."
  @type failure :: %{
          reason: term(),
          exception: Exception.t() | nil,
          stacktrace: Exception.stacktrace()
        }

  @spec invoke(tuple(), [term()]) :: {:ok, term()} | {:error, failure()}
  # Normal builtins: {:normal, fun}
  def invoke({:normal, fun}, args)
      when is_function(fun) do
    {:ok, apply(fun, args)}
  rescue
    e in FunctionClauseError ->
      # Provide a helpful error message for type mismatches
      failure(Helpers.type_error_for_args(fun, args), e, __STACKTRACE__)

    e in BadArityError ->
      failure({:arity_error, %{actual: length(args)}}, e, __STACKTRACE__)

    e in RuntimeError ->
      # Catch errors from closure evaluation (destructuring, arity, eval errors)
      failure({:type_error, Exception.message(e), args}, e, __STACKTRACE__)

    e in ArithmeticError ->
      failure({:arithmetic_error, arithmetic_token(e)}, e, __STACKTRACE__)

    e in BadFunctionError ->
      # Catch attempts to use non-functions as functions (e.g., :keyword passed to map)
      failure({:type_error, Exception.message(e), args}, e, __STACKTRACE__)
  end

  # Unary variadic builtins still route through Math for validation and
  # operator-specific single-argument behavior.
  def invoke(
        {:variadic, fun2, _identity},
        [x]
      ) do
    {:ok, Math.unary_variadic(fun2, x)}
  rescue
    e in ArithmeticError ->
      failure(
        {:type_error, "expected number, got #{Helpers.describe_type(x)}", x},
        e,
        __STACKTRACE__
      )
  end

  # Variadic builtins: {:variadic, fun2, identity}
  def invoke(
        {:variadic, fun2, identity},
        args
      )
      when is_function(fun2, 2) do
    result =
      case args do
        [] -> identity
        [x] -> Math.unary_variadic(fun2, x)
        [x, y] -> fun2.(x, y)
        [h | t] -> Enum.reduce(t, h, fn x, acc -> fun2.(acc, x) end)
      end

    {:ok, result}
  rescue
    e in ArithmeticError ->
      # Distinguish between type errors (nil/non-number) and arithmetic errors (e.g., overflow)
      if Enum.all?(args, &is_number/1) do
        failure({:arithmetic_error, arithmetic_token(e)}, e, __STACKTRACE__)
      else
        failure(Helpers.type_error_for_args(fun2, args), e, __STACKTRACE__)
      end
  end

  # Variadic requiring at least one arg: {:variadic_nonempty, name, fun2}
  def invoke({:variadic_nonempty, name, _fun2}, []) do
    failure({:arity_error, %{name: lisp_name(name), expected: {:at_least, 1}, actual: 0}})
  end

  def invoke(
        {:variadic_nonempty, name, fun2},
        args
      )
      when is_function(fun2, 2) do
    result =
      case args do
        [x] -> Math.unary_variadic_nonempty(name, fun2, x)
        [x, y] -> fun2.(x, y)
        [h | t] -> Enum.reduce(t, h, fn x, acc -> fun2.(acc, x) end)
      end

    {:ok, result}
  rescue
    e in ArithmeticError ->
      # Distinguish between type errors (nil/non-number) and arithmetic errors
      if Enum.all?(args, &is_number/1) do
        token =
          cond do
            arithmetic_token(e) == :division_by_zero -> :division_by_zero
            Enum.any?(tl(args), &(&1 === 0)) -> :division_by_zero
            true -> :bad_argument
          end

        failure({:arithmetic_error, token}, e, __STACKTRACE__)
      else
        failure(Helpers.type_error_for_args(fun2, args), e, __STACKTRACE__)
      end
  end

  # Collect builtins: pass all args as a list to unary function
  def invoke({:collect, fun}, args)
      when is_function(fun, 1) do
    {:ok, fun.(args)}
  rescue
    e in FunctionClauseError ->
      # A bad argument shape inside a collect builtin (e.g. (update-in [1 2]
      # [] f) routing a vector root through flex_update_in's integer-key
      # clauses) must surface as a recoverable type error, not leak the
      # internal module/function name as a raw :runtime_error. Mirrors the
      # {:normal} and {:multi_arity} handlers so all builtin dispatch shapes
      # fail consistently.
      failure(Helpers.type_error_for_args(fun, args), e, __STACKTRACE__)
  end

  # Multi-arity builtins: select function based on argument count
  # Tuple {fun2, fun3} means index 0 = arity 2, index 1 = arity 3, etc.
  def invoke({:multi_arity, name, funs}, args)
      when (is_atom(name) or is_binary(name)) and is_tuple(funs) do
    arity = length(args)

    # Determine min_arity from first function in tuple
    min_arity = :erlang.fun_info(elem(funs, 0), :arity) |> elem(1)
    idx = arity - min_arity

    if idx >= 0 and idx < tuple_size(funs) do
      fun = elem(funs, idx)

      try do
        {:ok, apply(fun, args)}
      rescue
        e in FunctionClauseError ->
          # Provide a helpful error message for type mismatches
          failure(Helpers.type_error_for_args(fun, args), e, __STACKTRACE__)

        e in RuntimeError ->
          # Catch errors from closure evaluation (destructuring, arity, eval errors)
          failure({:type_error, Exception.message(e), args}, e, __STACKTRACE__)
      end
    else
      arities = Enum.map(0..(tuple_size(funs) - 1), fn i -> i + min_arity end)

      failure({:arity_error, %{name: lisp_name(name), expected: arities, actual: arity}})
    end
  end

  defp failure(reason, exception \\ nil, stacktrace \\ []) do
    {:error, %{reason: reason, exception: exception, stacktrace: stacktrace}}
  end

  defp arithmetic_token(%ArithmeticError{} = error) do
    message = Exception.message(error)

    cond do
      message == "division by zero" -> :division_by_zero
      String.contains?(message, "division by zero") -> :division_by_zero
      message == "integer overflow" -> :integer_overflow
      String.contains?(message, "integer overflow") -> :integer_overflow
      true -> :bad_argument
    end
  end
end
