defmodule PtcRunner.Folding.Chemistry do
  @moduledoc """
  Bond rules and multi-pass assembly for folded genotypes.

  After folding places characters on a 2D grid, chemistry scans for adjacent
  character pairs and assembles them into PTC-Lisp AST fragments according to
  fixed bond rules. Assembly proceeds in 4 passes (like embryonic development):

  1. **Leaf bonds**: `get + field_key`, data references, literals
  2. **Predicate bonds**: comparators + pass-1 fragments, `fn` wraps predicates
  3. **Structural bonds**: `filter/map/reduce` + `fn` + data, `count/first` wraps
  4. **Composition bonds**: `let` bindings, `set` operations, `contains?` checks

  See `docs/plans/folding-evolution.md` for the full design.
  """

  alias PtcRunner.Folding.Alphabet

  @type position :: {integer(), integer()}
  @type grid :: %{position() => char()}
  @type fragment :: term()

  # 8-connected neighborhood (including diagonals)
  @neighbors [{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}]

  @doc """
  Assemble a folded grid into PTC-Lisp AST fragments.

  Takes the grid from `Fold.fold/1` and returns a list of assembled AST fragments
  (the largest/most complex fragments that formed). Fragments that were consumed
  by bonding into larger fragments are not returned.

  ## Examples

      iex> grid = %{{0, 0} => ?D, {1, 0} => ?a}
      iex> fragments = PtcRunner.Folding.Chemistry.assemble(grid)
      iex> length(fragments) > 0
      true
  """
  @spec assemble(grid()) :: [fragment()]
  def assemble(grid) do
    # Build adjacency map: position → list of adjacent positions
    adjacency = build_adjacency(grid)

    # Initialize fragment map: each position starts as its leaf fragment
    fragment_map =
      grid
      |> Enum.map(fn {pos, char} -> {pos, Alphabet.to_fragment(char)} end)
      |> Enum.reject(fn {_pos, frag} -> frag == :spacer end)
      |> Map.new()

    # Track which positions hold wildcards (for match pattern assembly)
    wildcard_positions =
      fragment_map
      |> Enum.filter(fn {_pos, frag} -> frag == :wildcard end)
      |> Enum.map(fn {pos, _} -> pos end)
      |> MapSet.new()

    # Track which positions have been consumed into larger fragments
    # A consumed position's fragment lives in its parent
    consumed = MapSet.new()

    # Pass 1: Leaf bonds (get + field_key)
    {fragment_map, consumed} = pass_leaf_bonds(fragment_map, adjacency, consumed)

    # Pass 2: Predicate bonds (comparator + values, fn + predicate)
    {fragment_map, consumed} = pass_predicate_bonds(fragment_map, adjacency, consumed)

    # Pass 3: Structural bonds (filter/map/reduce + fn + data, count/first + collection)
    {fragment_map, consumed} = pass_structural_bonds(fragment_map, adjacency, consumed)

    # Pass 4: Composition bonds (and/or/not + exprs)
    {fragment_map, consumed} = pass_composition_bonds(fragment_map, adjacency, consumed)

    # Pass 5: Conditional bonds (if + predicate + branches, match + pattern → tool/match)
    {fragment_map, consumed} =
      pass_conditional_bonds(fragment_map, adjacency, consumed, wildcard_positions)

    # Return unconsumed fragments (the top-level assembled results)
    fragment_map
    |> Enum.reject(fn {pos, _frag} -> MapSet.member?(consumed, pos) end)
    |> Enum.map(fn {_pos, frag} -> frag end)
    |> Enum.reject(&is_nil/1)
  end

  # === Pass 1: Leaf Bonds ===

  defp pass_leaf_bonds(fmap, adj, consumed) do
    # get + field_key → (get x key)
    Enum.reduce(Map.keys(fmap), {fmap, consumed}, fn pos, {fm, cons} ->
      if MapSet.member?(cons, pos), do: {fm, cons}, else: try_get_bond(pos, fm, adj, cons)
    end)
  end

  defp try_get_bond(pos, fmap, adj, consumed) do
    case Map.get(fmap, pos) do
      {:fn_fragment, :get} ->
        # Look for adjacent field key
        neighbors = adjacent_unconsumed(pos, adj, consumed, fmap)

        case Enum.find(neighbors, fn {_npos, frag} -> match?({:field_key, _}, frag) end) do
          {npos, {:field_key, key}} ->
            ast = {:list, [{:symbol, :get}, {:symbol, :x}, {:keyword, key}]}
            fmap = Map.put(fmap, pos, {:assembled, ast})
            consumed = MapSet.put(consumed, npos)
            {fmap, consumed}

          nil ->
            {fmap, consumed}
        end

      _ ->
        {fmap, consumed}
    end
  end

  # === Pass 2: Predicate Bonds ===

  defp pass_predicate_bonds(fmap, adj, consumed) do
    # comparator + two values → (comp val1 val2)
    {fmap, consumed} =
      Enum.reduce(Map.keys(fmap), {fmap, consumed}, fn pos, {fm, cons} ->
        if MapSet.member?(cons, pos),
          do: {fm, cons},
          else: try_comparator_bond(pos, fm, adj, cons)
      end)

    # fn + expression → (fn [x] expression)
    Enum.reduce(Map.keys(fmap), {fmap, consumed}, fn pos, {fm, cons} ->
      if MapSet.member?(cons, pos), do: {fm, cons}, else: try_fn_bond(pos, fm, adj, cons)
    end)
  end

  defp try_comparator_bond(pos, fmap, adj, consumed) do
    case Map.get(fmap, pos) do
      {:comparator, op} ->
        neighbors = adjacent_unconsumed(pos, adj, consumed, fmap)

        values =
          neighbors
          |> Enum.filter(fn {_p, f} -> value_fragment?(f) end)
          |> Enum.sort_by(fn {_p, f} -> value_priority(f) end)

        if length(values) >= 2 do
          [{p1, f1}, {p2, f2} | _] = values
          ast = {:list, [{:symbol, op}, fragment_to_ast(f1), fragment_to_ast(f2)]}
          fmap = Map.put(fmap, pos, {:assembled, ast})
          consumed = consumed |> MapSet.put(p1) |> MapSet.put(p2)
          {fmap, consumed}
        else
          {fmap, consumed}
        end

      _ ->
        {fmap, consumed}
    end
  end

  # Prefer assembled fragments (pass-1 results) over raw literals/data sources
  # Lower number = higher priority
  defp value_priority({:assembled, _}), do: 0
  defp value_priority({:literal, _}), do: 1
  defp value_priority({:data_source, _}), do: 2
  defp value_priority(_), do: 3

  defp try_fn_bond(pos, fmap, adj, consumed) do
    case Map.get(fmap, pos) do
      {:fn_fragment, :fn} ->
        neighbors = adjacent_unconsumed(pos, adj, consumed, fmap)

        case Enum.find(neighbors, fn {_p, f} -> expression_fragment?(f) end) do
          {npos, frag} ->
            ast =
              {:list,
               [
                 {:symbol, :fn},
                 {:vector, [{:symbol, :x}]},
                 fragment_to_ast(frag)
               ]}

            fmap = Map.put(fmap, pos, {:assembled, ast})
            consumed = MapSet.put(consumed, npos)
            {fmap, consumed}

          nil ->
            {fmap, consumed}
        end

      _ ->
        {fmap, consumed}
    end
  end

  # === Pass 3: Structural Bonds ===

  defp pass_structural_bonds(fmap, adj, consumed) do
    # filter/map + fn + data → (filter fn data)
    {fmap, consumed} =
      Enum.reduce(Map.keys(fmap), {fmap, consumed}, fn pos, {fm, cons} ->
        if MapSet.member?(cons, pos),
          do: {fm, cons},
          else: try_higher_order_bond(pos, fm, adj, cons)
      end)

    # count/first + collection → (count collection)
    Enum.reduce(Map.keys(fmap), {fmap, consumed}, fn pos, {fm, cons} ->
      if MapSet.member?(cons, pos), do: {fm, cons}, else: try_wrapper_bond(pos, fm, adj, cons)
    end)
  end

  defp try_higher_order_bond(pos, fmap, adj, consumed) do
    case Map.get(fmap, pos) do
      {:fn_fragment, op} when op in [:filter, :map, :reduce, :group_by] ->
        neighbors = adjacent_unconsumed(pos, adj, consumed, fmap)
        fn_frag = Enum.find(neighbors, fn {_p, f} -> fn_expression?(f) end)
        data_frag = Enum.find(neighbors, fn {_p, f} -> data_fragment?(f) end)

        case {fn_frag, data_frag} do
          {{fn_pos, fn_f}, {data_pos, data_f}} ->
            ast =
              {:list, [{:symbol, op}, fragment_to_ast(fn_f), fragment_to_ast(data_f)]}

            fmap = Map.put(fmap, pos, {:assembled, ast})
            consumed = consumed |> MapSet.put(fn_pos) |> MapSet.put(data_pos)
            {fmap, consumed}

          _ ->
            {fmap, consumed}
        end

      _ ->
        {fmap, consumed}
    end
  end

  defp try_wrapper_bond(pos, fmap, adj, consumed) do
    case Map.get(fmap, pos) do
      {:fn_fragment, op} when op in [:count, :first] ->
        neighbors = adjacent_unconsumed(pos, adj, consumed, fmap)

        case Enum.find(neighbors, fn {_p, f} -> collection_fragment?(f) end) do
          {npos, frag} ->
            ast = {:list, [{:symbol, op}, fragment_to_ast(frag)]}
            fmap = Map.put(fmap, pos, {:assembled, ast})
            consumed = MapSet.put(consumed, npos)
            {fmap, consumed}

          nil ->
            {fmap, consumed}
        end

      _ ->
        {fmap, consumed}
    end
  end

  # === Pass 4: Composition Bonds ===

  defp pass_composition_bonds(fmap, adj, consumed) do
    # and/or + two expressions → (and expr1 expr2)
    {fmap, consumed} =
      Enum.reduce(Map.keys(fmap), {fmap, consumed}, fn pos, {fm, cons} ->
        if MapSet.member?(cons, pos), do: {fm, cons}, else: try_logical_bond(pos, fm, adj, cons)
      end)

    # not + expression → (not expr)
    {fmap, consumed} =
      Enum.reduce(Map.keys(fmap), {fmap, consumed}, fn pos, {fm, cons} ->
        if MapSet.member?(cons, pos), do: {fm, cons}, else: try_not_bond(pos, fm, adj, cons)
      end)

    # set + collection → (set collection)
    {fmap, consumed} =
      Enum.reduce(Map.keys(fmap), {fmap, consumed}, fn pos, {fm, cons} ->
        if MapSet.member?(cons, pos), do: {fm, cons}, else: try_set_bond(pos, fm, adj, cons)
      end)

    # contains? + set + value → (contains? set value)
    Enum.reduce(Map.keys(fmap), {fmap, consumed}, fn pos, {fm, cons} ->
      if MapSet.member?(cons, pos), do: {fm, cons}, else: try_contains_bond(pos, fm, adj, cons)
    end)
  end

  defp try_logical_bond(pos, fmap, adj, consumed) do
    case Map.get(fmap, pos) do
      {:connective, op} when op in [:and, :or] ->
        neighbors = adjacent_unconsumed(pos, adj, consumed, fmap)
        exprs = Enum.filter(neighbors, fn {_p, f} -> expression_fragment?(f) end)

        if length(exprs) >= 2 do
          [{p1, f1}, {p2, f2} | _] = exprs
          ast = {:list, [{:symbol, op}, fragment_to_ast(f1), fragment_to_ast(f2)]}
          fmap = Map.put(fmap, pos, {:assembled, ast})
          consumed = consumed |> MapSet.put(p1) |> MapSet.put(p2)
          {fmap, consumed}
        else
          {fmap, consumed}
        end

      _ ->
        {fmap, consumed}
    end
  end

  defp try_not_bond(pos, fmap, adj, consumed) do
    case Map.get(fmap, pos) do
      {:connective, :not} ->
        neighbors = adjacent_unconsumed(pos, adj, consumed, fmap)

        case Enum.find(neighbors, fn {_p, f} -> expression_fragment?(f) end) do
          {npos, frag} ->
            ast = {:list, [{:symbol, :not}, fragment_to_ast(frag)]}
            fmap = Map.put(fmap, pos, {:assembled, ast})
            consumed = MapSet.put(consumed, npos)
            {fmap, consumed}

          nil ->
            {fmap, consumed}
        end

      _ ->
        {fmap, consumed}
    end
  end

  defp try_set_bond(pos, fmap, adj, consumed) do
    case Map.get(fmap, pos) do
      {:fn_fragment, :set} ->
        neighbors = adjacent_unconsumed(pos, adj, consumed, fmap)

        case Enum.find(neighbors, fn {_p, f} -> collection_fragment?(f) end) do
          {npos, frag} ->
            ast = {:list, [{:symbol, :set}, fragment_to_ast(frag)]}
            fmap = Map.put(fmap, pos, {:assembled, ast})
            consumed = MapSet.put(consumed, npos)
            {fmap, consumed}

          nil ->
            {fmap, consumed}
        end

      _ ->
        {fmap, consumed}
    end
  end

  defp try_contains_bond(pos, fmap, adj, consumed) do
    case Map.get(fmap, pos) do
      {:fn_fragment, :contains?} ->
        neighbors = adjacent_unconsumed(pos, adj, consumed, fmap)
        sets = Enum.filter(neighbors, fn {_p, f} -> set_fragment?(f) end)
        values = Enum.filter(neighbors, fn {_p, f} -> value_fragment?(f) end)

        case {sets, values} do
          {[{sp, sf} | _], [{vp, vf} | _]} ->
            ast =
              {:list, [{:symbol, :contains?}, fragment_to_ast(sf), fragment_to_ast(vf)]}

            fmap = Map.put(fmap, pos, {:assembled, ast})
            consumed = consumed |> MapSet.put(sp) |> MapSet.put(vp)
            {fmap, consumed}

          _ ->
            {fmap, consumed}
        end

      _ ->
        {fmap, consumed}
    end
  end

  # === Pass 5: Match Bonds ===
  # match + adjacent fragments → (tool/match {:pattern "stringified_pattern"})
  # Adjacent fragments are converted to a pattern string with wildcards.
  # The match tool reads peer_source from context internally.

  defp pass_conditional_bonds(fmap, adj, consumed, wildcard_positions) do
    Enum.reduce(Map.keys(fmap), {fmap, consumed}, fn pos, {fm, cons} ->
      if MapSet.member?(cons, pos) do
        {fm, cons}
      else
        case Map.get(fm, pos) do
          {:fn_fragment, :match} -> try_match_bond(pos, fm, adj, cons, wildcard_positions)
          {:fn_fragment, :if} -> try_if_bond(pos, fm, adj, cons)
          _ -> {fm, cons}
        end
      end
    end)
  end

  defp try_match_bond(pos, fmap, adj, consumed, wildcard_positions) do
    neighbors = adjacent_unconsumed(pos, adj, consumed, fmap)

    # Collect all adjacent fragments (excluding other match/if fragments)
    pattern_fragments =
      neighbors
      |> Enum.reject(fn {_p, f} -> match?({:fn_fragment, _}, f) end)
      |> Enum.sort_by(fn {p, _f} -> p end)

    case pattern_fragments do
      [] -> {fmap, consumed}
      _ -> assemble_match_bond(pos, pattern_fragments, fmap, consumed, wildcard_positions)
    end
  end

  # if + predicate + then_expr + else_expr → (if predicate then else)
  # Predicate: assembled comparison, match tool call, or boolean-producing expression
  # Branches: any value or assembled expression
  defp try_if_bond(pos, fmap, adj, consumed) do
    neighbors = adjacent_unconsumed(pos, adj, consumed, fmap)

    # Find a predicate (comparison, match result, connective, or boolean-like)
    predicates = Enum.filter(neighbors, fn {_p, f} -> predicate_fragment?(f) end)
    # Find branch expressions (any value fragment)
    branches = Enum.filter(neighbors, fn {_p, f} -> branch_fragment?(f) end)

    case {predicates, branches} do
      {[{pred_pos, pred_frag} | _], [{then_pos, then_frag}, {else_pos, else_frag} | _]} ->
        ast =
          {:list,
           [
             {:symbol, :if},
             fragment_to_ast(pred_frag),
             fragment_to_ast(then_frag),
             fragment_to_ast(else_frag)
           ]}

        fmap = Map.put(fmap, pos, {:assembled, ast})

        consumed =
          consumed
          |> MapSet.put(pred_pos)
          |> MapSet.put(then_pos)
          |> MapSet.put(else_pos)

        {fmap, consumed}

      {[{pred_pos, pred_frag} | _], [{then_pos, then_frag}]} ->
        # Two-branch if: missing else, use nil
        ast =
          {:list,
           [
             {:symbol, :if},
             fragment_to_ast(pred_frag),
             fragment_to_ast(then_frag)
           ]}

        fmap = Map.put(fmap, pos, {:assembled, ast})
        consumed = consumed |> MapSet.put(pred_pos) |> MapSet.put(then_pos)
        {fmap, consumed}

      _ ->
        {fmap, consumed}
    end
  end

  # A predicate is something that produces a boolean-ish value
  defp predicate_fragment?({:assembled, {:list, [{:symbol, op} | _]}})
       when op in [:>, :<, :=, :and, :or, :not, :contains?],
       do: true

  # Match tool calls are predicates (return boolean)
  defp predicate_fragment?({:assembled, {:list, [{:ns_symbol, :tool, :match} | _]}}), do: true
  defp predicate_fragment?(_), do: false

  # A branch can be any value-producing fragment
  defp branch_fragment?({:assembled, _}), do: true
  defp branch_fragment?({:literal, _}), do: true
  defp branch_fragment?({:data_source, _}), do: true
  defp branch_fragment?({:field_key, _}), do: true
  defp branch_fragment?(_), do: false

  defp assemble_match_bond(pos, pattern_fragments, fmap, consumed, wildcard_positions) do
    pattern_str =
      pattern_fragments
      |> Enum.map(fn {npos, frag} ->
        if MapSet.member?(wildcard_positions, npos),
          do: "*",
          else: frag |> fragment_to_ast() |> format_pattern_ast()
      end)
      |> build_pattern_string()

    ast =
      {:list,
       [
         {:ns_symbol, :tool, :match},
         {:map, [{{:keyword, :pattern}, {:string, pattern_str}}]}
       ]}

    consumed_positions =
      Enum.reduce(pattern_fragments, consumed, fn {npos, _}, acc -> MapSet.put(acc, npos) end)

    {Map.put(fmap, pos, {:assembled, ast}), consumed_positions}
  end

  # Build a pattern string from fragment strings.
  # If there's one assembled fragment, wrap it: "(count *)" style.
  # If there are multiple, join with spaces: "count * data/products"
  defp build_pattern_string(parts) do
    case parts do
      [single] -> single
      parts -> "(" <> Enum.join(parts, " ") <> ")"
    end
  end

  # Format an AST node as a pattern string (for match tool patterns)
  defp format_pattern_ast(nil), do: "*"
  defp format_pattern_ast({:symbol, s}), do: Atom.to_string(s)
  defp format_pattern_ast({:keyword, k}), do: ":#{k}"
  defp format_pattern_ast({:ns_symbol, ns, name}), do: "#{ns}/#{name}"
  defp format_pattern_ast(n) when is_integer(n), do: Integer.to_string(n)
  defp format_pattern_ast({:string, s}), do: ~s("#{s}")

  defp format_pattern_ast({:list, items}) do
    inner = Enum.map_join(items, " ", &format_pattern_ast/1)
    "(#{inner})"
  end

  defp format_pattern_ast({:vector, items}) do
    inner = Enum.map_join(items, " ", &format_pattern_ast/1)
    "[#{inner}]"
  end

  defp format_pattern_ast(_), do: "*"

  # === Fragment Classification ===

  defp value_fragment?({:assembled, _}), do: true
  defp value_fragment?({:literal, _}), do: true
  defp value_fragment?({:data_source, _}), do: true
  defp value_fragment?(_), do: false

  defp expression_fragment?({:assembled, _}), do: true
  defp expression_fragment?({:comparator, _}), do: false
  defp expression_fragment?({:literal, _}), do: true
  defp expression_fragment?(_), do: false

  defp fn_expression?({:assembled, {:list, [{:symbol, :fn} | _]}}), do: true
  defp fn_expression?(_), do: false

  defp data_fragment?({:data_source, _}), do: true

  defp data_fragment?({:assembled, {:list, [{:symbol, op} | _]}})
       when op in [:filter, :map, :reduce, :group_by, :sort],
       do: true

  defp data_fragment?(_), do: false

  defp collection_fragment?({:assembled, _}), do: true
  defp collection_fragment?({:data_source, _}), do: true
  defp collection_fragment?(_), do: false

  defp set_fragment?({:assembled, {:list, [{:symbol, :set} | _]}}), do: true
  defp set_fragment?(_), do: false

  # === Fragment → AST Conversion ===

  defp fragment_to_ast({:assembled, ast}), do: ast
  defp fragment_to_ast({:literal, n}), do: n
  defp fragment_to_ast({:data_source, name}), do: {:ns_symbol, :data, name}
  defp fragment_to_ast({:field_key, key}), do: {:keyword, key}
  defp fragment_to_ast({:fn_fragment, name}), do: {:symbol, name}
  defp fragment_to_ast({:comparator, op}), do: {:symbol, op}
  defp fragment_to_ast({:connective, op}), do: {:symbol, op}
  defp fragment_to_ast(:wildcard), do: {:symbol, :*}
  defp fragment_to_ast(nil), do: nil

  # === Adjacency Helpers ===

  defp build_adjacency(grid) do
    positions = Map.keys(grid)

    Map.new(positions, fn {x, y} = pos ->
      neighbors =
        @neighbors
        |> Enum.map(fn {dx, dy} -> {x + dx, y + dy} end)
        |> Enum.filter(&Map.has_key?(grid, &1))

      {pos, neighbors}
    end)
  end

  defp adjacent_unconsumed(pos, adj, consumed, fmap) do
    (Map.get(adj, pos, []) -- MapSet.to_list(consumed))
    |> Enum.map(fn npos -> {npos, Map.get(fmap, npos)} end)
    |> Enum.reject(fn {_p, f} -> is_nil(f) end)
  end
end
