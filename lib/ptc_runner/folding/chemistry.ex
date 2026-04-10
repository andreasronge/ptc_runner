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
