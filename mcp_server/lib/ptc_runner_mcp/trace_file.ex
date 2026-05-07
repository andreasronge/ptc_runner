defmodule PtcRunnerMcp.TraceFile do
  @moduledoc """
  Trace-file path construction, rotation, and write-failure handling.

  Per `Plans/ptc-runner-mcp-server.md` § 6.10:

    * File names: `<iso8601-utc>-<request_id_hash8>-<status>.jsonl`
    * `<status>` is `ok` (envelope `isError == false`) or `error`.
    * The 8-hex-char hash is `:crypto.hash(:sha256, request_id)`
      truncated to 8 chars (lowercase).
    * Rotation: at write time, if the directory contains more than
      `--trace-max-files` files, evict oldest by mtime FIFO.
    * Disk-pressure: any failure to mkdir, open, or write logs to
      stderr and continues serving without tracing for that call.
  """

  require Logger

  alias PtcRunnerMcp.{Log, TraceConfig}

  @doc """
  Build the trace-file path for a request.

  `request_id` is hashed (so full IDs don't leak into filenames).
  `status` is `:ok | :error`.

  Returns the absolute file path (relative paths are passed through).
  """
  @spec build_path(String.t() | nil, term(), :ok | :error) :: String.t()
  def build_path(trace_dir, request_id, status)
      when is_binary(trace_dir) and status in [:ok, :error] do
    timestamp = iso8601_compact(DateTime.utc_now())
    hash = request_id_hash8(request_id)
    Path.join(trace_dir, "#{timestamp}-#{hash}-#{status}.jsonl")
  end

  @doc """
  8-character lowercase hex SHA-256 of the request_id (or `"00000000"`
  when nil).
  """
  @spec request_id_hash8(term()) :: String.t()
  def request_id_hash8(nil), do: "00000000"

  def request_id_hash8(id) do
    bin = if is_binary(id), do: id, else: to_string(id)

    :sha256
    |> :crypto.hash(bin)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  @doc """
  ISO-8601 UTC timestamp with `:` replaced by `-` for filesystem safety.

  E.g. `"2026-05-07T12-34-56.789Z"`. Sorts lexically by time.
  """
  @spec iso8601_compact(DateTime.t()) :: String.t()
  def iso8601_compact(dt) do
    dt
    |> DateTime.to_iso8601()
    |> String.replace(":", "-")
  end

  @doc """
  Ensure `trace_dir` exists. Returns `:ok` on success; `{:error, reason}`
  on failure (also logs to stderr, never raises).
  """
  @spec ensure_dir(String.t()) :: :ok | {:error, term()}
  def ensure_dir(trace_dir) when is_binary(trace_dir) do
    case File.mkdir_p(trace_dir) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Log.log(:error, "trace_dir_create_failed", %{
          trace_dir: trace_dir,
          reason: inspect(reason)
        })

        err
    end
  end

  @doc """
  Apply FIFO rotation to `trace_dir`: if it contains more than
  `max_files - 1` `.jsonl` files (so adding one more stays at or
  below the cap), delete the oldest by mtime.

  Best-effort: failures to stat or delete are logged but never raise.
  """
  @spec rotate(String.t(), pos_integer()) :: :ok
  def rotate(trace_dir, max_files)
      when is_binary(trace_dir) and is_integer(max_files) and max_files > 0 do
    files = list_trace_files(trace_dir)
    over = length(files) - (max_files - 1)

    if over > 0 do
      files
      |> Enum.sort_by(fn {_path, mtime} -> mtime end)
      |> Enum.take(over)
      |> Enum.each(fn {path, _mtime} -> safe_delete(path) end)
    end

    :ok
  end

  @doc """
  Run `fun.()` inside `PtcRunner.TraceLog.with_trace/2` if tracing is
  configured, then move/rename the resulting trace file to its final
  status-tagged path under `--trace-dir`.

  Returns the function's result (the MCP envelope). Trace failures
  log to stderr and return the envelope unchanged.

  `fun` is invoked exactly once. The wrapper:

    1. Builds a temporary path inside `--trace-dir` (suffix `-pending`).
    2. Wraps `fun` in `with_trace/2` with header opts (trace_kind,
       producer, trace_label, model: nil, query).
    3. After the call, renames the file to its final status-tagged
       name based on the envelope's `isError` flag.
    4. Runs FIFO rotation against the trace dir.
  """
  @spec with_traced_call(term(), String.t(), keyword(), (-> map())) :: map()
  def with_traced_call(request_id, query_redacted, header_opts, fun)
      when is_function(fun, 0) and is_list(header_opts) do
    config = TraceConfig.get()

    case config.trace_dir do
      nil ->
        # Tracing disabled: invoke the function directly. The MCP
        # `[:ptc_runner_mcp, :call, *]` telemetry events still fire
        # — they're useful for any subscriber.
        fun.()

      trace_dir ->
        do_traced_call(
          trace_dir,
          config.trace_max_files,
          request_id,
          query_redacted,
          header_opts,
          fun
        )
    end
  end

  defp do_traced_call(trace_dir, max_files, request_id, query, header_opts, fun) do
    case ensure_dir(trace_dir) do
      :ok ->
        # Pre-rotate so we cap *before* opening the new file (saves
        # one transient overshoot beyond the cap).
        try do
          rotate(trace_dir, max_files)
        rescue
          _ -> :ok
        end

        pending_path = build_pending_path(trace_dir, request_id)

        opts =
          header_opts
          |> Keyword.merge(
            path: pending_path,
            trace_kind: "mcp_call",
            producer: "ptc_runner_mcp",
            trace_label: to_string(request_id || ""),
            model: nil,
            query: query
          )

        run_with_trace(opts, request_id, trace_dir, pending_path, fun)

      {:error, _reason} ->
        # Disk failure on mkdir — fall back to running without tracing.
        # Log already emitted by ensure_dir/1.
        fun.()
    end
  end

  defp run_with_trace(opts, request_id, trace_dir, pending_path, fun) do
    # Split trace setup from fun execution so a raise inside fun
    # cannot trigger a fallback that re-runs fun (which would execute
    # side-effecting work twice). Codex review of 212266d.
    case start_trace_safely(opts, request_id, trace_dir) do
      {:ok, collector} ->
        # Setup OK — run fun inside the active collector. Any raise
        # propagates after we close the collector and rename the file.
        try do
          result = fun.()
          _ = PtcRunner.TraceLog.stop(collector)
          rename_to_final(trace_dir, request_id, pending_path, result)
          result
        catch
          kind, reason ->
            stack = __STACKTRACE__

            try do
              PtcRunner.TraceLog.stop(collector)
            catch
              _, _ -> :ok
            end

            # Best-effort rename to *-error so the failed trace is
            # discoverable; we don't have an envelope to introspect, so
            # tag conservatively.
            rename_pending_to_error(trace_dir, request_id, pending_path)

            :erlang.raise(kind, reason, stack)
        end

      :error ->
        # File-open / setup failure already logged. Fall back to a
        # bare call (one execution).
        fun.()
    end
  end

  defp start_trace_safely(opts, request_id, trace_dir) do
    {:ok, PtcRunner.TraceLog.start(opts) |> elem(1)}
  rescue
    error ->
      Log.log(:error, "trace_open_failed", %{
        request_id: request_id,
        trace_dir: trace_dir,
        reason: Exception.message(error)
      })

      :error
  catch
    kind, reason ->
      Log.log(:error, "trace_open_failed", %{
        request_id: request_id,
        trace_dir: trace_dir,
        kind: inspect(kind),
        reason: inspect(reason)
      })

      :error
  end

  defp rename_pending_to_error(trace_dir, _request_id, pending_path) do
    final = Path.join(trace_dir, "#{Path.basename(pending_path, "-pending.jsonl")}-error.jsonl")
    _ = File.rename(pending_path, final)
    :ok
  rescue
    _ -> :ok
  end

  defp build_pending_path(trace_dir, request_id) do
    timestamp = iso8601_compact(DateTime.utc_now())
    hash = request_id_hash8(request_id)
    Path.join(trace_dir, "#{timestamp}-#{hash}-pending.jsonl")
  end

  defp rename_to_final(trace_dir, request_id, pending_path, envelope) do
    status =
      case envelope do
        %{"isError" => true} -> :error
        _ -> :ok
      end

    final_path = build_path(trace_dir, request_id, status)

    case File.exists?(pending_path) do
      true ->
        case File.rename(pending_path, final_path) do
          :ok ->
            :ok

          {:error, reason} ->
            Log.log(:error, "trace_rename_failed", %{
              request_id: request_id,
              from: pending_path,
              to: final_path,
              reason: inspect(reason)
            })

            :ok
        end

      false ->
        # Pending file never materialized (e.g., fallback path). Nothing
        # to rename.
        :ok
    end
  end

  # ----------------------------------------------------------------
  # File listing helpers
  # ----------------------------------------------------------------

  defp list_trace_files(trace_dir) do
    case File.ls(trace_dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(fn name ->
          path = Path.join(trace_dir, name)
          mtime = file_mtime(path)
          {path, mtime}
        end)
        |> Enum.reject(fn {_p, m} -> is_nil(m) end)

      {:error, _} ->
        []
    end
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  defp safe_delete(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Log.log(:warn, "trace_evict_failed", %{path: path, reason: inspect(reason)})
        :ok
    end
  end
end
