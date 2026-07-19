defmodule PtcRunner.Lisp.Eval.Effects do
  @moduledoc """
  Canonical evaluator audit effects and their ordering algebra.

  Effect lists are stored newest-first while evaluation is in progress. Merging
  therefore places the newer delta before the older value. Prelude call counts
  add, and newer cache writes win key conflicts.
  """

  defstruct tool_calls: [],
            pmap_calls: [],
            prints: [],
            prelude_call_counts: %{},
            tool_cache: %{}

  @type t :: %__MODULE__{
          tool_calls: [map()],
          pmap_calls: [map()],
          prints: [String.t()],
          prelude_call_counts: %{String.t() => non_neg_integer()},
          tool_cache: map()
        }

  @doc "Returns an empty effect value."
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc "Returns an effect value whose cache contains the supplied run baseline."
  @spec with_cache(map()) :: t()
  def with_cache(cache) when is_map(cache), do: %__MODULE__{tool_cache: cache}

  @doc "Records one already-bounded print in newest-first order."
  @spec record_print(t(), String.t()) :: t()
  def record_print(%__MODULE__{} = effects, message) when is_binary(message) do
    %{effects | prints: [message | effects.prints]}
  end

  @doc "Records one already-compacted tool ledger entry in newest-first order."
  @spec record_tool_call(t(), map()) :: t()
  def record_tool_call(%__MODULE__{} = effects, tool_call) when is_map(tool_call) do
    %{effects | tool_calls: [tool_call | effects.tool_calls]}
  end

  @doc "Records one parallel-call ledger entry in newest-first order."
  @spec record_pmap_call(t(), map()) :: t()
  def record_pmap_call(%__MODULE__{} = effects, pmap_call) when is_map(pmap_call) do
    %{effects | pmap_calls: [pmap_call | effects.pmap_calls]}
  end

  @doc "Increments one public prelude-call count."
  @spec record_prelude_call(t(), String.t()) :: t()
  def record_prelude_call(%__MODULE__{} = effects, ref) when is_binary(ref) do
    %{effects | prelude_call_counts: Map.update(effects.prelude_call_counts, ref, 1, &(&1 + 1))}
  end

  @doc "Records one cache write."
  @spec record_cache(t(), term(), term()) :: t()
  def record_cache(%__MODULE__{} = effects, key, value) do
    %{effects | tool_cache: Map.put(effects.tool_cache, key, value)}
  end

  @doc "Adds prelude-call counts without changing other effect fields."
  @spec add_prelude_counts(t(), %{String.t() => non_neg_integer()}) :: t()
  def add_prelude_counts(%__MODULE__{} = effects, counts) when is_map(counts) do
    %{effects | prelude_call_counts: merge_counts(counts, effects.prelude_call_counts)}
  end

  @doc """
  Merges a newer effect value onto an older one.

  Lists remain newest-first, counts add, and newer cache entries win.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = newer, %__MODULE__{} = older) do
    %__MODULE__{
      tool_calls: newer.tool_calls ++ older.tool_calls,
      pmap_calls: newer.pmap_calls ++ older.pmap_calls,
      prints: newer.prints ++ older.prints,
      prelude_call_counts: merge_counts(newer.prelude_call_counts, older.prelude_call_counts),
      tool_cache: Map.merge(older.tool_cache, newer.tool_cache)
    }
  end

  @doc """
  Computes the effects added to a cumulative value after a baseline.

  List suffixes and count baselines are removed. Cache entries are retained
  when their value differs from the baseline, including overwrites of an
  existing key.
  """
  @spec delta(t(), t()) :: t()
  def delta(%__MODULE__{} = cumulative, %__MODULE__{} = baseline) do
    %__MODULE__{
      tool_calls: strip_baseline_suffix(cumulative.tool_calls, baseline.tool_calls),
      pmap_calls: strip_baseline_suffix(cumulative.pmap_calls, baseline.pmap_calls),
      prints: strip_baseline_suffix(cumulative.prints, baseline.prints),
      prelude_call_counts:
        subtract_baseline_counts(cumulative.prelude_call_counts, baseline.prelude_call_counts),
      tool_cache: changed_cache_entries(cumulative.tool_cache, baseline.tool_cache)
    }
  end

  @doc "Merges effect deltas already ordered by ascending semantic execution order."
  @spec merge_ordered([t()]) :: t()
  def merge_ordered(ordered_effects) when is_list(ordered_effects) do
    Enum.reduce(ordered_effects, empty(), fn effects, accumulated ->
      merge(effects, accumulated)
    end)
  end

  @doc "Returns effects in their public chronological representation."
  @spec chronological(t()) :: t()
  def chronological(%__MODULE__{} = effects) do
    %{
      effects
      | tool_calls: Enum.reverse(effects.tool_calls),
        pmap_calls: Enum.reverse(effects.pmap_calls),
        prints: Enum.reverse(effects.prints)
    }
  end

  defp merge_counts(newer, older) do
    Map.merge(older, newer, fn _ref, older_count, newer_count -> older_count + newer_count end)
  end

  defp strip_baseline_suffix(values, []), do: values

  defp strip_baseline_suffix(values, baseline) do
    added = length(values) - length(baseline)

    if added >= 0 and Enum.drop(values, added) == baseline,
      do: Enum.take(values, added),
      else: values
  end

  defp subtract_baseline_counts(counts, baseline) do
    Enum.reduce(counts, %{}, fn {ref, count}, delta ->
      case count - Map.get(baseline, ref, 0) do
        added when added > 0 -> Map.put(delta, ref, added)
        _non_positive -> delta
      end
    end)
  end

  defp changed_cache_entries(cache, baseline) do
    Map.reject(cache, fn {key, value} -> Map.fetch(baseline, key) === {:ok, value} end)
  end
end
