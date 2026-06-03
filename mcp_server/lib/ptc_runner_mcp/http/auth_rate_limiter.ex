defmodule PtcRunnerMcp.Http.AuthRateLimiter do
  @moduledoc """
  Per-source rate limiter for failed `/mcp` bearer authentication
  (`OPLANE_REQ-00080322`).

  A `GenServer` owns a named, public ETS table and runs a periodic
  cleanup sweep. The hot path (`check/2`, `record_failure/2`,
  `reset/2`) touches ETS directly — atomic `:ets.update_counter/3` for
  failure increments, plain `:ets.lookup/2` for block checks — so auth
  is never serialized through a single process.

  Each source (keyed by `conn.remote_ip`) gets one row:

      {source_key, failure_count, window_started_mono, blocked_until_mono}

  Window and block expiry are evaluated lazily on read; the periodic
  sweep evicts rows whose window has fully expired and that are not
  currently blocked, bounding table growth under many distinct sources.

  Graceful degradation: when the limiter is disabled (no configured
  token or `http_auth_rate_limit: false`) or the table is absent, every
  function is a no-op that fails open — auth proceeds normally.
  """

  use GenServer

  alias PtcRunnerMcp.Http.Telemetry
  alias PtcRunnerMcp.Log

  @table __MODULE__.Table
  @cleanup_interval_ms 60_000

  @type source_key :: :inet.ip_address() | term()
  @type config :: %{optional(atom()) => term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Hot-path block check. Returns `:ok` when the source may attempt auth,
  or `{:blocked, retry_after_s}` when it is currently blocked. Fails
  open (returns `:ok`) when disabled or the table is absent.
  """
  @spec check(source_key(), config()) :: :ok | {:blocked, pos_integer()}
  def check(source_key, cfg) do
    if enabled?(cfg) do
      now = System.monotonic_time(:millisecond)

      case :ets.lookup(@table, source_key) do
        [{^source_key, _count, _window, blocked_until}] when blocked_until > now ->
          {:blocked, retry_after_s(blocked_until - now)}

        _ ->
          :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Record one failed bearer auth for `source_key`. Increments the
  per-source counter (atomically) and arms a block once it reaches
  `http_auth_rate_limit_max_failures` within the window. No-op when
  disabled or the table is absent.
  """
  @spec record_failure(source_key(), config()) :: :ok
  def record_failure(source_key, cfg) do
    if enabled?(cfg) do
      do_record_failure(source_key, cfg)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Reset a source's failure state after a successful auth. No-op when
  disabled or the table is absent.
  """
  @spec reset(source_key(), config()) :: :ok
  def reset(source_key, cfg) do
    if enabled?(cfg), do: :ets.delete(@table, source_key)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp do_record_failure(source_key, cfg) do
    now = System.monotonic_time(:millisecond)
    window_ms = window_ms(cfg)

    # `blocked_until` is initialized to `now` (== "not blocked"); using a
    # fixed sentinel like 0 is unsafe because monotonic time can be
    # negative, so 0 would read as "blocked far into the future".
    :ets.insert_new(@table, {source_key, 0, now, now})

    case :ets.lookup(@table, source_key) do
      [{^source_key, _count, _window, blocked_until}] when blocked_until > now ->
        :ok

      [{^source_key, _count, window_started, _blocked_until}]
      when now - window_started >= window_ms ->
        # Window elapsed: start a fresh window at this failure.
        :ets.insert(@table, {source_key, 1, now, now})
        :ok

      _ ->
        count = :ets.update_counter(@table, source_key, {2, 1})

        if count >= max_failures(cfg) do
          arm_block(source_key, cfg, now)
        end

        :ok
    end
  end

  defp arm_block(source_key, cfg, now) do
    block_ms = block_ms(cfg)
    :ets.update_element(@table, source_key, {4, now + block_ms})

    meta = %{instance: Map.get(cfg, :instance_label), source: source_label(source_key)}
    Telemetry.emit([:auth, :rate_limited], %{count: 1, block_ms: block_ms}, meta)
    Log.log(:warn, "http_auth_rate_limited", Map.put(meta, :block_ms, block_ms))
  end

  @impl GenServer
  def init(opts) do
    config = Keyword.fetch!(opts, :config)

    table =
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    ref = Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:ok, %{table: table, config: config, cleanup_ref: ref}}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    threshold = now - window_ms(state.config)

    # Evict rows that are not currently blocked and whose window has
    # fully expired: blocked_until <= now AND window_started < threshold.
    match_spec = [
      {{:_, :_, :"$1", :"$2"}, [{:andalso, {:"=<", :"$2", now}, {:<, :"$1", threshold}}], [true]}
    ]

    _ = :ets.select_delete(state.table, match_spec)

    ref = Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:noreply, %{state | cleanup_ref: ref}}
  end

  defp enabled?(cfg) do
    Map.get(cfg, :auth_rate_limit, false) and
      is_binary(Map.get(cfg, :auth_token)) and
      :ets.whereis(@table) != :undefined
  end

  defp window_ms(cfg), do: Map.get(cfg, :auth_rate_limit_window_ms, 60_000)
  defp max_failures(cfg), do: Map.get(cfg, :auth_rate_limit_max_failures, 5)
  defp block_ms(cfg), do: Map.get(cfg, :auth_rate_limit_block_ms, 60_000)

  defp retry_after_s(remaining_ms) when remaining_ms > 0,
    do: max(1, div(remaining_ms + 999, 1000))

  defp retry_after_s(_remaining_ms), do: 1

  defp source_label(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> inspect(ip)
      charlist -> List.to_string(charlist)
    end
  end

  defp source_label(other), do: inspect(other)
end
