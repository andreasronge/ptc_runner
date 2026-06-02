defmodule PtcRunner.Lisp.Analyze.ShortFn do
  @moduledoc """
  Analyzer for short function syntax (#()).

  Transforms short function forms into desugared anonymous functions
  by extracting placeholders (%, %1, %2, %&, etc.) and generating parameters.
  """

  alias PtcRunner.Lisp.Analyze.Placeholder
  alias PtcRunner.Lisp.SourceAtoms

  @max_short_fn_arity 20

  @doc """
  Desugars short function syntax into a transformed AST.

  Takes the body ASTs from a short_fn form and returns a desugared form
  as a list-based fn form, ready for the parent analyzer to process.

  Returns `{:ok, desugared_ast}` on success or `{:error, error_reason()}` on failure.
  """
  @spec desugar(list(term())) :: {:ok, term()} | {:error, term()}
  def desugar(body_asts) do
    # The parser gives us a list of AST elements that form the body
    # These could be:
    # 1. A single literal: #(42) -> [42]
    # 2. A function call: #(+ % 1) -> [{:symbol, :+}, {:symbol, :"%"}, 1]
    # 3. Any other single expression wrapped in a list

    # Convert body_asts into an actual body expression
    body_expr =
      case body_asts do
        [] ->
          nil

        [single_form] ->
          # A single symbol like #(foo) means call foo: (fn [] (foo))
          # A single list like #((+ 1 2)) is already a call expression
          # Literals like #(42) are kept as-is (will error at runtime like Clojure)
          case single_form do
            {:symbol, name} ->
              if Placeholder.placeholder?(name), do: single_form, else: {:list, [single_form]}

            _ ->
              single_form
          end

        multiple_forms ->
          # Multiple forms means it's a function call with args
          # e.g. #(+ % 1) -> (fn [p1] (+ p1 1))
          {:list, multiple_forms}
      end

    # Now find placeholders in the expression
    with placeholders_result <- extract_placeholders([body_expr]),
         {:ok, placeholders} <- validate_placeholder_result(placeholders_result),
         {:ok, arity} <- determine_arity(placeholders),
         params <- generate_params(arity),
         transformed_body <- transform_body(body_expr, placeholders) do
      {:ok, {:list, [{:symbol, :fn}, {:vector, params}, transformed_body]}}
    end
  end

  # ============================================================
  # Placeholder extraction and validation
  # ============================================================

  defp validate_placeholder_result(:nested_short_fn) do
    {:error, {:invalid_form, "Nested #() anonymous functions are not allowed"}}
  end

  defp validate_placeholder_result(result) do
    result
  end

  # Extract all placeholder symbols (%, %1, %2, etc.) from AST
  defp extract_placeholders(asts) do
    # credo:disable-for-next-line
    try do
      placeholders =
        asts
        |> Enum.flat_map(&find_all_placeholders/1)
        |> Enum.uniq()

      {:ok, placeholders}
    catch
      :nested_short_fn ->
        :nested_short_fn
    end
  end

  # Recursively find all placeholder symbols in an AST node
  defp find_all_placeholders({:symbol, name}) do
    if Placeholder.placeholder?(name) do
      [name]
    else
      []
    end
  end

  defp find_all_placeholders({:vector, elems}) do
    Enum.flat_map(elems, &find_all_placeholders/1)
  end

  defp find_all_placeholders({:list, elems}) do
    Enum.flat_map(elems, &find_all_placeholders/1)
  end

  defp find_all_placeholders({:map, pairs}) do
    Enum.flat_map(pairs, fn {k, v} ->
      find_all_placeholders(k) ++ find_all_placeholders(v)
    end)
  end

  defp find_all_placeholders({:set, elems}) do
    Enum.flat_map(elems, &find_all_placeholders/1)
  end

  defp find_all_placeholders({:short_fn, _body_asts}) do
    # Nested #() is not allowed
    throw(:nested_short_fn)
  end

  defp find_all_placeholders(_), do: []

  # ============================================================
  # Arity and parameter generation
  # ============================================================

  defp determine_arity(placeholders) do
    has_rest? = Enum.any?(placeholders, &(to_string(&1) == "%&"))

    numeric_result =
      placeholders
      |> Enum.filter(fn p ->
        s = to_string(p)
        s != "%" and s != "%&"
      end)
      |> Enum.reduce_while({:ok, []}, fn p, {:ok, acc} ->
        num_str = p |> to_string() |> String.replace_leading("%", "")

        if byte_size(num_str) > 3 do
          {:halt,
           {:error,
            {:invalid_form,
             "short function placeholder %#{num_str} exceeds max arity of #{@max_short_fn_arity}"}}}
        else
          n = String.to_integer(num_str)

          if n > @max_short_fn_arity do
            {:halt,
             {:error,
              {:invalid_form,
               "short function placeholder %#{n} exceeds max arity of #{@max_short_fn_arity}"}}}
          else
            {:cont, {:ok, [n | acc]}}
          end
        end
      end)

    case numeric_result do
      {:error, _} = err ->
        err

      {:ok, nums} ->
        base_arity =
          case nums do
            [] ->
              if Enum.any?(placeholders, &(to_string(&1) == "%")), do: 1, else: 0

            nums ->
              Enum.max(nums)
          end

        arity = if has_rest?, do: {:variadic, base_arity}, else: base_arity
        {:ok, arity}
    end
  end

  # Generate parameter list based on arity (as symbols, not yet analyzed)
  defp generate_params(0), do: []

  defp generate_params({:variadic, n}) do
    leading =
      if n > 0, do: Enum.map(1..n, fn i -> {:symbol, SourceAtoms.intern("p#{i}")} end), else: []

    leading ++ [{:symbol, :&}, {:symbol, :rest}]
  end

  defp generate_params(arity) when arity > 0 do
    Enum.map(1..arity, fn i -> {:symbol, SourceAtoms.intern("p#{i}")} end)
  end

  # ============================================================
  # Body transformation
  # ============================================================

  # Transform body by replacing placeholders with parameter variables
  # credo:disable-for-next-line Credo.Check.Warning.UnusedVariable
  defp transform_body(asts, placeholders) when is_list(asts) do
    Enum.map(asts, &transform_body(&1, placeholders))
  end

  defp transform_body({:symbol, name}, _placeholders) when is_atom(name) or is_binary(name) do
    name_str = to_string(name)

    case Placeholder.placeholder?(name) do
      true ->
        param_name = placeholder_to_param(name_str)
        {:symbol, param_name}

      false ->
        {:symbol, name}
    end
  end

  # credo:disable-for-next-line Credo.Check.Warning.UnusedVariable
  defp transform_body({:vector, elems}, placeholders) do
    {:vector, transform_body(elems, placeholders)}
  end

  # credo:disable-for-next-line Credo.Check.Warning.UnusedVariable
  defp transform_body({:list, elems}, placeholders) do
    {:list, transform_body(elems, placeholders)}
  end

  # credo:disable-for-next-line Credo.Check.Warning.UnusedVariable
  defp transform_body({:map, pairs}, placeholders) do
    {:map,
     Enum.map(pairs, fn {k, v} ->
       {transform_body(k, placeholders), transform_body(v, placeholders)}
     end)}
  end

  # credo:disable-for-next-line Credo.Check.Warning.UnusedVariable
  defp transform_body({:set, elems}, placeholders) do
    {:set, transform_body(elems, placeholders)}
  end

  defp transform_body(node, _placeholders) do
    node
  end

  defp placeholder_to_param(name_str) when is_binary(name_str) do
    case name_str do
      "%" ->
        :p1

      "%&" ->
        :rest

      "%" <> num_str ->
        n = String.to_integer(num_str)
        SourceAtoms.intern("p#{n}")
    end
  end
end
