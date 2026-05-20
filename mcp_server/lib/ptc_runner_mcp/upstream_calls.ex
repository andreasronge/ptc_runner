defmodule PtcRunnerMcp.UpstreamCalls do
  @moduledoc """
  Collector helpers for the per-`tools/call` `upstream_calls`
  side-channel.

  Per `Plans/ptc-runner-mcp-aggregator.md` §6.4 + §8.5: the MCP
  request handler is the collector. Each `(tool/mcp-call ...)`
  closure invocation sends `{:upstream_call_recorded, ref, entry}`
  to the worker process at completion; the worker drains its mailbox
  in arrival order (= upstream call **completion order**) and
  decorates the structured payload with the resulting list.

  ## Entry shape (§8.5)

  Required fields: `server`, `tool`, `status`, `duration_ms`.
  When `status == "error"`, `reason` and `error` are also required.

      %{
        "server"      => "github",
        "tool"        => "search_repos",
        "status"      => "ok",
        "duration_ms" => 420
      }

      %{
        "server"      => "github",
        "tool"        => "search_repos",
        "status"      => "error",
        "duration_ms" => 5000,
        "reason"      => "timeout",
        "error"       => "request exceeded 5000ms"
      }

  ## Drain semantics (§6.4 step 4)

  The drain runs **only on normal completion or a caught Lisp/runtime
  error** producing an envelope. Cancellation / worker crash skips
  the drain entirely (per MCP semantics no envelope is sent for
  cancelled requests).

  The unique `ref` is matched explicitly to isolate this request's
  entries even if process reuse is ever introduced.
  """

  alias PtcRunnerMcp.Credentials.Redactor

  @typedoc "An entry recorded for a single `(tool/mcp-call ...)` invocation."
  @type entry :: %{required(String.t()) => term()}

  @typedoc """
  Closed map of state shared by the worker (collector) and every
  `mcp-call` closure executing under it. The closure captures the
  entire context — never the process dictionary, never ETS — so
  `pmap` children spawned with empty pdicts still see the same
  counter, ref, and limits.
  """
  @type call_context :: %{
          required(:collector_pid) => pid(),
          required(:collector_ref) => reference(),
          required(:call_counter) => :atomics.atomics_ref(),
          required(:catalog_op_counter) => :atomics.atomics_ref(),
          required(:failure_cache) => :ets.tid(),
          required(:max_calls) => pos_integer(),
          required(:max_catalog_ops) => pos_integer(),
          required(:call_timeout_ms) => pos_integer(),
          required(:max_response_bytes) => pos_integer(),
          required(:max_catalog_result_bytes) => pos_integer()
        }

  @doc """
  Builds a fresh `call_context` for a worker handling one
  `tools/call`.

  Per `Plans/ptc-runner-mcp-aggregator.md` §6.4 cap closure:

    * `:call_counter` — 1-slot `:atomics` ref for the per-program
      upstream-call cap. Closure-captured (not pdict, not ETS) per
      §6.4 so `pmap` children incrementing in parallel never lose
      a count.

      **Spec deviation:** §6.4 specifies `:counters.new(1, [])`, but
      `:counters.add/3` returns `:ok` (not the new value), so the
      spec's pseudocode `n = :counters.add(...)` is not implementable
      atomically — bump-then-`get` is two steps and races under
      contention. Codex review of `8b9a3fc` flagged that with
      `cap=1` and 2 concurrent calls the bump-then-get pattern can
      reject **both** (both reads see 2 > 1 after both bumps).
      `:atomics.add_get/3` is the right primitive — it returns the
      post-increment value atomically, giving each caller a unique
      slot number and precise rejection. Spec is being amended.
    * `:failure_cache` — owned-by-collector ETS table tracking
      `name -> {reason, detail}` for upstreams whose
      `ensure_started/2` already failed in **this program**. Per
      §4.3: "no automatic retry within a single program; the next
      program is a fresh attempt." Lifetime is tied to the
      collector pid — auto-deletion on worker death (cancellation
      / crash) means a fresh program always starts with an empty
      cache.

  ETS is the right shape for the failure cache (vs `:atomics`)
  because the value type is `{atom, binary}` not an integer, and
  access is read-mostly with concurrent writers from `pmap`
  children. The table is `:public` and `:set` so multiple writers
  race safely on duplicate keys (last-write-wins on detail; reason
  is identical across concurrent `ensure_started` for the same
  name in the same program because the registry serializes
  per-name).
  """
  @spec new_call_context(keyword()) :: call_context()
  def new_call_context(opts \\ []) do
    %{
      collector_pid: Keyword.get(opts, :collector_pid, self()),
      collector_ref: Keyword.get(opts, :collector_ref, make_ref()),
      call_counter: :atomics.new(1, signed: false),
      catalog_op_counter: :atomics.new(1, signed: false),
      failure_cache: :ets.new(:upstream_failure_cache, [:set, :public]),
      max_calls: Keyword.fetch!(opts, :max_calls),
      max_catalog_ops: Keyword.get(opts, :max_catalog_ops, 25),
      call_timeout_ms: Keyword.fetch!(opts, :call_timeout_ms),
      max_response_bytes: Keyword.fetch!(opts, :max_response_bytes),
      max_catalog_result_bytes: Keyword.get(opts, :max_catalog_result_bytes, 262_144)
    }
  end

  @doc """
  Records that this program's `ensure_started(name)` already failed
  with `{reason, detail}`. Subsequent `(tool/mcp-call ...)` calls
  targeting `name` in the same program short-circuit via
  `cached_failure/2` and return `nil` without re-attempting the
  spawn (§4.3 "no automatic retry within a single program").
  """
  @spec mark_failure(call_context(), String.t(), atom(), String.t()) :: :ok
  def mark_failure(%{failure_cache: tid}, name, reason, detail)
      when is_binary(name) and is_atom(reason) and is_binary(detail) do
    :ets.insert(tid, {name, {reason, detail}})
    :ok
  end

  @doc """
  Returns `{:cached, reason, detail}` if `name`'s `ensure_started/2`
  has already failed in this program, or `:miss` otherwise.
  """
  @spec cached_failure(call_context(), String.t()) ::
          {:cached, atom(), String.t()} | :miss
  def cached_failure(%{failure_cache: tid}, name) when is_binary(name) do
    case :ets.lookup(tid, name) do
      [{^name, {reason, detail}}] -> {:cached, reason, detail}
      [] -> :miss
    end
  end

  # ----------------------------------------------------------------
  # Leader/follower lock for `ensure_started/2` (§4.3 first bullet)
  # ----------------------------------------------------------------
  #
  # Per §4.3: "no automatic retry of `ensure_started/1` within a
  # single program." Within-program serialization across the
  # `Upstream.Registry` GenServer alone is insufficient — N
  # concurrent `pmap` branches all observe `cached_failure/2 → :miss`
  # at once, all submit their own `ensure_started/2`, and even
  # though the registry serializes per-name they all run a real
  # spawn attempt.
  #
  # Approach (a): ETS-based leader/follower. The first `pmap`
  # branch to `:ets.insert_new({:ensure_lock, name}, leader_pid)`
  # becomes the leader and runs `ensure_started/2` exactly once.
  # Followers (whose `insert_new` returned false) poll for the
  # leader's published result via `await_ensure_result/3`. The
  # poll budget is bounded by `upstream_call_timeout_ms` so a
  # hung leader cannot stall a follower forever.

  @doc """
  Attempts to acquire the per-program `ensure_started` leader
  lock for `name`. Returns `:leader` if this caller won the race
  and MUST run `ensure_started/2`, or `:follower` if another
  caller is already running it (and this caller MUST wait via
  `await_ensure_result/3`).
  """
  @spec acquire_ensure_lock(call_context(), String.t()) :: :leader | :follower
  def acquire_ensure_lock(%{failure_cache: tid}, name) when is_binary(name) do
    if :ets.insert_new(tid, {{:ensure_lock, name}, self()}) do
      :leader
    else
      :follower
    end
  end

  @doc """
  Publishes the leader's `ensure_started/2` outcome and releases
  the lock so any waiting followers can replay it.
  """
  @spec publish_ensure_result(call_context(), String.t(), :ok | {:error, atom(), String.t()}) ::
          :ok
  def publish_ensure_result(%{failure_cache: tid}, name, result) when is_binary(name) do
    :ets.insert(tid, {{:ensure_result, name}, result})
    :ets.delete(tid, {:ensure_lock, name})
    :ok
  end

  @doc """
  Waits up to `timeout_ms` for the leader to publish an
  `ensure_started/2` result for `name`. Returns the published
  result, or `{:error, :timeout, detail}` if the leader did not
  finish within the budget.

  Polls every `1` ms via `receive after` (no `Process.sleep`).
  The total budget matches `upstream_call_timeout_ms`: any
  ensure_started taking longer than that would already breach
  the per-call SLO regardless of who won the lock.
  """
  @spec await_ensure_result(call_context(), String.t(), pos_integer()) ::
          :ok | {:error, atom(), String.t()}
  def await_ensure_result(%{failure_cache: tid}, name, timeout_ms)
      when is_binary(name) and is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_ensure_result(tid, name, deadline)
  end

  defp do_await_ensure_result(tid, name, deadline) do
    case :ets.lookup(tid, {:ensure_result, name}) do
      [{{:ensure_result, ^name}, result}] ->
        result

      [] ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          {:error, :timeout, "ensure_started leader did not publish a result within timeout"}
        else
          # `receive after` is the spec-approved primitive for
          # bounded polling (no `Process.sleep` per CLAUDE.md).
          # 1 ms granularity keeps poll-spin latency low without
          # busy-burning a scheduler.
          receive do
          after
            1 -> do_await_ensure_result(tid, name, deadline)
          end
        end
    end
  end

  @doc """
  Atomically increments the catalog operation counter and checks
  against the per-program cap. Returns `:proceed` if under the
  limit, `:cap_exhausted` otherwise.
  """
  @spec check_catalog_cap(call_context()) :: :proceed | :cap_exhausted
  def check_catalog_cap(%{catalog_op_counter: counter, max_catalog_ops: max_ops}) do
    slot = :atomics.add_get(counter, 1, 1)
    if slot <= max_ops, do: :proceed, else: :cap_exhausted
  end

  @doc """
  Sends a recorded `entry` to the collector worker and returns
  `:ok`. Closures running in `pmap` child processes use this to
  deliver their entry back to the (single) request handler.

  The entry **MUST** already conform to §8.5 — use `success_entry/3`
  or `error_entry/5` to construct it.
  """
  @spec record(call_context(), entry()) :: :ok
  def record(%{collector_pid: pid, collector_ref: ref}, entry) when is_map(entry) do
    send(pid, {:upstream_call_recorded, ref, entry})
    :ok
  end

  @doc """
  Builds a successful-call entry (§8.5).

  Per `Plans/ptc-runner-mcp-payload-reduction.md` §4.1 the entry also
  carries `result_bytes` — the byte size of the upstream response *as
  the aggregator received it*, before any `--trace-payloads`
  redaction — and `oversize` (always `false` for a successful call).
  Pass `:result_bytes` in `opts`; omit it (or pass `nil`) when the
  size is not cheaply known.
  """
  @spec success_entry(String.t(), String.t(), non_neg_integer(), keyword()) :: entry()
  def success_entry(server, tool, duration_ms, opts \\ [])
      when is_binary(server) and is_binary(tool) and is_integer(duration_ms) and duration_ms >= 0 and
             is_list(opts) do
    %{
      "server" => server,
      "tool" => tool,
      "status" => "ok",
      "duration_ms" => duration_ms,
      "result_bytes" => normalize_result_bytes(Keyword.get(opts, :result_bytes)),
      "oversize" => false
    }
    |> maybe_put_result_overview(Keyword.get(opts, :result_overview))
  end

  @doc """
  Builds a failed-call entry (§8.5). `reason` is one of:
  `:upstream_unavailable | :upstream_error | :timeout |
  :response_too_large | :cap_exhausted`.

  `duration_ms` semantics per §8.5 are the caller's responsibility;
  pass `0` for `:cap_exhausted` and recovery-window
  `:upstream_unavailable` rejections, otherwise the wall-clock
  duration of the operation up to failure.

  Per `Plans/ptc-runner-mcp-payload-reduction.md` §4.1 the entry also
  carries `result_bytes` (bytes received before the failure if any —
  usually `nil`, never counted as useful compression) and `oversize`
  (`true` iff `reason == :response_too_large`; for that path
  `result_bytes` is the exact size only if cheaply known — `nil` is
  acceptable and expected, do **not** parse the detail string to
  recover a number).
  """
  @spec error_entry(String.t(), String.t(), atom(), String.t(), non_neg_integer(), keyword()) ::
          entry()
  def error_entry(server, tool, reason, detail, duration_ms, opts \\ [])
      when is_binary(server) and is_binary(tool) and is_atom(reason) and is_binary(detail) and
             is_integer(duration_ms) and duration_ms >= 0 and is_list(opts) do
    # Per `Plans/http-transport-credentials.md` §7.5.1: scrub the
    # `error` field (and `args_truncated` when added in a later
    # phase) at record-construction time, BEFORE the entry reaches
    # the structured response payload. A failed upstream call's
    # `detail` is the most likely place for a half-leaked secret
    # ("Bearer abcd…" prefix in a transport error message).
    %{
      "server" => server,
      "tool" => tool,
      "status" => "error",
      "duration_ms" => duration_ms,
      "reason" => Atom.to_string(reason),
      "error" => Redactor.scrub(detail),
      "result_bytes" => normalize_result_bytes(Keyword.get(opts, :result_bytes)),
      "oversize" => reason == :response_too_large
    }
  end

  # `result_bytes` is a non-negative integer or `nil` (JSON `null`).
  # Anything else (a stray negative, a non-integer) collapses to `nil`
  # rather than leaking a bogus count into the metrics — §4.1 / §7.
  defp normalize_result_bytes(n) when is_integer(n) and n >= 0, do: n
  defp normalize_result_bytes(_), do: nil

  @doc """
  Builds a compact, LLM-facing overview of a value returned by an upstream
  tool after default MCP unwrapping.
  """
  @spec result_overview(term(), atom()) :: map()
  def result_overview(value, value_kind) when is_atom(value_kind) do
    %{
      "value_kind" => Atom.to_string(value_kind),
      "shape" => shape(value),
      "preview" => preview(value)
    }
  end

  @doc """
  Drains all `{:upstream_call_recorded, ref, entry}` messages from
  the current process's mailbox, returning them in arrival order.

  Pass the worker's unique `ref` so unrelated mailbox traffic and
  any other request's entries (in the unlikely future case of
  process reuse) are left untouched.

  Per §6.4 the drain runs only on normal completion or a caught
  Lisp/runtime error producing an envelope.
  """
  @spec drain(reference()) :: [entry()]
  def drain(ref) when is_reference(ref) do
    drain(ref, [])
  end

  defp drain(ref, acc) do
    receive do
      {:upstream_call_recorded, ^ref, entry} -> drain(ref, [entry | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc """
  Decorates a v1 R22/R23 structured payload with the drained
  `upstream_calls` list (§8.3). Omits the field when the list is
  empty per the spec ("`upstream_calls` MUST be omitted when empty").
  """
  @spec decorate(map(), [entry()]) :: map()
  def decorate(payload, []) when is_map(payload), do: payload

  def decorate(payload, entries) when is_map(payload) and is_list(entries) do
    payload
    |> Map.put("upstream_calls", Enum.map(entries, &Map.delete(&1, "result_overview")))
    |> maybe_put_upstream_results(entries)
  end

  defp maybe_put_result_overview(entry, nil), do: entry

  defp maybe_put_result_overview(entry, overview) when is_map(overview) do
    Map.put(entry, "result_overview", overview)
  end

  defp maybe_put_result_overview(entry, _), do: entry

  defp maybe_put_upstream_results(payload, entries) do
    summaries =
      entries
      |> Enum.map(&compact_result_entry/1)
      |> Enum.reject(&is_nil/1)

    if summaries == [] do
      payload
    else
      Map.put(payload, "upstream_results", summaries)
    end
  end

  defp compact_result_entry(%{"status" => "ok", "result_overview" => overview} = entry)
       when is_map(overview) do
    %{
      "server" => Map.get(entry, "server"),
      "tool" => Map.get(entry, "tool"),
      "status" => "ok"
    }
    |> Map.merge(overview)
  end

  defp compact_result_entry(%{"status" => "error"} = entry) do
    %{
      "server" => Map.get(entry, "server"),
      "tool" => Map.get(entry, "tool"),
      "status" => "error"
    }
    |> maybe_put("reason", Map.get(entry, "reason"))
    |> maybe_put("error", Map.get(entry, "error"))
  end

  defp compact_result_entry(_), do: nil

  defp shape(value) when is_map(value) do
    keys = value |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    "map keys=#{inspect(Enum.take(keys, 8))} count=#{length(keys)}"
  end

  defp shape(value) when is_list(value), do: "list count=#{length(value)}"
  defp shape(value) when is_binary(value), do: "string bytes=#{byte_size(value)}"
  defp shape(value) when is_integer(value), do: "integer"
  defp shape(value) when is_float(value), do: "number"
  defp shape(value) when is_boolean(value), do: "boolean"
  defp shape(nil), do: "nil"
  defp shape(_), do: "unknown"

  defp preview(value) when is_binary(value), do: truncate(Redactor.scrub(value), 240)

  defp preview(value) do
    value
    |> compact_value()
    |> encode_or_inspect()
    |> Redactor.scrub()
    |> truncate(240)
  end

  defp compact_value(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.take(8)
    |> Map.new(fn {key, val} -> {to_string(key), compact_leaf(val)} end)
  end

  defp compact_value(value) when is_list(value) do
    value
    |> Enum.take(5)
    |> Enum.map(&compact_leaf/1)
  end

  defp compact_value(value), do: compact_leaf(value)

  defp compact_leaf(value) when is_binary(value), do: truncate(value, 120)
  defp compact_leaf(value) when is_map(value), do: %{"type" => "map", "keys" => map_keys(value)}
  defp compact_leaf(value) when is_list(value), do: %{"type" => "list", "count" => length(value)}
  defp compact_leaf(value), do: value

  defp map_keys(value) do
    value
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
    |> Enum.take(8)
  end

  defp encode_or_inspect(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value, limit: 20, printable_limit: 200)
    end
  end

  defp truncate(text, max_bytes) when is_binary(text) and byte_size(text) <= max_bytes, do: text

  defp truncate(text, max_bytes) when is_binary(text) do
    truncate_utf8(text, max_bytes) <> "..."
  end

  defp truncate_utf8(_text, max_bytes) when max_bytes <= 0, do: ""

  defp truncate_utf8(text, max_bytes) do
    chunk = binary_part(text, 0, max_bytes)

    if String.valid?(chunk) do
      chunk
    else
      truncate_utf8(text, max_bytes - 1)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
