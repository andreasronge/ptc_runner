defmodule PtcRunner.Test.LivebookExtractor do
  @moduledoc """
  Helpers for testing the `livebooks/*.livemd` notebooks.

  Livebooks are Markdown with fenced ` ```elixir ` code cells. These helpers
  pull those cells out as plain strings so tests can parse-check or evaluate
  them, keeping the published tutorials honest against the real engine.
  """

  # This file lives in test/support; the livebooks dir is two levels up.
  @livebooks_dir Path.expand("../../livebooks", __DIR__)

  @doc "Absolute path to the `livebooks/` directory."
  def livebooks_dir, do: @livebooks_dir

  @doc "Sorted list of every `.livemd` notebook under `livebooks/`."
  def paths do
    @livebooks_dir
    |> Path.join("*.livemd")
    |> Path.wildcard()
    |> Enum.sort()
  end

  @doc "Reads a notebook and returns its elixir code cells, in document order."
  def elixir_cells(path) do
    path
    |> File.read!()
    |> extract_cells()
  end

  # Matches ```elixir fenced blocks at the start of a line, non-greedily up to
  # the closing fence. The `m` flag anchors ^ to line starts; `s` lets . span
  # newlines so multi-line cells are captured whole.
  @fence ~r/^```elixir\r?\n(.*?)^```/ms

  @doc "Extracts elixir code cells from raw LiveMarkdown content."
  def extract_cells(content) do
    @fence
    |> Regex.scan(content, capture: :all_but_first)
    |> Enum.map(fn [code] -> code end)
  end
end
