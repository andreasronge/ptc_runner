defmodule PtcRunner.Lisp.CoreAST do
  @moduledoc """
  Core, validated AST for PTC-Lisp.

  This module defines the type specifications for the intermediate
  representation that the analyzer produces. The interpreter evaluates
  CoreAST to produce results.

  ## Pipeline

  ```
  source → Parser → RawAST → Analyze → CoreAST → Eval → result
  ```
  """

  alias PtcRunner.Lisp.Java.Surface, as: JavaSurface

  @type name :: atom() | String.t()

  @type literal ::
          nil
          | boolean()
          | number()
          | {:string, String.t()}
          | {:keyword, name()}
          | {:symbol_ref, String.t()}

  @type fn_params :: [pattern()] | {:variadic, [pattern()], pattern()}

  @type t ::
          literal
          # Collections
          | {:vector, [t()]}
          | {:map, [{t(), t()}]}
          | {:set, [t()]}
          # Variables and namespace access
          | {:var, name()}
          | {:data, name()}
          | {:runtime_callable, name(), name()}
          | {:turn_history, 1 | 2 | 3}
          | {:literal, term()}
          # Function call: f(args...)
          | {:call, t(), [t()]}
          # Let bindings: (let [p1 v1 p2 v2 ...] body)
          | {:let, [binding()], t()}
          # Conditionals
          | {:if, t(), t(), t()}
          # Anonymous function (optionally named for self-recursion)
          | {:fn, fn_params(), t()}
          | {:fn, name(), fn_params(), t()}
          # Sequential evaluation (special forms, not calls)
          | {:do, [t()]}
          # Short-circuit logic (special forms, not calls)
          | {:and, [t()]}
          | {:or, [t()]}
          | {:juxt, [t()]}
          | {:pmap, t(), [t()]}
          | {:pcalls, [t()]}
          # Control flow signals
          | {:return, t()}
          | {:fail, t()}
          # Tool invocation via tool/ namespace: (tool/name args...)
          | {:tool_call, name(), [t()]}
          # Public prelude export reference / call.
          # `ref` is the host-boundary string ref, e.g. "crm/get-user". The
          # evaluator resolves it from the attached prelude's export table and
          # invokes the captured closure against the captured private prelude
          # env so the export can call its private sibling helpers.
          | {:prelude_ref, String.t()}
          | {:prelude_call, String.t(), [t()]}
          # Closed Java interop. Stable manifest identities are retained so
          # evaluation never falls back to an open namespace or host member.
          | {:java_static, atom(), [t()]}
          | {:java_new, atom(), [t()]}
          | {:java_field, atom()}
          | {:java_instance, atom(), t(), [t()]}
          | {:java_dot, atom(), t(), [t()]}
          | {:java_ref, atom()}
          # Define binding in user namespace: (def name value) with optional metadata
          | {:def, name(), t(), map()}
          # Idempotent define: (defonce name value) — no-op if already bound
          | {:defonce, name(), t(), map()}
          # Tail recursion: loop and recur
          | {:loop, [binding()], t()}
          | {:recur, [t()]}

  @type validation_error :: {:invalid_core_ast, [non_neg_integer()], term()}

  @doc "Validates the complete CoreAST algebra, including recursive Java nodes."
  @spec validate(term()) :: :ok | {:error, validation_error()}
  def validate(ast), do: do_validate(ast, [])

  defp do_validate(value, _path)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_atom(value),
       do: :ok

  defp do_validate({:string, value}, _path) when is_binary(value), do: :ok
  defp do_validate({:keyword, name}, _path) when is_atom(name) or is_binary(name), do: :ok
  defp do_validate({:symbol_ref, name}, _path) when is_binary(name), do: :ok
  defp do_validate({:literal, _value}, _path), do: :ok
  defp do_validate({:var, name}, _path) when is_atom(name) or is_binary(name), do: :ok
  defp do_validate({:data, name}, _path) when is_atom(name) or is_binary(name), do: :ok

  defp do_validate({tag, elements}, path)
       when tag in [:vector, :set, :do, :and, :or, :recur, :pcalls, :juxt] and is_list(elements),
       do: validate_list(elements, path)

  defp do_validate({:map, pairs}, path) when is_list(pairs) do
    pairs
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {{key, value}, index}, :ok ->
        with :ok <- do_validate(key, path ++ [index, 0]),
             :ok <- do_validate(value, path ++ [index, 1]) do
          {:cont, :ok}
        else
          {:error, _reason} = error -> {:halt, error}
        end

      {_malformed, _index}, :ok ->
        {:halt, invalid(path, {:map, pairs})}
    end)
  end

  defp do_validate({:call, target, arguments}, path) when is_list(arguments),
    do: validate_target_and_arguments(target, arguments, path)

  defp do_validate({:if, condition, then_branch, else_branch}, path),
    do: validate_list([condition, then_branch, else_branch], path)

  defp do_validate({tag, bindings, body}, path) when tag in [:let, :loop] and is_list(bindings) do
    with :ok <- validate_bindings(bindings, path ++ [0]),
         do: do_validate(body, path ++ [1])
  end

  defp do_validate({:fn, params, body}, path) do
    with :ok <- validate_params(params, path ++ [0]), do: do_validate(body, path ++ [1])
  end

  defp do_validate({:fn, name, params, body}, path) when is_atom(name) or is_binary(name) do
    with :ok <- validate_params(params, path ++ [0]), do: do_validate(body, path ++ [1])
  end

  defp do_validate({tag, value}, path) when tag in [:return, :fail],
    do: do_validate(value, path ++ [0])

  defp do_validate({tag, name, value, metadata}, path)
       when tag in [:def, :defonce] and (is_atom(name) or is_binary(name)) and is_map(metadata),
       do: do_validate(value, path ++ [0])

  defp do_validate({:tool_call, name, arguments}, path)
       when (is_atom(name) or is_binary(name)) and is_list(arguments),
       do: validate_list(arguments, path)

  defp do_validate({:prelude_ref, ref}, _path) when is_binary(ref), do: :ok

  defp do_validate({:prelude_call, ref, arguments}, path)
       when is_binary(ref) and is_list(arguments),
       do: validate_list(arguments, path)

  defp do_validate({:runtime_callable, namespace, name}, _path)
       when (is_atom(namespace) or is_binary(namespace)) and (is_atom(name) or is_binary(name)),
       do: :ok

  defp do_validate({:turn_history, n}, _path) when n in [1, 2, 3], do: :ok

  defp do_validate({:pmap, function, collections}, path) when is_list(collections),
    do: validate_target_and_arguments(function, collections, path)

  defp do_validate({tag, reference_id, arguments}, path)
       when tag in [:java_static, :java_new] and is_atom(reference_id) and is_list(arguments),
       do:
         with(
           :ok <-
             validate_java_reference(
               {tag, reference_id, arguments},
               reference_id,
               if(tag == :java_static, do: :static, else: :constructor),
               path
             ),
           do: validate_list(arguments, path)
         )

  defp do_validate({:java_field, reference_id} = node, path) when is_atom(reference_id),
    do: validate_java_reference(node, reference_id, :field, path)

  defp do_validate({:java_ref, reference_id} = node, path) when is_atom(reference_id) do
    case JavaSurface.fetch_reference(reference_id) do
      {:ok, %{callable?: true}} ->
        if JavaSurface.closed_dispatch_reference?(reference_id),
          do: :ok,
          else: invalid(path, node)

      _ ->
        invalid(path, node)
    end
  end

  defp do_validate({tag, reference_id, receiver, arguments}, path)
       when tag in [:java_instance, :java_dot] and is_atom(reference_id) and is_list(arguments) do
    with :ok <- maybe_validate_java_instance(tag, reference_id, receiver, arguments, path),
         do: validate_target_and_arguments(receiver, arguments, path)
  end

  defp do_validate(malformed, path), do: invalid(path, malformed)

  defp validate_target_and_arguments(target, arguments, path) do
    with :ok <- do_validate(target, path ++ [0]), do: validate_list(arguments, path ++ [1])
  end

  defp maybe_validate_java_instance(:java_dot, family_id, receiver, arguments, path) do
    if JavaSurface.member_family?(family_id),
      do: :ok,
      else: invalid(path, {:java_dot, family_id, receiver, arguments})
  end

  defp maybe_validate_java_instance(:java_instance, reference_id, receiver, arguments, path),
    do:
      validate_java_reference(
        {:java_instance, reference_id, receiver, arguments},
        reference_id,
        :instance,
        path
      )

  defp validate_java_reference(node, reference_id, expected_kind, path) do
    case JavaSurface.fetch_reference(reference_id) do
      {:ok, %{kind: ^expected_kind}} ->
        if JavaSurface.closed_dispatch_reference?(reference_id),
          do: :ok,
          else: invalid(path, node)

      _ ->
        invalid(path, node)
    end
  end

  defp validate_list(values, path) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case do_validate(value, path ++ [index]) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_bindings(bindings, path) do
    bindings
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {{:binding, pattern, value}, index}, :ok ->
        with :ok <- validate_pattern(pattern, path ++ [index, 0]),
             :ok <- do_validate(value, path ++ [index, 1]) do
          {:cont, :ok}
        else
          {:error, _reason} = error -> {:halt, error}
        end

      {_malformed, _index}, :ok ->
        {:halt, invalid(path, bindings)}
    end)
  end

  defp validate_params(params, path) when is_list(params), do: validate_patterns(params, path)

  defp validate_params({:variadic, leading, rest}, path) when is_list(leading) do
    with :ok <- validate_patterns(leading, path),
         do: validate_pattern(rest, path ++ [length(leading)])
  end

  defp validate_params(malformed, path), do: invalid(path, malformed)

  defp validate_patterns(patterns, path) do
    patterns
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {pattern, index}, :ok ->
      case validate_pattern(pattern, path ++ [index]) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_pattern({:var, name}, _path) when is_atom(name) or is_binary(name), do: :ok
  defp validate_pattern({:destructure, _shape}, _path), do: :ok
  defp validate_pattern(malformed, path), do: invalid(path, malformed)

  defp invalid(path, malformed), do: {:error, {:invalid_core_ast, Enum.take(path, 32), malformed}}

  @type binding :: {:binding, pattern(), t()}

  @type pattern ::
          {:var, name()}
          | {:destructure, {:keys, [name()], keyword()}}
          | {:destructure, {:map, [name()], [{pattern(), term()}], keyword()}}
          | {:destructure, {:as, name(), pattern()}}
          | {:destructure, {:seq, [pattern()]}}
          # Rest pattern: [a b & rest] binds rest to remaining elements
          | {:destructure, {:seq_rest, [pattern()], pattern()}}
end
