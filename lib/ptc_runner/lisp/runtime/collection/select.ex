defmodule PtcRunner.Lisp.Runtime.Collection.Select do
  @moduledoc """
  Selection operations for PTC-Lisp collections: filter, remove, find,
  some, every?, not_any?, take_while, drop_while.

  Each function is collapsed from ~10 type-dispatch clauses to 2-3 by
  delegating predicate/collection normalization to `Collection.Normalize`.
  """

  alias PtcRunner.Lisp.Runtime.Collection.Normalize

  # ── filter ──────────────────────────────────────────────────────────

  # Keyword on string graphemes: keyword access always returns nil → empty
  def filter(pred, coll) when is_atom(pred) and is_binary(coll), do: []

  def filter(pred, coll) when is_map(coll) and not is_struct(coll) do
    pred_fn = Normalize.normalize_pred(pred, :truthy)
    coll |> Enum.filter(fn {k, v} -> pred_fn.([k, v]) end) |> Enum.map(fn {k, v} -> [k, v] end)
  end

  def filter(pred, coll) do
    Enum.filter(Normalize.to_seq(coll), Normalize.normalize_pred(pred, :truthy))
  end

  # ── remove ──────────────────────────────────────────────────────────

  # Keyword on string: always falsy, so nothing is removed
  def remove(pred, coll) when is_atom(pred) and is_binary(coll), do: Normalize.graphemes(coll)

  def remove(pred, coll) when is_map(coll) and not is_struct(coll) do
    pred_fn = Normalize.normalize_pred(pred, :truthy)
    coll |> Enum.reject(fn {k, v} -> pred_fn.([k, v]) end) |> Enum.map(fn {k, v} -> [k, v] end)
  end

  def remove(pred, coll) do
    Enum.reject(Normalize.to_seq(coll), Normalize.normalize_pred(pred, :truthy))
  end

  # ── find ────────────────────────────────────────────────────────────

  # Keyword on string: always nil
  def find(pred, coll) when is_atom(pred) and is_binary(coll), do: nil

  def find(pred, coll) when is_map(coll) and not is_struct(coll) do
    pred_fn = Normalize.normalize_pred(pred, :truthy)

    case Enum.find(coll, fn {k, v} -> pred_fn.([k, v]) end) do
      {k, v} -> [k, v]
      nil -> nil
    end
  end

  def find(pred, coll) do
    Enum.find(Normalize.to_seq(coll), Normalize.normalize_pred(pred, :truthy))
  end

  # ── some ────────────────────────────────────────────────────────────

  def some(pred, coll) when is_map(coll) and not is_struct(coll) do
    pred_fn = Normalize.normalize_pred(pred, :value)
    Enum.find_value(coll, fn {k, v} -> pred_fn.([k, v]) end)
  end

  def some(pred, coll) do
    Enum.find_value(Normalize.to_seq(coll), Normalize.normalize_pred(pred, :value))
  end

  # ── every? ──────────────────────────────────────────────────────────

  def every?(pred, coll) when is_map(coll) and not is_struct(coll) do
    pred_fn = Normalize.normalize_pred(pred, :truthy)
    Enum.all?(coll, fn {k, v} -> pred_fn.([k, v]) end)
  end

  def every?(pred, coll) do
    Enum.all?(Normalize.to_seq(coll), Normalize.normalize_pred(pred, :truthy))
  end

  # ── not_any? ────────────────────────────────────────────────────────

  def not_any?(pred, coll) when is_map(coll) and not is_struct(coll) do
    pred_fn = Normalize.normalize_pred(pred, :truthy)
    not Enum.any?(coll, fn {k, v} -> pred_fn.([k, v]) end)
  end

  def not_any?(pred, coll) do
    not Enum.any?(Normalize.to_seq(coll), Normalize.normalize_pred(pred, :truthy))
  end

  # ── not_every? ────────────────────────────────────────────────────────

  def not_every?(pred, coll) when is_map(coll) and not is_struct(coll) do
    pred_fn = Normalize.normalize_pred(pred, :truthy)
    not Enum.all?(coll, fn {k, v} -> pred_fn.([k, v]) end)
  end

  def not_every?(pred, coll) do
    not Enum.all?(Normalize.to_seq(coll), Normalize.normalize_pred(pred, :truthy))
  end

  # ── take_while ──────────────────────────────────────────────────────

  # Map case: use Stream.map to preserve lazy early-stop semantics
  def take_while(pred, coll) when is_map(coll) and not is_struct(coll) do
    pred_fn = Normalize.normalize_pred(pred, :truthy)
    coll |> Stream.map(fn {k, v} -> [k, v] end) |> Enum.take_while(pred_fn)
  end

  def take_while(pred, coll) do
    Enum.take_while(Normalize.to_seq(coll), Normalize.normalize_pred(pred, :truthy))
  end

  # ── drop_while ──────────────────────────────────────────────────────

  # Map case: use Stream.map to preserve lazy early-stop semantics
  def drop_while(pred, coll) when is_map(coll) and not is_struct(coll) do
    pred_fn = Normalize.normalize_pred(pred, :truthy)
    coll |> Stream.map(fn {k, v} -> [k, v] end) |> Enum.drop_while(pred_fn)
  end

  def drop_while(pred, coll) do
    Enum.drop_while(Normalize.to_seq(coll), Normalize.normalize_pred(pred, :truthy))
  end
end
