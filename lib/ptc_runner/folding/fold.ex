defmodule PtcRunner.Folding.Fold do
  @moduledoc """
  Folds a genotype string onto a 2D grid.

  Each character in the genotype is placed on a grid cell. The fold instruction
  encoded in each character determines the direction of the next step. Uppercase
  letters turn left, lowercase letters go straight, digits go straight, and the
  spacer characters W/X/Y/Z provide explicit direction overrides.

  Self-avoidance: when the next cell is occupied, try turning left, then right,
  then skip the character entirely.

  See `docs/plans/folding-evolution.md` for the full design.
  """

  @type position :: {integer(), integer()}
  @type direction :: :up | :down | :left | :right
  @type grid :: %{position() => char()}

  @doc """
  Fold a genotype string onto a 2D grid.

  Returns `{grid, placements}` where grid is a map from `{x, y}` to the character
  placed there, and placements is an ordered list of `{position, char}` tuples
  recording the placement order.

  ## Examples

      iex> {grid, _placements} = PtcRunner.Folding.Fold.fold("AB")
      iex> Map.keys(grid) |> length()
      2
  """
  @spec fold(String.t()) :: {grid(), [{position(), char()}]}
  def fold(genotype) when is_binary(genotype) do
    chars = String.to_charlist(genotype)
    do_fold(chars, %{}, {0, 0}, :right, [])
  end

  defp do_fold([], grid, _pos, _dir, placements) do
    {grid, Enum.reverse(placements)}
  end

  defp do_fold([char | rest], grid, pos, dir, placements) do
    case place_with_avoidance(grid, pos, dir, char) do
      {:placed, new_grid, placed_pos} ->
        new_dir = next_direction(dir, char)
        next_pos = advance(placed_pos, new_dir)
        do_fold(rest, new_grid, next_pos, new_dir, [{placed_pos, char} | placements])

      :skip ->
        # Can't place anywhere — skip this character, keep moving
        next_pos = advance(pos, dir)
        do_fold(rest, grid, next_pos, dir, placements)
    end
  end

  defp place_with_avoidance(grid, pos, dir, char) do
    if Map.has_key?(grid, pos) do
      try_alternate_placement(grid, pos, dir, char)
    else
      {:placed, Map.put(grid, pos, char), pos}
    end
  end

  defp try_alternate_placement(grid, pos, dir, char) do
    left_dir = turn_left(dir)
    left_pos = advance(pos, left_dir)

    if Map.has_key?(grid, left_pos) do
      try_right_placement(grid, pos, dir, char)
    else
      {:placed, Map.put(grid, left_pos, char), left_pos}
    end
  end

  defp try_right_placement(grid, pos, dir, char) do
    right_dir = turn_right(dir)
    right_pos = advance(pos, right_dir)

    if Map.has_key?(grid, right_pos) do
      :skip
    else
      {:placed, Map.put(grid, right_pos, char), right_pos}
    end
  end

  @doc """
  Compute the next direction based on the current direction and the fold
  instruction encoded in the character.

  - Uppercase letters (A-V) → turn left
  - Lowercase letters (a-z) → straight
  - Digits (0-9) → straight
  - W → straight (explicit)
  - X → turn left (explicit)
  - Y → turn right (explicit)
  - Z → reverse (explicit)
  """
  @spec next_direction(direction(), char()) :: direction()
  def next_direction(dir, char) do
    cond do
      char == ?W -> dir
      char == ?X -> turn_left(dir)
      char == ?Y -> turn_right(dir)
      char == ?Z -> reverse(dir)
      char in ?a..?z -> dir
      char in ?0..?9 -> dir
      char in ?A..?V -> turn_left(dir)
      true -> dir
    end
  end

  @doc """
  Advance one step in the given direction.
  """
  @spec advance(position(), direction()) :: position()
  def advance({x, y}, :right), do: {x + 1, y}
  def advance({x, y}, :left), do: {x - 1, y}
  def advance({x, y}, :up), do: {x, y - 1}
  def advance({x, y}, :down), do: {x, y + 1}

  defp turn_left(:right), do: :up
  defp turn_left(:up), do: :left
  defp turn_left(:left), do: :down
  defp turn_left(:down), do: :right

  defp turn_right(:right), do: :down
  defp turn_right(:down), do: :left
  defp turn_right(:left), do: :up
  defp turn_right(:up), do: :right

  defp reverse(:right), do: :left
  defp reverse(:left), do: :right
  defp reverse(:up), do: :down
  defp reverse(:down), do: :up
end
