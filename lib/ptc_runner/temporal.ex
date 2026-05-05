defmodule PtcRunner.Temporal do
  @moduledoc """
  Normalize Elixir temporal structs (`DateTime`, `NaiveDateTime`, `Date`, `Time`)
  to ISO 8601 strings before they cross any boundary into LLM-visible territory.

  ## Why this exists

  Elixir's `Inspect` protocol renders temporal structs with sigil syntax:

      iex> inspect(~U[2026-05-03 09:14:00Z])
      "~U[2026-05-03 09:14:00Z]"

  That's idiomatic Elixir, but every downstream consumer that expects a parseable
  date string (the LLM, JSON Schema validators, `(java.util.Date. ...)` in
  PTC-Lisp) breaks when it sees the sigil. ISO 8601 is the universal lingua
  franca for temporal data.

  This module is the central seam: any code that exposes Elixir data to an LLM
  or to PTC-Lisp should normalize through `iso8601/1` (for known scalar position)
  or `walk/1` (for arbitrary nested data like tool results).

  ## Functions

  - `iso8601/1` — convert a single value. Pass-through for non-temporal terms.
  - `walk/1` — recursively normalize temporal structs inside maps and lists,
    leaving everything else alone.

  ## Examples

      iex> PtcRunner.Temporal.iso8601(~U[2026-05-03 09:14:00Z])
      "2026-05-03T09:14:00Z"

      iex> PtcRunner.Temporal.iso8601(~D[2026-05-03])
      "2026-05-03"

      iex> PtcRunner.Temporal.iso8601(~N[2026-05-03 09:14:00])
      "2026-05-03T09:14:00"

      iex> PtcRunner.Temporal.iso8601(~T[09:14:00])
      "09:14:00"

      iex> PtcRunner.Temporal.iso8601("hello")
      "hello"

      iex> PtcRunner.Temporal.iso8601(nil)
      nil

      iex> PtcRunner.Temporal.walk(%{at: ~D[2026-05-03], items: [~T[09:14:00]]})
      %{at: "2026-05-03", items: ["09:14:00"]}
  """

  @doc """
  Convert a temporal struct to its ISO 8601 string. Pass-through for everything
  else (including non-temporal structs like user-defined ones).
  """
  @spec iso8601(term()) :: term()
  def iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def iso8601(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  def iso8601(%Date{} = d), do: Date.to_iso8601(d)
  def iso8601(%Time{} = t), do: Time.to_iso8601(t)
  def iso8601(other), do: other

  @doc """
  Recursively walk a value, normalizing any temporal structs found inside maps
  and lists. Non-temporal structs are left untouched at struct boundaries
  (we don't dive into them) since their internal shape is the user's contract.

  Use this for tool results and other arbitrary data that gets JSON-encoded
  or otherwise serialized for the LLM.
  """
  @spec walk(term()) :: term()
  def walk(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def walk(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  def walk(%Date{} = d), do: Date.to_iso8601(d)
  def walk(%Time{} = t), do: Time.to_iso8601(t)
  # Other structs: don't dive in — the struct's internal shape is the user's contract.
  def walk(%_{} = struct), do: struct

  def walk(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, walk(v)} end)
  end

  def walk(list) when is_list(list), do: Enum.map(list, &walk/1)
  def walk(other), do: other
end
