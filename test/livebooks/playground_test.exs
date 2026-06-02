defmodule PtcRunner.LivebookPlaygroundTest do
  @moduledoc """
  End-to-end check of `livebooks/ptc_runner_playground.livemd`.

  The playground is fully deterministic — in-memory tool functions, no LLM, no
  network — so we can evaluate its cells against the real `PtcRunner.Lisp`
  engine and assert the exact results the tutorial promises. If the public API
  the playground teaches ever drifts, this test fails.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias PtcRunner.Test.LivebookExtractor

  @path Path.join(LivebookExtractor.livebooks_dir(), "ptc_runner_playground.livemd")

  test "playground cells run against the real engine and produce the documented results" do
    # Drop the Mix.install cell — ptc_runner is already loaded in the test
    # runtime, and re-installing would be slow and pointless here.
    cells =
      @path
      |> LivebookExtractor.elixir_cells()
      |> Enum.reject(&String.contains?(&1, "Mix.install"))

    assert cells != [], "no runnable cells found in the playground livebook"

    {values, output} = with_io(fn -> eval_cells(cells) end)

    # Both the PTC-Lisp and plain-Clojure forms of the basic example sum the
    # two travel expenses (500 + 200) to 700.
    assert output =~ "Travel expenses: 700"
    assert output =~ "Travel expenses (Clojure style): 700"

    # The `let` cell returns an aggregate map. Keys come back as a mix of atoms
    # and strings depending on the builtin, so normalize before matching.
    assert Enum.any?(values, fn value ->
             is_map(value) and match?(%{"count" => 2, "total" => 700}, stringify_keys(value))
           end),
           "expected the let cell to aggregate 2 travel expenses totalling 700"

    # The grouping cell returns one row per category with per-group totals.
    assert Enum.any?(values, fn value ->
             is_list(value) and
               has_row?(value, %{"category" => "travel", "total" => 700, "count" => 2}) and
               has_row?(value, %{"category" => "food", "total" => 125, "count" => 2})
           end),
           "expected the grouping cell to total travel=700 and food=125"
  end

  defp has_row?(rows, expected) do
    Enum.any?(rows, fn row ->
      is_map(row) and Enum.all?(expected, fn {k, v} -> Map.get(stringify_keys(row), k) == v end)
    end)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  # Evaluate cells in sequence, threading the binding so later cells see the
  # variables earlier ones defined — exactly as Livebook would. Returns the
  # value of each cell in order. A cell that raises (e.g. a failed `{:ok, step}`
  # match) fails the test loudly, which is the point.
  defp eval_cells(cells) do
    {values, _binding} =
      Enum.reduce(cells, {[], []}, fn code, {values, binding} ->
        {value, binding} = Code.eval_string(code, binding)
        {[value | values], binding}
      end)

    Enum.reverse(values)
  end
end
