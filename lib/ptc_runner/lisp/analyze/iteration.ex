defmodule PtcRunner.Lisp.Analyze.Iteration do
  @moduledoc """
  Iteration analysis for `doseq` and `for` comprehensions.

  Parses binding vectors with `:when`/`:let`/`:while` modifiers, builds
  desugared loop/recur RawAST, and delegates final analysis back through
  a callback.
  """

  # ============================================================
  # Public API
  # ============================================================

  @doc """
  Analyzes a `doseq` form.

  Takes the arguments and an analyzer function `(ast, tail?) -> result`.
  """
  def analyze_doseq([{:vector, bindings}, first_body | rest_body], analyze_fn) do
    body_asts = [first_body | rest_body]

    case parse_binding_segments(bindings) do
      {:ok, segments} ->
        do_build_doseq(segments, body_asts, analyze_fn)

      {:error, _} = err ->
        err
    end
  end

  def analyze_doseq([{:vector, _bindings}], _analyze_fn) do
    {:error,
     {:invalid_arity, :doseq, "doseq requires at least one body expression, missing body"}}
  end

  def analyze_doseq(_, _analyze_fn) do
    {:error, {:invalid_arity, :doseq, "expected (doseq [bindings] body ...)"}}
  end

  @doc """
  Analyzes a `for` (list comprehension) form.

  Takes the arguments and an analyzer function `(ast, tail?) -> result`.
  """
  def analyze_for([{:vector, bindings}, first_body | rest_body], analyze_fn) do
    body_asts = [first_body | rest_body]

    case parse_binding_segments(bindings) do
      {:ok, segments} ->
        do_build_for(segments, body_asts, analyze_fn)

      {:error, _} = err ->
        err
    end
  end

  def analyze_for([{:vector, _bindings}], _analyze_fn) do
    {:error, {:invalid_arity, :for, "for requires at least one body expression"}}
  end

  def analyze_for(_, _analyze_fn) do
    {:error, {:invalid_arity, :for, "expected (for [bindings] body ...)"}}
  end

  # ============================================================
  # Binding segment parsing
  # ============================================================

  # Parse binding vector into segments: [{binding, collection, modifiers}, ...]
  # Modifiers are :when/:let/:while keywords that follow a binding pair.
  defp parse_binding_segments(bindings) do
    parse_binding_segments(bindings, [])
  end

  defp parse_binding_segments([], acc) do
    case acc do
      [] -> {:error, {:invalid_form, "for/doseq requires at least one binding pair"}}
      _ -> {:ok, Enum.reverse(acc)}
    end
  end

  # Keyword in binding position → error
  defp parse_binding_segments([{:keyword, k} | _], _acc) do
    {:error,
     {:invalid_form,
      "expected a binding symbol, got keyword :#{k}. Keywords like :when/:let/:while must follow a binding pair"}}
  end

  defp parse_binding_segments([binding, coll | rest], acc) do
    case parse_modifiers(rest, []) do
      {:ok, modifiers, remaining} ->
        segment = %{binding: binding, collection: coll, modifiers: modifiers}
        parse_binding_segments(remaining, [segment | acc])

      {:error, _} = err ->
        err
    end
  end

  defp parse_binding_segments([_single], _acc) do
    {:error, {:invalid_form, "for/doseq bindings require pairs, got trailing element"}}
  end

  @known_modifiers [:when, :let, :while]

  defp parse_modifiers([{:keyword, k} | rest], acc) when k in @known_modifiers do
    case {k, rest} do
      {_, []} ->
        {:error, {:invalid_form, "modifier :#{k} requires a value"}}

      {:let, [{:vector, _} = vec | remaining]} ->
        parse_modifiers(remaining, [{:let, vec} | acc])

      {:let, [other | _]} ->
        {:error,
         {:invalid_form,
          ":let modifier requires a vector of bindings, got: #{inspect_ast(other)}"}}

      {mod, [expr | remaining]} ->
        parse_modifiers(remaining, [{mod, expr} | acc])
    end
  end

  defp parse_modifiers([{:keyword, k} | _], _acc) do
    {:error, {:invalid_form, "unknown modifier :#{k} in for/doseq. Known: :when, :let, :while"}}
  end

  defp parse_modifiers(rest, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  # ============================================================
  # AST inspection helpers
  # ============================================================

  defp inspect_ast({:vector, _}), do: "vector"
  defp inspect_ast({:symbol, s}), do: "symbol '#{s}'"
  defp inspect_ast({:keyword, k}), do: ":#{k}"
  defp inspect_ast(n) when is_number(n), do: "#{n}"
  defp inspect_ast({:string, s}), do: inspect(s)
  defp inspect_ast(other), do: inspect(other)

  # Reconstruct flat binding tokens from a segment (for recursive inner for/doseq calls)
  defp segment_to_bindings(%{binding: b, collection: c, modifiers: mods}) do
    [b, c | Enum.flat_map(mods, &modifier_to_tokens/1)]
  end

  defp modifier_to_tokens({:let, vec}), do: [{:keyword, :let}, vec]
  defp modifier_to_tokens({mod, expr}), do: [{:keyword, mod}, expr]

  # ============================================================
  # Modifier wrapping
  # ============================================================

  # Wrap an inner expression with modifiers applied in reverse declaration order.
  # This ensures earlier modifiers wrap later ones (correct nesting).
  defp wrap_with_modifiers(modifiers, inner, skip_expr, stop_expr) do
    modifiers
    |> Enum.reverse()
    |> Enum.reduce(inner, fn
      {:when, pred}, acc ->
        {:list, [{:symbol, :if}, pred, acc, skip_expr]}

      {:while, pred}, acc ->
        {:list, [{:symbol, :if}, pred, acc, stop_expr]}

      {:let, {:vector, _} = bindings_vec}, acc ->
        {:list, [{:symbol, :let}, bindings_vec, acc]}
    end)
  end

  # ============================================================
  # doseq builder
  # ============================================================

  defp do_build_doseq([segment | rest_segments], body_asts, analyze_fn) do
    %{binding: binding_ast, collection: coll_ast, modifiers: modifiers} = segment

    case check_iterator_collection(:doseq, binding_ast, coll_ast) do
      {:error, _} = err ->
        err

      {:ok, _} ->
        inner_form =
          if rest_segments == [] do
            {:program, body_asts}
          else
            inner_bindings = Enum.flat_map(rest_segments, &segment_to_bindings/1)
            {:list, [{:symbol, :doseq}, {:vector, inner_bindings} | body_asts]}
          end

        temp_sym = {:symbol, :"$doseq_temp"}

        # Skip expression for :when — just advance iterator
        skip_expr = {:list, [{:symbol, :recur}, {:list, [{:symbol, :next}, temp_sym]}]}

        # Stop expression for :while — return nil immediately
        stop_expr = nil

        # Start with innermost: do { body; recur next }
        recur_expr = {:list, [{:symbol, :recur}, {:list, [{:symbol, :next}, temp_sym]}]}

        innermost =
          {:list,
           [
             {:symbol, :do},
             inner_form,
             recur_expr
           ]}

        # Wrap with modifiers in reverse order
        wrapped = wrap_with_modifiers(modifiers, innermost, skip_expr, stop_expr)

        desugared =
          {:list,
           [
             {:symbol, :loop},
             {:vector, [temp_sym, {:list, [{:symbol, :seq}, coll_ast]}]},
             {:list,
              [
                {:symbol, :if},
                temp_sym,
                {:list,
                 [
                   {:symbol, :let},
                   {:vector, [binding_ast, {:list, [{:symbol, :first}, temp_sym]}]},
                   wrapped
                 ]},
                nil
              ]}
           ]}

        analyze_fn.(desugared, true)
    end
  end

  # ============================================================
  # for builder
  # ============================================================

  defp do_build_for([segment | rest_segments], body_asts, analyze_fn) do
    %{binding: binding_ast, collection: coll_ast, modifiers: modifiers} = segment

    case check_iterator_collection(:for, binding_ast, coll_ast) do
      {:error, _} = err ->
        err

      {:ok, _} ->
        inner_form =
          if rest_segments == [] do
            # Last segment: body result gets conj'd into accumulator
            {:program, body_asts}
          else
            # More segments: recursive inner (for ...) call
            inner_bindings = Enum.flat_map(rest_segments, &segment_to_bindings/1)
            {:list, [{:symbol, :for}, {:vector, inner_bindings} | body_asts]}
          end

        seq_sym = {:symbol, :"$for_seq"}
        acc_sym = {:symbol, :"$for_acc"}

        body_expr =
          if rest_segments == [] do
            # (conj $for_acc body)
            {:list, [{:symbol, :conj}, acc_sym, inner_form]}
          else
            # (into $for_acc (for [...] body))
            {:list, [{:symbol, :into}, acc_sym, inner_form]}
          end

        # Skip expression for :when — advance iterator, keep acc
        skip_expr =
          {:list, [{:symbol, :recur}, {:list, [{:symbol, :next}, seq_sym]}, acc_sym]}

        # Stop expression for :while — return accumulated results
        stop_expr = acc_sym

        # Innermost: (recur (next $for_seq) body_expr)
        innermost =
          {:list,
           [
             {:symbol, :recur},
             {:list, [{:symbol, :next}, seq_sym]},
             body_expr
           ]}

        # Wrap with modifiers in reverse order
        wrapped = wrap_with_modifiers(modifiers, innermost, skip_expr, stop_expr)

        desugared =
          {:list,
           [
             {:symbol, :loop},
             {:vector, [seq_sym, {:list, [{:symbol, :seq}, coll_ast]}, acc_sym, {:vector, []}]},
             {:list,
              [
                {:symbol, :if},
                seq_sym,
                {:list,
                 [
                   {:symbol, :let},
                   {:vector, [binding_ast, {:list, [{:symbol, :first}, seq_sym]}]},
                   wrapped
                 ]},
                acc_sym
              ]}
           ]}

        analyze_fn.(desugared, true)
    end
  end

  # ============================================================
  # Collection validation
  # ============================================================

  defp check_iterator_collection(op, binding_ast, coll_ast) do
    case coll_ast do
      n when is_number(n) ->
        name = binding_name_prefix(binding_ast)

        {:error,
         {:invalid_arity, op, "#{op} binding #{name}expected a collection, got: #{n} (number)"}}

      {:keyword, k} ->
        name = binding_name_prefix(binding_ast)

        {:error,
         {:invalid_arity, op, "#{op} binding #{name}expected a collection, got: :#{k} (keyword)"}}

      _ ->
        {:ok, coll_ast}
    end
  end

  defp binding_name_prefix({:symbol, sym}), do: "'#{sym}' "
  defp binding_name_prefix(_), do: ""
end
