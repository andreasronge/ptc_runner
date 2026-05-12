defmodule PtcRunnerMcp.DebugTool do
  @moduledoc """
  The opt-in `ptc_debug` diagnostics tool.

  See `Plans/ptc-runner-mcp-debug-tool.md` § 6. Mirrors how `ptc_task`
  lives in `PtcRunnerMcp.Agentic`: this module owns the tool entry,
  the input/output schemas, argument validation, and `call/1` which
  dispatches `op` (`stats` | `recent` | `get`) to
  `PtcRunnerMcp.DebugBuffer`, formats `structuredContent`, enriches
  `op=get` from `--trace-dir` when set, and enforces
  `--max-debug-response-bytes`.

  `ptc_debug` is dispatched synchronously by `PtcRunnerMcp.JsonRpc`
  with no concurrency permit, and is never written to the ring buffer.
  All operations are read-only.
  """

  alias PtcRunnerMcp.{
    Credentials.Redactor,
    DebugBuffer,
    DebugConfig,
    Envelope,
    TraceConfig,
    TraceFile
  }

  @tool_name "ptc_debug"

  @description """
  Read-only diagnostics for this MCP server. Inspect recent `tools/call` activity: aggregate stats (success/error rates, latency, error reasons, per-tool and upstream-call breakdown), the most recent calls, or one call's redacted record by `request_id`. Data is a bounded in-memory window since the server last started; payloads are redacted. Use this to investigate whether programs, the aggregator, or agentic tasks are behaving well.\
  """

  @doc false
  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @doc "The `ptc_debug` tool entry returned in `tools/list` (when enabled)."
  @spec tool_entry() :: map()
  def tool_entry do
    %{
      "name" => @tool_name,
      "description" => @description,
      "inputSchema" => input_schema(),
      "outputSchema" => output_schema(),
      "annotations" => %{
        "readOnlyHint" => true,
        "destructiveHint" => false,
        "idempotentHint" => true,
        "openWorldHint" => false
      }
    }
  end

  # Small cushion over the computed frame reserve (e.g. a trailing newline the
  # transport may add) so the advertised cap is a true ceiling.
  @frame_cushion_bytes 8

  @doc """
  Handle a `tools/call name: "ptc_debug"` request.

  `frame_reserve_bytes` is how many bytes the surrounding JSON-RPC
  success frame (`{"jsonrpc":"2.0","id":<id>,"result":...}`) adds around
  the MCP envelope; it counts against `--max-debug-response-bytes` so the
  cap bounds the *whole reply*, including the (client-chosen) `id`.

  When `id` consumes most of `--max-debug-response-bytes` the payload
  budget shrinks toward zero and `run/3` reduces the response to its
  minimal shape. That minimal shape — a handful of required fields plus
  the echoed `id` — is the irreducible floor: JSON-RPC mandates echoing
  `id` verbatim, so an operator who sets `--max-debug-response-bytes`
  below `byte_size(id) + minimal_shape` is asking for the impossible; the
  server minimizes its own contribution, the `id` passthrough is on the
  caller. (`max_frame_bytes` already bounds the incoming `id`.)

  Validation failures produce the standard `args_error` envelope (not
  capped — the message is already bounded by `show/1`, and an oversized
  response there can only be as large as the oversized request).
  """
  @spec call(map(), non_neg_integer()) :: map()
  def call(params, frame_reserve_bytes \\ 0)
      when is_map(params) and is_integer(frame_reserve_bytes) do
    args =
      case Map.get(params, "arguments") do
        m when is_map(m) -> m
        _ -> %{}
      end

    case validate(args) do
      {:ok, op, opts} ->
        cap =
          max(DebugConfig.max_response_bytes() - frame_reserve_bytes - @frame_cushion_bytes, 0)

        run(op, opts, cap)

      {:error, message} ->
        Envelope.render_error(:args_error, message)
    end
  end

  # ----------------------------------------------------------------
  # Validation
  # ----------------------------------------------------------------

  @doc false
  @spec validate(map()) :: {:ok, atom(), keyword()} | {:error, String.t()}
  def validate(args) when is_map(args) do
    with {:ok, op} <- validate_op(args),
         {:ok, limit} <- validate_int(args, "limit", 1, 200),
         {:ok, since} <- validate_int(args, "since_seconds", 1, 86_400),
         {:ok, errors_only} <- validate_bool(args, "errors_only"),
         {:ok, request_id} <- validate_request_id(args, op) do
      opts =
        []
        |> maybe_kw(:limit, limit)
        |> maybe_kw(:since_seconds, since)
        |> maybe_kw(:errors_only, errors_only)
        |> maybe_kw(:request_id, request_id)

      {:ok, op, opts}
    end
  end

  defp validate_op(args) do
    case Map.get(args, "op") do
      "stats" ->
        {:ok, :stats}

      "recent" ->
        {:ok, :recent}

      "get" ->
        {:ok, :get}

      nil ->
        {:error, "argument `op` is required (one of: stats, recent, get)"}

      other ->
        {:error, "argument `op` must be one of stats, recent, get (got: #{show(other)})"}
    end
  end

  # Bound a client-supplied value before echoing it into a validation-error
  # message: a huge `op` / `limit` / `request_id` etc. must not blow the
  # response past `--max-debug-response-bytes` via the `args_error` text. The
  # capped-envelope path only covers successful ops, so validation messages
  # bound themselves here.
  defp show(v), do: v |> inspect(limit: 5, printable_limit: 64) |> String.slice(0, 80)

  defp validate_int(args, key, min, max) do
    case Map.fetch(args, key) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, v} when is_integer(v) and v >= min and v <= max ->
        {:ok, v}

      {:ok, v} when is_integer(v) ->
        {:error, "argument `#{key}` must be between #{min} and #{max} (got: #{show(v)})"}

      {:ok, v} ->
        {:error, "argument `#{key}` must be an integer (got: #{show(v)})"}
    end
  end

  defp validate_bool(args, key) do
    case Map.fetch(args, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, v} when is_boolean(v) -> {:ok, v}
      {:ok, v} -> {:error, "argument `#{key}` must be a boolean (got: #{show(v)})"}
    end
  end

  defp validate_request_id(args, :get) do
    case Map.get(args, "request_id") do
      v when is_binary(v) and v != "" and byte_size(v) <= 256 ->
        {:ok, v}

      v when is_binary(v) and byte_size(v) > 256 ->
        {:error, "argument `request_id` exceeds 256 bytes"}

      _ ->
        {:error, "argument `request_id` is required for op=get"}
    end
  end

  defp validate_request_id(args, _op) do
    case Map.get(args, "request_id") do
      nil -> {:ok, nil}
      v when is_binary(v) and byte_size(v) <= 256 -> {:ok, nil}
      v when is_binary(v) -> {:error, "argument `request_id` exceeds 256 bytes"}
      v -> {:error, "argument `request_id` must be a string (got: #{show(v)})"}
    end
  end

  defp maybe_kw(kw, _key, nil), do: kw
  defp maybe_kw(kw, key, value), do: Keyword.put(kw, key, value)

  # ----------------------------------------------------------------
  # Dispatch
  # ----------------------------------------------------------------

  defp run(:stats, opts, cap) do
    raw = DebugBuffer.stats(opts)

    %{
      "op" => "stats",
      "payload_policy" => payload_policy(),
      "redaction_applied" => true,
      "debug_source" => "ring_buffer",
      "ring_size" => raw.ring_size,
      "ring_count" => raw.ring_count,
      "trace_dir_enabled" => trace_dir_enabled?(),
      "window" => window_json(raw.window),
      "by_tool" => by_tool_json(raw.by_tool),
      "errors" => %{"by_reason" => stringify_keys(raw.errors.by_reason)}
    }
    |> maybe_put("upstream_calls", upstream_calls_json(raw.upstream_calls))
    |> maybe_put("agentic", agentic_json(raw.agentic))
    |> capped_envelope(:stats, cap)
  end

  defp run(:recent, opts, cap) do
    records = DebugBuffer.recent(opts)

    %{
      "op" => "recent",
      "payload_policy" => payload_policy(),
      "redaction_applied" => true,
      "count" => length(records),
      "calls" => Enum.map(records, &recent_call_json/1)
    }
    |> capped_envelope(:recent, cap)
  end

  defp run(:get, opts, cap) do
    request_id = Keyword.fetch!(opts, :request_id)

    base = %{
      "op" => "get",
      "request_id" => request_id,
      "payload_policy" => payload_policy(),
      "redaction_applied" => true
    }

    result =
      case trace_file_lookup(request_id) do
        {:ok, lines} ->
          # Only reached when `--trace-payloads` is currently `full`, so the
          # inlined trace is at `full` fidelity and `payload_policy` (`"full"`)
          # in `base` matches what's returned. `lines` were re-scrubbed for the
          # current credential set in `read_jsonl/1`.
          Map.merge(base, %{"found" => true, "source" => "trace_file", "record" => lines})

        {:too_large, basename} ->
          # The trace file exists but is bigger than the response cap, so we
          # never loaded it (see `read_trace_file/1`). Point the caller at it
          # instead of streaming megabytes through the synchronous path.
          Map.merge(base, %{
            "found" => true,
            "source" => "trace_file",
            "truncated" => true,
            "note" =>
              "trace file #{basename} exceeds --max-debug-response-bytes; read it directly under --trace-dir"
          })

        {:not_inlined, basename} ->
          # A trace file exists, but the current `--trace-payloads` is stricter
          # than `full`: inlining a trace written by an earlier run / at a more
          # permissive policy would leak data the current policy forbids. Prefer
          # this run's ring record (redacted per the *current* policy); else just
          # point at the file.
          note =
            "an on-disk trace exists (#{basename}) under --trace-dir; not inlined " <>
              "under --trace-payloads=#{payload_policy()} — read it there, or " <>
              "restart with --trace-payloads full to inline it here"

          case DebugBuffer.get(request_id) do
            {:ok, rec} ->
              Map.merge(base, %{
                "found" => true,
                "source" => "ring_buffer",
                "record" => full_record_json(rec),
                "note" => note
              })

            :not_found ->
              Map.merge(base, %{"found" => true, "source" => "trace_file", "note" => note})
          end

        :no_trace_file ->
          case DebugBuffer.get(request_id) do
            {:ok, rec} ->
              Map.merge(base, %{
                "found" => true,
                "source" => "ring_buffer",
                # Full redacted ring record — keeps the per-call
                # `upstream_calls` entries (not just the count) so
                # aggregator failures are inspectable via `get`.
                "record" => full_record_json(rec)
              })

            :not_found ->
              Map.put(base, "found", false) |> Map.put("source", "ring_buffer")
          end
      end

    capped_envelope(result, :get, cap)
  end

  # ----------------------------------------------------------------
  # `--trace-dir` enrichment (Phase 2)
  # ----------------------------------------------------------------

  # One bounded directory listing of `<trace_dir>`, filtered to
  # `*-<hash8>-*.jsonl`. On a same-millisecond hash collision, pick the newest
  # by mtime. Outcomes:
  #   * `:no_trace_file` — no `--trace-dir`, no match, or read failure (→ ring).
  #   * `{:not_inlined, basename}` — a match exists but the *current*
  #     `--trace-payloads` is stricter than `full`, so inlining it could leak
  #     data the current policy forbids (the file may be from an earlier run or
  #     a more permissive policy). The caller points at the file instead.
  #   * `{:too_large, basename}` — a match exists but is bigger than the
  #     response cap; not read (a single `File.stat`).
  #   * `{:ok, lines}` — inlined (only when current policy is `full`),
  #     re-scrubbed for the current credential set.
  defp trace_file_lookup(request_id) do
    case TraceConfig.get().trace_dir do
      dir when is_binary(dir) and dir != "" ->
        hash8 = TraceFile.request_id_hash8(request_id)

        case matching_trace_files(dir, hash8) do
          [] ->
            :no_trace_file

          paths ->
            path = newest_by_mtime(paths)

            if TraceConfig.trace_payloads() == :full do
              read_trace_file(path)
            else
              {:not_inlined, Path.basename(path)}
            end
        end

      _ ->
        :no_trace_file
    end
  rescue
    _ -> :no_trace_file
  catch
    _, _ -> :no_trace_file
  end

  # `File.ls/1`, not `Path.wildcard/1`: the operator-supplied `--trace-dir` may
  # contain glob metacharacters (`[` `]` `?` `*`), which `Path.wildcard` would
  # interpret as part of the pattern — missing real files or matching sibling
  # directories. We list the directory literally and match filenames in Elixir.
  # `hash8` is `[0-9a-f]{8}` (or `"00000000"`), so it is safe to interpolate.
  defp matching_trace_files(dir, hash8) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&(String.ends_with?(&1, ".jsonl") and String.contains?(&1, "-#{hash8}-")))
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  # Bound the read. `ptc_debug` runs synchronously in the Stdio process, so a
  # multi-MB trace (e.g. `--trace-payloads full` with a large `context`) must
  # not be slurped into memory and decoded before `capped_envelope/2` can drop
  # it — that would stall all JSON-RPC handling. Stat first: if the raw file is
  # already bigger than the response cap, skip the read and return a pointer.
  # Files at/under the cap are bounded (≤ `--max-debug-response-bytes`, default
  # 64 KiB), so reading them is safe; the envelope cap still applies after.
  defp read_trace_file(path) do
    cap = DebugConfig.max_response_bytes()

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when is_integer(size) and size > cap ->
        {:too_large, Path.basename(path)}

      {:ok, _stat} ->
        read_jsonl(path)

      {:error, _} ->
        :no_trace_file
    end
  end

  defp newest_by_mtime([single]), do: single

  defp newest_by_mtime(paths) do
    paths
    |> Enum.map(fn p ->
      mtime =
        case File.stat(p, time: :posix) do
          {:ok, %File.Stat{mtime: m}} -> m
          _ -> 0
        end

      {p, mtime}
    end)
    |> Enum.max_by(fn {_p, m} -> m end)
    |> elem(0)
  end

  defp read_jsonl(path) do
    case File.read(path) do
      {:ok, body} ->
        lines =
          body
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case Jason.decode(line) do
              {:ok, decoded} -> decoded
              {:error, _} -> %{"_raw" => line}
            end
          end)
          # Defence in depth: the trace was scrubbed for the credentials active
          # when it was written; re-scrub every binary leaf for the current set
          # too (handles the rare case where credentials changed between runs).
          |> Redactor.scrub_deep()

        {:ok, lines}

      {:error, _} ->
        :no_trace_file
    end
  end

  # ----------------------------------------------------------------
  # JSON formatting
  # ----------------------------------------------------------------

  # `recent` view: `upstream_calls` collapsed to a count (full per-call
  # detail is reachable via `get`).
  defp recent_call_json(rec) do
    %{
      "request_id" => rec.request_id,
      "ts" => iso8601(rec.ts),
      "tool" => rec.tool,
      "status" => Atom.to_string(rec.status),
      "reason" => rec.reason,
      "duration_ms" => rec.duration_ms,
      "program" => rec.program,
      "context" => rec.context,
      "result_bytes" => rec.result_bytes,
      "prints_count" => rec.prints_count,
      "signature_present" => rec.signature_present?,
      "protocol_version" => rec.protocol_version,
      "upstream_calls" => length(rec.upstream_calls || [])
    }
    |> maybe_put("agentic", agentic_record_json(rec.agentic))
  end

  # `get` view: the full redacted ring record, including the per-call
  # `upstream_calls` entries (already redacted to `server`/`tool`/
  # `status`/`duration_ms`/`reason` by `DebugRecorder`).
  defp full_record_json(rec) do
    rec
    |> recent_call_json()
    |> Map.put("upstream_calls", List.wrap(rec.upstream_calls))
  end

  defp agentic_record_json(nil), do: nil

  defp agentic_record_json(agentic) when is_map(agentic) do
    %{
      "planner_status" => Atom.to_string(agentic.planner_status),
      "planner_duration_ms" => agentic.planner_duration_ms,
      "planner_rejects" => agentic.planner_rejects,
      "retries" => agentic.retries,
      "program_bytes" => agentic.program_bytes
    }
  end

  defp window_json(%{from: from, to: to, calls: calls}) do
    %{"from" => iso8601(from), "to" => iso8601(to), "calls" => calls}
  end

  defp by_tool_json(by_tool) do
    Map.new(by_tool, fn {tool, m} ->
      {tool,
       %{
         "calls" => m.calls,
         "ok" => m.ok,
         "error" => m.error,
         "error_rate" => m.error_rate,
         "duration_ms" => %{
           "p50" => m.duration_ms.p50,
           "p95" => m.duration_ms.p95,
           "max" => m.duration_ms.max
         }
       }}
    end)
  end

  defp upstream_calls_json(nil), do: nil

  defp upstream_calls_json(m) do
    %{
      "total" => m.total,
      "ok" => m.ok,
      "by_reason" => stringify_keys(m.by_reason),
      "by_server" =>
        Map.new(m.by_server, fn {server, sm} ->
          {server,
           %{"total" => sm.total, "ok" => sm.ok, "by_reason" => stringify_keys(sm.by_reason)}}
        end)
    }
  end

  defp agentic_json(nil), do: nil

  defp agentic_json(m) do
    %{
      "tasks" => m.tasks,
      "planner_calls" => m.planner_calls,
      "planner_errors" => m.planner_errors,
      "planner_rejects" => m.planner_rejects,
      "retries" => m.retries
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ----------------------------------------------------------------
  # Size cap (§ 6.4)
  # ----------------------------------------------------------------

  # Wrap `sc` in the success envelope, enforcing `cap` (already net of the
  # JSON-RPC frame reserve — see `call/2`) against the *fully serialized
  # envelope*, not just `structuredContent`. `Envelope.success/1` duplicates
  # the payload into `content[0].text` (as a JSON-of-JSON string, so quotes /
  # backslashes are escaped a second time), so the only reliable measure is
  # `byte_size(Jason.encode!(envelope))`. If it exceeds `cap`, shrink and
  # re-measure.
  defp capped_envelope(sc, kind, cap) do
    if within_cap?(sc, cap) do
      ok_envelope(sc)
    else
      ok_envelope(shrink(sc, kind, cap))
    end
  end

  defp within_cap?(sc, cap) do
    case Jason.encode(ok_envelope(sc)) do
      {:ok, json} -> byte_size(json) <= cap
      _ -> true
    end
  end

  # `recent`: drop oldest records until it fits, mark truncated.
  defp shrink(%{"calls" => calls} = sc, :recent, cap) when is_list(calls) do
    sc = Map.put(sc, "truncated", true)
    do_shrink_recent(sc, calls, cap)
  end

  # `stats`: drop the heaviest optional sections (by_server first,
  # then per-tool duration detail), mark truncated.
  defp shrink(sc, :stats, cap) do
    sc = Map.put(sc, "truncated", true)

    steps = [
      fn s -> drop_by_server(s) end,
      fn s -> drop_tool_durations(s) end,
      fn s -> Map.drop(s, ["by_tool"]) end,
      fn s -> Map.drop(s, ["upstream_calls"]) end
    ]

    Enum.reduce_while(steps, sc, fn step, acc ->
      acc = step.(acc)
      if within_cap?(acc, cap), do: {:halt, acc}, else: {:cont, acc}
    end)
  end

  # `get`: a found record is too big to inline. Drop the record body,
  # flag truncated, point at `--trace-dir`. A *miss* (`found: false`)
  # is already minimal — there's nothing to trim, so leave it intact
  # rather than rewriting it to a misleading `found: true`.
  defp shrink(%{"op" => "get", "found" => true} = sc, :get, _cap) do
    sc
    |> Map.drop(["record"])
    |> Map.merge(%{
      "found" => true,
      "truncated" => true,
      "note" =>
        "record exceeds --max-debug-response-bytes; set --trace-dir and read the trace file directly"
    })
  end

  defp shrink(%{"op" => "get"} = sc, :get, _cap), do: sc

  defp shrink(sc, _kind, _cap), do: Map.put(sc, "truncated", true)

  defp do_shrink_recent(sc, calls, cap) do
    cond do
      calls == [] ->
        sc |> Map.put("calls", []) |> Map.put("count", 0)

      within_cap?(Map.merge(sc, %{"calls" => calls, "count" => length(calls)}), cap) ->
        Map.merge(sc, %{"calls" => calls, "count" => length(calls)})

      true ->
        # Drop the oldest record (`recent` is newest-first → drop last).
        do_shrink_recent(sc, Enum.drop(calls, -1), cap)
    end
  end

  defp drop_by_server(%{"upstream_calls" => uc} = sc) when is_map(uc) do
    Map.put(sc, "upstream_calls", Map.drop(uc, ["by_server"]))
  end

  defp drop_by_server(sc), do: sc

  defp drop_tool_durations(%{"by_tool" => by_tool} = sc) when is_map(by_tool) do
    Map.put(
      sc,
      "by_tool",
      Map.new(by_tool, fn {tool, m} -> {tool, Map.drop(m, ["duration_ms"])} end)
    )
  end

  defp drop_tool_durations(sc), do: sc

  # ----------------------------------------------------------------
  # Misc helpers
  # ----------------------------------------------------------------

  defp ok_envelope(sc), do: Envelope.success(sc)

  defp payload_policy do
    case TraceConfig.trace_payloads() do
      :none -> "none"
      :full -> "full"
      _ -> "summary"
    end
  end

  defp trace_dir_enabled? do
    case TraceConfig.get().trace_dir do
      dir when is_binary(dir) and dir != "" -> true
      _ -> false
    end
  end

  # ----------------------------------------------------------------
  # Schemas
  # ----------------------------------------------------------------

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "op" => %{"type" => "string", "enum" => ["stats", "recent", "get"]},
        "limit" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 200,
          "description" => "recent: max records to return (default 20)"
        },
        "since_seconds" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 86_400,
          "description" => "stats/recent: only consider calls newer than this"
        },
        "errors_only" => %{
          "type" => "boolean",
          "description" => "stats/recent: restrict to status == error"
        },
        "request_id" => %{
          "type" => "string",
          "maxLength" => 256,
          "description" => "get: the call to fetch (required for op=get)"
        }
      },
      "required" => ["op"],
      "additionalProperties" => false
    }
  end

  defp output_schema do
    common = %{
      "op" => %{"type" => "string"},
      "payload_policy" => %{"type" => "string", "enum" => ["none", "summary", "full"]},
      "redaction_applied" => %{"const" => true}
    }

    %{
      "type" => "object",
      "oneOf" => [
        %{
          "type" => "object",
          "required" => [
            "op",
            "payload_policy",
            "redaction_applied",
            "debug_source",
            "ring_size",
            "ring_count",
            "window"
          ],
          "properties" =>
            Map.merge(common, %{
              "debug_source" => %{"const" => "ring_buffer"},
              "ring_size" => %{"type" => "integer"},
              "ring_count" => %{"type" => "integer"},
              "trace_dir_enabled" => %{"type" => "boolean"},
              "window" => %{"type" => "object"},
              "by_tool" => %{"type" => "object"},
              "errors" => %{"type" => "object"},
              "upstream_calls" => %{"type" => ["object", "null"]},
              "agentic" => %{"type" => ["object", "null"]},
              "truncated" => %{"type" => "boolean"}
            })
        },
        %{
          "type" => "object",
          "required" => ["op", "payload_policy", "redaction_applied", "count", "calls"],
          "properties" =>
            Map.merge(common, %{
              "count" => %{"type" => "integer"},
              "calls" => %{"type" => "array"},
              "truncated" => %{"type" => "boolean"}
            })
        },
        %{
          "type" => "object",
          "required" => ["op", "payload_policy", "redaction_applied", "request_id", "found"],
          "properties" =>
            Map.merge(common, %{
              "request_id" => %{"type" => "string"},
              "found" => %{"type" => "boolean"},
              "source" => %{"type" => "string", "enum" => ["ring_buffer", "trace_file"]},
              "record" => %{},
              "truncated" => %{"type" => "boolean"},
              "note" => %{"type" => "string"}
            })
        },
        # Validation failures (and a few transport-level errors) return the
        # standard R23 error payload, not one of the three success shapes —
        # advertise it so strict clients validating `structuredContent`
        # against `outputSchema` don't reject the server's own error replies
        # (cf. the same fix in `PtcRunnerMcp.Tools`).
        %{
          "type" => "object",
          "required" => ["status", "reason", "message", "feedback"],
          "properties" => %{
            "status" => %{"const" => "error"},
            "reason" => %{
              "type" => "string",
              "enum" => ["args_error", "unknown_tool", "shutting_down"]
            },
            "message" => %{"type" => "string"},
            "feedback" => %{"type" => "string"},
            "result" => %{"type" => "string"}
          }
        }
      ]
    }
  end
end
