defmodule PtcRunner.Lisp.Analyze.ShortFn do
  @moduledoc """
  Analyzer for short function syntax (#()).

  Transforms short function forms into desugared anonymous functions
  by extracting placeholders (%, %1, %2, etc.) and generating parameters.
  """

  alias PtcRunner.Lisp.Analyze

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
          single_form

        multiple_forms ->
          # Multiple forms means it's likely a function call with args
          {:list, multiple_forms}
      end

    # Now find placeholders in the expression
    with placeholders_result <- extract_placeholders([body_expr]),
         {:ok, placeholders} <- validate_placeholder_result(placeholders_result),
         # 2. Determine arity
         arity <- determine_arity(placeholders),
         # 3. Generate parameter list [{:symbol, :p1}, {:symbol, :p2}, ...]
         params <- generate_params(arity),
         # 4. Replace placeholders in body
         transformed_body <- transform_body(body_expr, placeholders) do
      # Return desugared form: (fn [params] transformed_body)
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
    if Analyze.placeholder?(name) do
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

  # Determine arity from placeholders
  defp determine_arity(placeholders) do
    # Extract numeric placeholders
    numeric =
      placeholders
      |> Enum.filter(&(to_string(&1) != "%"))
      |> Enum.map(fn p ->
        p
        |> to_string()
        |> String.replace_leading("%", "")
        |> String.to_integer()
      end)

    case numeric do
      [] ->
        # Only % or no placeholders, arity is 1 if % exists, 0 otherwise
        if Enum.any?(placeholders, &(to_string(&1) == "%")) do
          1
        else
          0
        end

      nums ->
        Enum.max(nums)
    end
  end

  # Generate parameter list based on arity (as symbols, not yet analyzed)
  defp generate_params(0) do
    []
  end

  defp generate_params(arity) when arity > 0 do
    Enum.map(1..arity, fn i -> {:symbol, String.to_atom("p#{i}")} end)
  end

  # ============================================================
  # Body transformation
  # ============================================================

  # Transform body by replacing placeholders with parameter variables
  # credo:disable-for-next-line Credo.Check.Warning.UnusedVariable
  defp transform_body(asts, placeholders) when is_list(asts) do
    Enum.map(asts, &transform_body(&1, placeholders))
  end

  defp transform_body({:symbol, name}, _placeholders) when is_atom(name) do
    name_str = to_string(name)

    case Analyze.placeholder?(name) do
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

  # Convert placeholder symbol to parameter variable name
  defp placeholder_to_param(name_str) when is_binary(name_str) do
    case name_str do
      "%" -> :p1
      "%" <> num_str -> String.to_atom("p#{num_str}")
    end
  end
end
