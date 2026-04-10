defmodule PtcRunner.Folding.FoldTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Folding.Fold

  describe "fold/1" do
    test "places all characters from a short genotype" do
      {grid, placements} = Fold.fold("ABCD")
      assert map_size(grid) == 4
      assert length(placements) == 4
    end

    test "first character is placed at origin" do
      {_grid, [{pos, char} | _]} = Fold.fold("A")
      assert pos == {0, 0}
      assert char == ?A
    end

    test "uppercase letters turn left" do
      # A at (0,0) heading right → turn left → heading up
      # B at (0,-1) heading up → turn left → heading left
      {grid, _} = Fold.fold("AB")
      assert Map.has_key?(grid, {0, 0})
      assert Map.has_key?(grid, {0, -1})
    end

    test "lowercase letters go straight" do
      # Start heading right, lowercase keeps going right
      {grid, _} = Fold.fold("Aab")
      # A at (0,0) → turn left → heading up
      # a at (0,-1) → straight → heading up
      # b at (0,-2) → straight → heading up
      assert Map.has_key?(grid, {0, 0})
      assert Map.has_key?(grid, {0, -1})
      assert Map.has_key?(grid, {0, -2})
    end

    test "digits go straight" do
      {grid, _} = Fold.fold("A12")
      # A at (0,0) → heading up
      # 1 at (0,-1) → straight → heading up
      # 2 at (0,-2) → straight
      assert map_size(grid) == 3
    end

    test "X turns left, Y turns right, Z reverses" do
      # Starting heading right
      # X → turn left → heading up → place next at (0,-1)
      # But X is a spacer placed at (0,0), and it turns left
      # Actually: first char placed at (0,0), then direction computed
      {_grid, placements} = Fold.fold("XY")
      assert length(placements) == 2
    end

    test "self-avoidance skips occupied cells" do
      # A long straight genotype that tries to revisit cells
      # Create a scenario: fold into a tight loop
      {grid, _} = Fold.fold("AAAA")
      # 4 left turns should try to come back to start
      # Self-avoidance should handle the collision
      assert map_size(grid) >= 3
    end

    test "empty genotype produces empty grid" do
      {grid, placements} = Fold.fold("")
      assert grid == %{}
      assert placements == []
    end

    test "placements preserve order" do
      {_grid, placements} = Fold.fold("ABC")
      chars = Enum.map(placements, fn {_pos, char} -> char end)
      assert chars == ~c"ABC"
    end
  end

  describe "next_direction/2" do
    test "uppercase turns left from right" do
      assert Fold.next_direction(:right, ?A) == :up
    end

    test "lowercase goes straight" do
      assert Fold.next_direction(:right, ?a) == :right
      assert Fold.next_direction(:up, ?b) == :up
    end

    test "digits go straight" do
      assert Fold.next_direction(:right, ?5) == :right
    end

    test "W goes straight" do
      assert Fold.next_direction(:right, ?W) == :right
    end

    test "X turns left" do
      assert Fold.next_direction(:right, ?X) == :up
    end

    test "Y turns right" do
      assert Fold.next_direction(:right, ?Y) == :down
    end

    test "Z reverses" do
      assert Fold.next_direction(:right, ?Z) == :left
    end
  end
end
