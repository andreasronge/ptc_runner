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

  alias PtcRunner.Lisp.FastParser
  alias PtcRunner.Lisp.Format.SymbolRef
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
          | {:runtime_callable, :tool, name()}
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

  @doc false
  @spec valid_prelude_ref?(term()) :: boolean()
  def valid_prelude_ref?(ref) when is_binary(ref) do
    case String.split(ref, "/", parts: 3) do
      [namespace, name] ->
        SymbolRef.valid_name?(namespace) and SymbolRef.valid_name?(name) and
          not String.contains?(namespace, "/") and not String.contains?(name, "/") and
          exact_namespaced_symbol?(ref, namespace, name)

      _other ->
        false
    end
  end

  def valid_prelude_ref?(_ref), do: false

  defp exact_namespaced_symbol?(ref, namespace, name) do
    case FastParser.parse(ref) do
      {:ok, {:ns_symbol, parsed_namespace, parsed_name}} ->
        to_string(parsed_namespace) == namespace and to_string(parsed_name) == name

      _other ->
        false
    end
  end

  defp do_validate(value, _path)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_atom(value),
       do: :ok

  defp do_validate({:string, value}, _path) when is_binary(value), do: :ok
  defp do_validate({:keyword, name}, _path) when is_atom(name) or is_binary(name), do: :ok

  defp do_validate({:symbol_ref, name} = value, path) when is_binary(name) do
    if SymbolRef.valid_name?(name), do: :ok, else: invalid(path, value)
  end

  defp do_validate({:literal, _value}, _path), do: :ok
  defp do_validate({:var, name}, _path) when is_atom(name) or is_binary(name), do: :ok

  defp do_validate({:data, name} = node, path) when is_atom(name) or is_binary(name) do
    if exact_qualified_name?("data", name), do: :ok, else: invalid(path, node)
  end

  defp do_validate({tag, elements}, path)
       when tag in [:vector, :set, :do, :and, :or, :recur, :pcalls, :juxt] and is_list(elements),
       do: validate_list(elements, path)

  defp do_validate({:map, pairs}, path) when is_list(pairs) do
    if proper_list?(pairs) do
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
    else
      invalid(path, {:map, pairs})
    end
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

  defp do_validate({:tool_call, name, arguments} = node, path)
       when (is_atom(name) or is_binary(name)) and is_list(arguments) do
    if exact_qualified_name?("tool", name),
      do: validate_list(arguments, path),
      else: invalid(path, node)
  end

  defp do_validate({:prelude_ref, ref} = node, path) when is_binary(ref) do
    if valid_prelude_ref?(ref), do: :ok, else: invalid(path, node)
  end

  defp do_validate({:prelude_call, ref, arguments} = node, path)
       when is_binary(ref) and is_list(arguments) do
    if valid_prelude_ref?(ref), do: validate_list(arguments, path), else: invalid(path, node)
  end

  defp do_validate({:runtime_callable, :tool, name} = node, path)
       when is_atom(name) or is_binary(name) do
    if exact_tool_callable?(name), do: :ok, else: invalid(path, node)
  end

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
        :ok

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
        :ok

      _ ->
        invalid(path, node)
    end
  end

  defp validate_list(values, path) do
    if proper_list?(values) do
      values
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
        case do_validate(value, path ++ [index]) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      invalid(path, values)
    end
  end

  defp validate_bindings(bindings, path) do
    if proper_list?(bindings) do
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
    else
      invalid(path, bindings)
    end
  end

  defp validate_params(params, path) when is_list(params), do: validate_patterns(params, path)

  defp validate_params({:variadic, leading, rest}, path) when is_list(leading) do
    with :ok <- validate_patterns(leading, path),
         do: validate_pattern(rest, path ++ [length(leading)])
  end

  defp validate_params(malformed, path), do: invalid(path, malformed)

  defp validate_patterns(patterns, path) do
    if proper_list?(patterns) do
      patterns
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {pattern, index}, :ok ->
        case validate_pattern(pattern, path ++ [index]) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      invalid(path, patterns)
    end
  end

  defp validate_pattern({:var, name}, _path) when is_atom(name) or is_binary(name), do: :ok

  defp validate_pattern({:destructure, {:keys, keys, defaults}}, path) do
    with :ok <- validate_pattern_names(keys, path ++ [0]),
         do: validate_pattern_defaults(defaults, path ++ [1])
  end

  defp validate_pattern({:destructure, {:map, keys, renames, defaults}}, path) do
    with :ok <- validate_pattern_names(keys, path ++ [0]),
         :ok <- validate_pattern_renames(renames, path ++ [1]),
         do: validate_pattern_defaults(defaults, path ++ [2])
  end

  defp validate_pattern({:destructure, {:as, name, inner}}, path)
       when is_atom(name) or is_binary(name),
       do: validate_pattern(inner, path ++ [1])

  defp validate_pattern({:destructure, {:seq, patterns}}, path),
    do: validate_patterns(patterns, path)

  defp validate_pattern({:destructure, {:seq_rest, leading, rest}}, path) do
    with :ok <- validate_patterns(leading, path ++ [0]),
         do: validate_pattern(rest, path ++ [1])
  end

  defp validate_pattern(malformed, path), do: invalid(path, malformed)

  defp validate_pattern_names(names, path) do
    if proper_list?(names) do
      names
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn
        {name, _index}, :ok when is_atom(name) or is_binary(name) ->
          {:cont, :ok}

        {name, index}, :ok ->
          {:halt, invalid(path ++ [index], name)}
      end)
    else
      invalid(path, names)
    end
  end

  defp validate_pattern_renames(renames, path) do
    if proper_list?(renames) do
      renames
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn
        {{pattern, source_key}, index}, :ok
        when is_atom(source_key) or is_binary(source_key) ->
          case validate_pattern(pattern, path ++ [index, 0]) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end

        {malformed, index}, :ok ->
          {:halt, invalid(path ++ [index], malformed)}
      end)
    else
      invalid(path, renames)
    end
  end

  defp validate_pattern_defaults(defaults, path) do
    if proper_list?(defaults) do
      defaults
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn
        {{name, value}, _index}, :ok
        when (is_atom(name) or is_binary(name)) and
               (is_nil(value) or is_boolean(value) or is_number(value) or is_atom(value) or
                  is_binary(value)) ->
          {:cont, :ok}

        {malformed, index}, :ok ->
          {:halt, invalid(path ++ [index], malformed)}
      end)
    else
      invalid(path, defaults)
    end
  end

  defp invalid(path, malformed), do: {:error, {:invalid_core_ast, Enum.take(path, 32), malformed}}

  defp exact_tool_callable?(name), do: exact_qualified_name?("tool", name)

  defp exact_qualified_name?(namespace, name) do
    name = to_string(name)
    source = namespace <> "/" <> name

    case FastParser.parse(source) do
      {:ok, {:ns_symbol, parsed_namespace, parsed_name}} ->
        to_string(parsed_namespace) == namespace and to_string(parsed_name) == name

      _other ->
        false
    end
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_other), do: false

  @type binding :: {:binding, pattern(), t()}

  @type pattern ::
          {:var, name()}
          | {:destructure, {:keys, [name()], [{name(), term()}]}}
          | {:destructure, {:map, [name()], [{pattern(), name()}], [{name(), term()}]}}
          | {:destructure, {:as, name(), pattern()}}
          | {:destructure, {:seq, [pattern()]}}
          # Rest pattern: [a b & rest] binds rest to remaining elements
          | {:destructure, {:seq_rest, [pattern()], pattern()}}
end
