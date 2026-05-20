defmodule PtcRunnerMcp.DebugBuffer do
  @moduledoc """
  In-memory ring buffer of recent `tools/call` records, backing the
  opt-in `lisp_debug` diagnostics tool.

  See `Plans/ptc-runner-mcp-debug-tool.md` § 5. A `GenServer` owns a
  private ETS `:ordered_set` keyed by a monotonically increasing
  integer. `record/1` is a fire-and-forget cast that must never make a
  `tools/call` fail; `stats/1`, `recent/1`, and `get/1` are reads over
  in-memory data only (no disk access).

  Started as a supervised child of `PtcRunnerMcp.Supervisor` **only
  when `--debug-tool` is set**. When the process is absent (or
  overloaded), `record/1` degrades silently and the reads return empty
  results — same graceful-degradation contract as a failed trace write.

  Records are stored already redacted per `--trace-payloads`; this
  module never re-redacts. It is a dumb buffer + aggregator.
  """

  use GenServer

  alias PtcRunnerMcp.{DebugConfig, Log}

  @table_name __MODULE__.Table

  @typedoc """
  Stored call record (atom-keyed; already redacted per
  `--trace-payloads`). See `Plans/ptc-runner-mcp-debug-tool.md` § 5.1.
  """
  @type record :: %{
          required(:request_id) => String.t(),
          required(:ts) => DateTime.t(),
          required(:tool) => String.t(),
          required(:status) => :ok | :error,
          required(:is_error) => boolean(),
          required(:reason) => String.t() | nil,
          required(:duration_ms) => non_neg_integer(),
          required(:program) => map() | String.t() | nil,
          required(:context) => map() | nil,
          required(:result_bytes) => non_neg_integer() | nil,
          required(:prints_count) => non_neg_integer() | nil,
          required(:signature_present?) => boolean(),
          required(:protocol_version) => String.t() | nil,
          required(:upstream_calls) => [map()],
          # `Plans/ptc-runner-mcp-payload-reduction.md` §4.5: the
          # envelope's `ptc_metrics` block (string-keyed) or `nil`.
          required(:ptc_metrics) => map() | nil,
          required(:agentic) => map() | nil
        }

  # ----------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------

  @doc "Start the buffer GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # Load-shed threshold for the recorder's mailbox. A burst of call
  # completions can enqueue casts faster than the buffer drains them, and the
  # mailbox is not bounded by `ring_size` (the ETS ring is trimmed only after a
  # message is processed). Once the queue is this deep we drop new records —
  # diagnostics are best-effort; an unbounded mailbox is not acceptable.
  @max_mailbox 1_000

  @doc """
  Record one call record. Fire-and-forget cast: never blocks, never
  fails the caller, a silent no-op when the buffer is not running, and
  load-sheds (drops the record) when the buffer's mailbox is backed up.
  """
  @spec record(record()) :: :ok
  def record(rec) when is_map(rec) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, n} when is_integer(n) and n >= @max_mailbox ->
            :ok

          _ ->
            GenServer.cast(pid, {:record, rec})
            :ok
        end
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Aggregate stats over the ring (optionally windowed). Returns a map
  shaped per `Plans/ptc-runner-mcp-debug-tool.md` § 6.3 (`op: stats`),
  or an "empty ring" snapshot when the buffer is not running.

  Options: `:since_seconds` (only calls newer than this),
  `:errors_only` (restrict to status == error).
  """
  @spec stats(keyword()) :: map()
  def stats(opts \\ []) do
    case safe_call({:stats, opts}) do
      {:ok, result} -> result
      :error -> empty_stats()
    end
  end

  @doc """
  Most recent records (newest first), shaped per § 6.3 (`op: recent`).

  Options: `:limit` (default 20, capped at 200), `:since_seconds`,
  `:errors_only`.
  """
  @spec recent(keyword()) :: [record()]
  def recent(opts \\ []) do
    case safe_call({:recent, opts}) do
      {:ok, result} -> result
      :error -> []
    end
  end

  @doc "Fetch the full record for `request_id`, or `:not_found`."
  @spec get(String.t()) :: {:ok, record()} | :not_found
  def get(request_id) when is_binary(request_id) do
    case safe_call({:get, request_id}) do
      {:ok, result} -> result
      :error -> :not_found
    end
  end

  @doc "Current number of records in the ring (test helper)."
  @spec count() :: non_neg_integer()
  def count do
    case safe_call(:count) do
      {:ok, n} -> n
      :error -> 0
    end
  end

  defp safe_call(msg) do
    case Process.whereis(__MODULE__) do
      nil ->
        :error

      pid when is_pid(pid) ->
        try do
          {:ok, GenServer.call(pid, msg, 5_000)}
        catch
          :exit, _ -> :error
        end
    end
  end

  # ----------------------------------------------------------------
  # GenServer
  # ----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    ring_size = Keyword.get(opts, :ring_size) || DebugConfig.ring_size()
    table = :ets.new(@table_name, [:ordered_set, :private])
    {:ok, %{table: table, ring_size: ring_size, seq: 0}}
  end

  @impl GenServer
  def handle_cast({:record, rec}, state) do
    seq = state.seq + 1
    :ets.insert(state.table, {seq, rec})
    evict_excess(state.table, state.ring_size)
    {:noreply, %{state | seq: seq}}
  rescue
    error ->
      Log.log(:warn, "debug_buffer_record_failed", %{
        kind: inspect(error.__struct__),
        message: Exception.message(error)
      })

      {:noreply, state}
  end

  @impl GenServer
  def handle_call(:count, _from, state) do
    {:reply, :ets.info(state.table, :size), state}
  end

  def handle_call({:stats, opts}, _from, state) do
    records = filtered_records(state.table, opts)
    {:reply, compute_stats(records, state.ring_size, :ets.info(state.table, :size)), state}
  end

  def handle_call({:recent, opts}, _from, state) do
    limit = opts |> Keyword.get(:limit, 20) |> normalize_limit()

    records =
      state.table
      |> filtered_records(opts)
      |> Enum.reverse()
      |> Enum.take(limit)

    {:reply, records, state}
  end

  def handle_call({:get, request_id}, _from, state) do
    result =
      state.table
      |> all_records()
      |> Enum.reverse()
      |> Enum.find(fn rec -> rec.request_id == request_id end)
      |> case do
        nil -> :not_found
        rec -> {:ok, rec}
      end

    {:reply, result, state}
  end

  # ----------------------------------------------------------------
  # ETS helpers
  # ----------------------------------------------------------------

  defp evict_excess(table, ring_size) do
    over = :ets.info(table, :size) - ring_size

    if over > 0 do
      _ =
        Enum.reduce(1..over, :ets.first(table), fn _i, key ->
          case key do
            :"$end_of_table" ->
              key

            k ->
              next = :ets.next(table, k)
              :ets.delete(table, k)
              next
          end
        end)
    end

    :ok
  end

  # Oldest-first list of records.
  defp all_records(table) do
    :ets.tab2list(table)
    |> Enum.sort_by(fn {seq, _rec} -> seq end)
    |> Enum.map(fn {_seq, rec} -> rec end)
  end

  # Oldest-first list, filtered by `:since_seconds` and `:errors_only`.
  defp filtered_records(table, opts) do
    since_seconds = Keyword.get(opts, :since_seconds)
    errors_only? = Keyword.get(opts, :errors_only, false) == true
    cutoff = since_seconds && DateTime.add(DateTime.utc_now(), -since_seconds, :second)

    table
    |> all_records()
    |> Enum.filter(fn rec ->
      time_ok? = is_nil(cutoff) or DateTime.compare(rec.ts, cutoff) != :lt
      status_ok? = not errors_only? or rec.status == :error
      time_ok? and status_ok?
    end)
  end

  defp normalize_limit(n) when is_integer(n) and n >= 1, do: min(n, 200)
  defp normalize_limit(_), do: 20

  # ----------------------------------------------------------------
  # Stats computation
  # ----------------------------------------------------------------

  defp empty_stats do
    %{
      debug_source: "ring_buffer",
      ring_size: DebugConfig.ring_size(),
      ring_count: 0,
      window: %{from: nil, to: nil, calls: 0},
      by_tool: %{},
      errors: %{by_reason: %{}},
      upstream_calls: nil,
      agentic: nil,
      payload_reduction: nil
    }
  end

  defp compute_stats([], ring_size, ring_count) do
    %{empty_stats() | ring_size: ring_size, ring_count: ring_count}
  end

  defp compute_stats(records, ring_size, ring_count) do
    timestamps = Enum.map(records, & &1.ts)

    %{
      debug_source: "ring_buffer",
      ring_size: ring_size,
      ring_count: ring_count,
      window: %{
        from: Enum.min(timestamps, DateTime),
        to: Enum.max(timestamps, DateTime),
        calls: length(records)
      },
      by_tool: by_tool(records),
      errors: %{by_reason: count_by(records, fn r -> if r.status == :error, do: r.reason end)},
      upstream_calls: upstream_stats(records),
      agentic: agentic_stats(records),
      payload_reduction: payload_reduction_stats(records)
    }
  end

  defp by_tool(records) do
    records
    |> Enum.group_by(& &1.tool)
    |> Map.new(fn {tool, recs} ->
      ok = Enum.count(recs, &(&1.status == :ok))
      error = Enum.count(recs, &(&1.status == :error))
      calls = length(recs)
      durations = recs |> Enum.map(& &1.duration_ms) |> Enum.reject(&is_nil/1)

      {tool,
       %{
         calls: calls,
         ok: ok,
         error: error,
         error_rate: if(calls > 0, do: Float.round(error / calls, 3), else: 0.0),
         duration_ms: percentiles(durations)
       }}
    end)
  end

  @doc false
  @spec percentiles([non_neg_integer()]) :: %{p50: integer(), p95: integer(), max: integer()}
  def percentiles([]), do: %{p50: 0, p95: 0, max: 0}

  def percentiles(values) do
    sorted = Enum.sort(values)

    %{
      p50: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95),
      max: List.last(sorted)
    }
  end

  # Nearest-rank percentile (1-indexed). `sorted` is non-empty.
  defp percentile(sorted, q) do
    n = length(sorted)
    rank = max(1, round(Float.ceil(q * n)))
    Enum.at(sorted, min(rank, n) - 1)
  end

  # Per-reason histogram with unknown reasons passing through verbatim.
  # `fun.(record)` returns the bucket key (a binary) or nil/falsey to skip.
  defp count_by(records, fun) do
    Enum.reduce(records, %{}, fn rec, acc ->
      case fun.(rec) do
        key when is_binary(key) -> Map.update(acc, key, 1, &(&1 + 1))
        _ -> acc
      end
    end)
  end

  defp upstream_stats(records) do
    entries = Enum.flat_map(records, fn r -> r.upstream_calls || [] end)

    if entries == [] do
      nil
    else
      ok = Enum.count(entries, &(Map.get(&1, "status") == "ok"))

      %{
        total: length(entries),
        ok: ok,
        by_reason: count_by(entries, &upstream_reason/1),
        by_server: upstream_by_server(entries)
      }
    end
  end

  defp upstream_by_server(entries) do
    entries
    |> Enum.group_by(fn e -> to_string(Map.get(e, "server", "")) end)
    |> Map.new(fn {server, es} ->
      ok = Enum.count(es, &(Map.get(&1, "status") == "ok"))

      {server,
       %{
         total: length(es),
         ok: ok,
         by_reason: count_by(es, &upstream_reason/1)
       }}
    end)
  end

  defp upstream_reason(entry) do
    case Map.get(entry, "status") do
      "error" ->
        case Map.get(entry, "reason") do
          r when is_binary(r) -> r
          _ -> "upstream_error"
        end

      _ ->
        nil
    end
  end

  defp agentic_stats(records) do
    tasks = Enum.filter(records, &(&1.tool == "lisp_task"))

    if tasks == [] do
      nil
    else
      with_agentic = Enum.filter(tasks, &is_map(&1.agentic))

      %{
        tasks: length(tasks),
        planner_calls: length(with_agentic),
        planner_errors: Enum.count(with_agentic, &(&1.agentic[:planner_status] == :error)),
        planner_rejects:
          with_agentic |> Enum.map(&(&1.agentic[:planner_rejects] || 0)) |> Enum.sum(),
        retries: with_agentic |> Enum.map(&(&1.agentic[:retries] || 0)) |> Enum.sum()
      }
    end
  end

  # ----------------------------------------------------------------
  # payload_reduction aggregate
  # (Plans/ptc-runner-mcp-payload-reduction.md §4.4)
  # ----------------------------------------------------------------
  #
  # Built from the per-call `ptc_metrics` blocks the recorder copied
  # into the ring. `null` when the window has no call carrying one.
  # The per-call ratios that are `null` (pure-compute / all-failed /
  # errored) are skipped from p50/p95/max; `weighted` is computed from
  # the totals (with the same `max(.., 1)` denominator guard).
  defp payload_reduction_stats(records) do
    with_metrics =
      records
      |> Enum.map(fn r -> {r, Map.get(r, :ptc_metrics)} end)
      |> Enum.filter(fn {_r, m} -> is_map(m) end)

    if with_metrics == [] do
      nil
    else
      total_final = sum_metric(with_metrics, "final_result_bytes")
      total_upstream = sum_metric(with_metrics, "upstream_result_bytes")
      total_error = sum_metric(with_metrics, "upstream_error_bytes")
      total_oversize = sum_metric(with_metrics, "upstream_oversize_bytes")
      total_calls = sum_metric(with_metrics, "upstream_call_count")

      ratios =
        with_metrics
        |> Enum.map(fn {_r, m} -> Map.get(m, "payload_reduction_ratio") end)
        |> Enum.filter(&is_number/1)

      %{
        schema_version: 1,
        calls_with_metrics: length(with_metrics),
        total_final_result_bytes: total_final,
        total_upstream_result_bytes: total_upstream,
        total_upstream_error_bytes: total_error,
        total_upstream_oversize_bytes: total_oversize,
        total_upstream_calls: total_calls,
        reduction_ratio: ratio_summary(ratios, total_upstream, total_final),
        estimated_tokens: %{
          final_result: est_tokens(total_final),
          upstream_result: est_tokens(total_upstream),
          method: "utf8_bytes_div_4"
        },
        top_reducers: top_reducers(with_metrics),
        agentic_planner: agentic_planner_stats(with_metrics)
      }
    end
  end

  defp sum_metric(with_metrics, key) do
    Enum.reduce(with_metrics, 0, fn {_r, m}, acc ->
      case Map.get(m, key) do
        n when is_integer(n) and n >= 0 -> acc + n
        _ -> acc
      end
    end)
  end

  defp ratio_summary([], total_upstream, total_final) do
    %{p50: nil, p95: nil, max: nil, weighted: weighted_ratio(total_upstream, total_final)}
  end

  defp ratio_summary(ratios, total_upstream, total_final) do
    sorted = Enum.sort(ratios)

    %{
      p50: float_percentile(sorted, 0.50),
      p95: float_percentile(sorted, 0.95),
      max: List.last(sorted),
      weighted: weighted_ratio(total_upstream, total_final)
    }
  end

  # `total_upstream_result_bytes / max(total_final_result_bytes, 1)` —
  # `null` when either total is 0 (same honesty rule as the per-call
  # ratio).
  defp weighted_ratio(total_upstream, total_final)
       when is_integer(total_upstream) and is_integer(total_final) do
    if total_upstream <= 0 or total_final <= 0 do
      nil
    else
      Float.round(total_upstream / max(total_final, 1), 2)
    end
  end

  # Nearest-rank percentile over a non-empty sorted float list.
  defp float_percentile(sorted, q) do
    n = length(sorted)
    rank = max(1, round(Float.ceil(q * n)))
    Enum.at(sorted, min(rank, n) - 1)
  end

  # `ceil(n / 4)` — the `utf8_bytes_div_4` token estimate, over a
  # non-negative integer.
  defp est_tokens(n) when is_integer(n) and n >= 0, do: div(n + 3, 4)

  # Up to 10 calls with the highest per-call `payload_reduction_ratio`,
  # newest as the tie-break. Calls whose ratio is `null` never appear.
  defp top_reducers(with_metrics) do
    with_metrics
    |> Enum.filter(fn {_r, m} -> is_number(Map.get(m, "payload_reduction_ratio")) end)
    |> Enum.sort_by(
      fn {r, m} -> {Map.get(m, "payload_reduction_ratio"), r.ts} end,
      fn {ratio_a, ts_a}, {ratio_b, ts_b} ->
        cond do
          ratio_a > ratio_b -> true
          ratio_a < ratio_b -> false
          # Equal ratio → newer ts first.
          true -> DateTime.compare(ts_a, ts_b) != :lt
        end
      end
    )
    |> Enum.take(10)
    |> Enum.map(fn {r, m} ->
      %{
        request_id: r.request_id,
        ts: r.ts,
        tool: r.tool,
        final_result_bytes: int_or_zero(Map.get(m, "final_result_bytes")),
        upstream_result_bytes: int_or_zero(Map.get(m, "upstream_result_bytes")),
        ratio: Map.get(m, "payload_reduction_ratio")
      }
    end)
  end

  # The `agentic_planner` sub-block — present only when the window has
  # ≥ 1 `lisp_task` call carrying `ptc_metrics.server_side_llm`.
  defp agentic_planner_stats(with_metrics) do
    tasks =
      with_metrics
      |> Enum.filter(fn {r, m} ->
        r.tool == "lisp_task" and is_map(Map.get(m, "server_side_llm"))
      end)
      |> Enum.map(fn {_r, m} -> Map.get(m, "server_side_llm") end)

    if tasks == [] do
      nil
    else
      provider_reported = Enum.count(tasks, &(Map.get(&1, "provider_reported") == true))
      all_provider_reported? = provider_reported == length(tasks)

      %{
        tasks: length(tasks),
        provider_reported_tasks: provider_reported,
        total_prompt_tokens:
          if(all_provider_reported?, do: sum_token_field(tasks, "prompt_tokens")),
        total_completion_tokens:
          if(all_provider_reported?, do: sum_token_field(tasks, "completion_tokens")),
        total_prompt_bytes: sum_token_field(tasks, "prompt_bytes"),
        total_completion_bytes: sum_token_field(tasks, "completion_bytes"),
        estimated_total_tokens:
          est_tokens(sum_token_field(tasks, "prompt_bytes")) +
            est_tokens(sum_token_field(tasks, "completion_bytes"))
      }
    end
  end

  defp sum_token_field(tasks, key) do
    Enum.reduce(tasks, 0, fn t, acc ->
      case Map.get(t, key) do
        n when is_integer(n) and n >= 0 -> acc + n
        _ -> acc
      end
    end)
  end

  defp int_or_zero(n) when is_integer(n) and n >= 0, do: n
  defp int_or_zero(_), do: 0
end
