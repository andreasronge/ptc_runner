defmodule PtcRunner.Folding.ChemistryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Folding.Chemistry

  describe "assemble/1" do
    test "get + field_key bonds into (get x :key)" do
      # D(get) at (0,0), a(:price) at (1,0) — adjacent
      grid = %{{0, 0} => ?D, {1, 0} => ?a}
      fragments = Chemistry.assemble(grid)

      assert length(fragments) == 1
      [{:assembled, ast}] = fragments
      assert ast == {:list, [{:symbol, :get}, {:symbol, :x}, {:keyword, :price}]}
    end

    test "comparator + two values bonds" do
      # K(>) adjacent to assembled (get x :price) and literal 500
      # Build this via a grid with D, a, K, 5 in the right adjacency
      # D at (0,0), a at (1,0), K at (0,1), 5 at (1,1)
      grid = %{
        {0, 0} => ?D,
        {1, 0} => ?a,
        {0, 1} => ?K,
        {1, 1} => ?5
      }

      fragments = Chemistry.assemble(grid)
      # Should get (> (get x :price) 500) assembled
      assembled = Enum.filter(fragments, fn f -> match?({:assembled, _}, f) end)
      assert assembled != []
    end

    test "spacers are excluded from fragments" do
      grid = %{{0, 0} => ?W, {1, 0} => ?X, {2, 0} => ?Y}
      fragments = Chemistry.assemble(grid)
      assert fragments == []
    end

    test "isolated characters produce leaf fragments" do
      # S(data/products) alone — no bonds possible, stays as data_source
      grid = %{{0, 0} => ?S}
      fragments = Chemistry.assemble(grid)
      assert fragments == [{:data_source, :products}]
    end

    test "count + collection bonds" do
      # B(count) adjacent to S(data/products)
      grid = %{{0, 0} => ?B, {1, 0} => ?S}
      fragments = Chemistry.assemble(grid)

      assembled = Enum.filter(fragments, fn f -> match?({:assembled, _}, f) end)
      assert length(assembled) == 1
      [{:assembled, ast}] = assembled
      assert ast == {:list, [{:symbol, :count}, {:ns_symbol, :data, :products}]}
    end

    test "empty grid produces no fragments" do
      assert Chemistry.assemble(%{}) == []
    end
  end
end
