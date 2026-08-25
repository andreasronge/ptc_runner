defmodule PtcRunner.Research.SealedEvidenceLog.Indexes do
  @moduledoc """
  Private ETS indexes and logical versus actual retained accounting.

  Logical index bytes are the conservative `RetainedSize.bytes/1` charge of
  each detached `{family, key, value}` row. Actual ETS allocation is
  `sum(:ets.info(table, :memory)) * word_size`. Owner metadata, paired trace
  facts, and cache state are charged separately and never as a substitute for
  the ETS total. Shared binaries that appear in both owner metadata and an ETS
  row are charged in both places.
  """

  alias PtcRunner.Lisp.RetainedSize
  alias PtcRunner.Research.SealedEvidenceLog.Limits

  @table_names [
    :records,
    :capability_join,
    :provider_join,
    :evaluation_join,
    :prelude_occurrence,
    :turn_projection,
    :collection_order,
    :filter_posting,
    :counts,
    :runs,
    :results,
    :relationships,
    :meta
  ]

  @ordered [
    :records,
    :turn_projection,
    :collection_order,
    :filter_posting,
    :runs
  ]

  @type t :: %{
          tables: %{atom() => :ets.tid()},
          logical_entries: non_neg_integer(),
          logical_bytes: non_neg_integer(),
          owner_metadata: map(),
          trace_facts: map(),
          cache: map(),
          turn_evidence: map()
        }

  @spec create(pid()) :: t()
  def create(heir) when is_pid(heir) do
    tables =
      Map.new(@table_names, fn name ->
        type = if name in @ordered, do: :ordered_set, else: :set

        tid =
          :ets.new(name, [
            type,
            :public,
            :compressed,
            {:read_concurrency, true},
            {:heir, heir, name}
          ])

        {name, tid}
      end)

    %{
      tables: tables,
      logical_entries: 0,
      logical_bytes: 0,
      owner_metadata: %{},
      trace_facts: %{},
      cache: %{},
      turn_evidence: %{}
    }
  end

  @spec insert(t(), atom(), term(), term(), map()) ::
          {:ok, t()} | {:error, :max_index_entries | :max_logical_index_bytes}
  def insert(indexes, family, key, value, limits)
      when is_map(indexes) and is_atom(family) and is_map(limits) do
    row = RetainedSize.detach_binaries({key, value})
    charge = logical_charge(row)
    entries = indexes.logical_entries + 1
    bytes = indexes.logical_bytes + charge

    cond do
      entries > limits.max_index_entries ->
        {:error, :max_index_entries}

      bytes > limits.max_logical_index_bytes ->
        {:error, :max_logical_index_bytes}

      true ->
        table = table_for(family)
        true = :ets.insert(Map.fetch!(indexes.tables, table), row)

        {:ok,
         %{
           indexes
           | logical_entries: entries,
             logical_bytes: bytes
         }}
    end
  end

  @spec put_owner_metadata(t(), map()) :: t()
  def put_owner_metadata(indexes, metadata) when is_map(indexes) and is_map(metadata) do
    %{indexes | owner_metadata: RetainedSize.detach_binaries(metadata)}
  end

  @spec put_trace_facts(t(), map()) :: t()
  def put_trace_facts(indexes, facts) when is_map(indexes) and is_map(facts) do
    %{indexes | trace_facts: RetainedSize.detach_binaries(facts)}
  end

  @spec put_cache(t(), map()) :: t()
  def put_cache(indexes, cache) when is_map(indexes) and is_map(cache) do
    %{indexes | cache: RetainedSize.detach_binaries(cache)}
  end

  @spec put_turn_evidence(t(), map()) :: t()
  def put_turn_evidence(indexes, evidence) when is_map(indexes) and is_map(evidence) do
    %{indexes | turn_evidence: RetainedSize.detach_binaries(evidence)}
  end

  @spec lookup(t(), atom(), term()) :: [term()]
  def lookup(indexes, table, key) when is_map(indexes) and is_atom(table) do
    :ets.lookup(Map.fetch!(indexes.tables, table), key)
  end

  @spec match(t(), atom(), term()) :: [term()]
  def match(indexes, table, pattern) when is_map(indexes) and is_atom(table) do
    :ets.match_object(Map.fetch!(indexes.tables, table), pattern)
  end

  @spec tab2list(t(), atom()) :: [term()]
  def tab2list(indexes, table) when is_map(indexes) and is_atom(table) do
    :ets.tab2list(Map.fetch!(indexes.tables, table))
  end

  @spec table_ids(t()) :: [reference()]
  def table_ids(%{tables: tables}), do: Map.values(tables)

  @spec accounting(t()) :: map()
  def accounting(indexes) when is_map(indexes) do
    word_bytes = Limits.word_bytes()

    ets =
      Enum.map(indexes.tables, fn {name, tid} ->
        memory_words =
          case :ets.info(tid, :memory) do
            words when is_integer(words) -> words
            _other -> 0
          end

        size =
          case :ets.info(tid, :size) do
            count when is_integer(count) -> count
            _other -> 0
          end

        {name,
         %{
           words: memory_words,
           bytes: memory_words * word_bytes,
           entries: size
         }}
      end)
      |> Map.new()

    ets_bytes = ets |> Map.values() |> Enum.reduce(0, &(&1.bytes + &2))
    ets_words = ets |> Map.values() |> Enum.reduce(0, &(&1.words + &2))
    ets_entries = ets |> Map.values() |> Enum.reduce(0, &(&1.entries + &2))
    other = other_retained_bytes(indexes)

    %{
      ets: ets,
      ets_words: ets_words,
      ets_bytes: ets_bytes,
      ets_entries: ets_entries,
      logical_entries: indexes.logical_entries,
      logical_bytes: indexes.logical_bytes,
      other_retained_bytes: other,
      charged_retained_bytes: ets_bytes + other
    }
  end

  @spec within_retained?(t(), map()) :: boolean()
  def within_retained?(indexes, limits) when is_map(indexes) and is_map(limits) do
    accounting(indexes).charged_retained_bytes <= limits.max_retained_bytes
  end

  @spec delete_all(t()) :: :ok
  def delete_all(%{tables: tables}) do
    Enum.each(tables, fn {_name, tid} ->
      if :ets.info(tid) != :undefined, do: :ets.delete(tid)
    end)

    :ok
  end

  @spec undefined?(t()) :: boolean()
  def undefined?(%{tables: tables}) do
    Enum.all?(tables, fn {_name, tid} -> :ets.info(tid) == :undefined end)
  end

  defp table_for(:primary), do: :records
  defp table_for(:join_capability), do: :capability_join
  defp table_for(:join_provider), do: :provider_join
  defp table_for(:join_evaluation), do: :evaluation_join
  defp table_for(:join_prelude), do: :prelude_occurrence
  defp table_for(:turn), do: :turn_projection
  defp table_for(:order), do: :collection_order
  defp table_for(:filter_posting), do: :filter_posting
  defp table_for(:count), do: :counts
  defp table_for(:run), do: :runs
  defp table_for(:result), do: :results
  defp table_for(:relationship), do: :relationships
  defp table_for(:meta), do: :meta

  defp logical_charge(row) do
    case RetainedSize.bytes(row) do
      :oversized -> Limits.defaults().max_logical_index_bytes + 1
      bytes -> bytes
    end
  end

  defp other_retained_bytes(indexes) do
    charge(indexes.owner_metadata) + charge(indexes.trace_facts) + charge(indexes.cache) +
      charge(indexes.turn_evidence)
  end

  defp charge(value) do
    case RetainedSize.bytes(value) do
      :oversized -> 0
      bytes -> bytes
    end
  end
end
