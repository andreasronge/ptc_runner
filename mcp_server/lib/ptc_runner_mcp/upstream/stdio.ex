defmodule PtcRunnerMcp.Upstream.Stdio do
  @moduledoc """
  Subprocess-backed implementation of `PtcRunnerMcp.Upstream` for
  Phase 1b.

  Per `Plans/ptc-runner-mcp-aggregator.md` §6.3 / §12.3.2: each
  configured upstream is a child MCP server (e.g. an `npx` package)
  driven via JSON-RPC over stdio. The handshake order is normative:

      initialize
      notifications/initialized   (notification — no reply expected)
      tools/list

  Some upstreams reject `tools/call` until they observe
  `notifications/initialized`, so the third step MUST come AFTER
  both the `initialize` reply and the notification have been sent.

  ## Framing

  Line-delimited JSON (NDJSON): one JSON-RPC message per line,
  terminated by `\\n`. `:max_response_bytes` is enforced
  pre-decode by limiting how many bytes we'll accumulate before
  the next newline; once the budget is exhausted we discard the
  line, complete the in-flight call with `:response_too_large`,
  and resynchronize at the next newline.

  ## Lifecycle

  Owned by the calling `Upstream.Connection` per §4.4. `start_link/2`
  blocks until the handshake (`initialize` → `notifications/initialized`
  → `tools/list`) completes successfully or fails with
  `{:upstream_unavailable, detail}`. `stop/1` is idempotent: the
  Port is closed via stdin EOF (the spec's §4.3 graceful shutdown
  path) and the GenServer terminates `:normal`.

  Subprocess crash mid-call is detected via the Port's
  `{:EXIT_STATUS, _}` / `{:exit_status, _}` message; in-flight
  callers receive `{:error, :upstream_unavailable, _}` and the
  GenServer stops, which the owning Connection observes as `:DOWN`
  and translates into a backoff-armed transition to `:not_started`.

  ## Config

      %{
        command:           String.t(),         # required
        args:              [String.t()],       # default []
        env:               %{String.t() => String.t()}, # default %{}
        cd:                String.t() | nil,
        handshake_timeout_ms: pos_integer(),   # default 10_000
      }

  Per §5.2 the JSON config carries `command/args/env`; the loader in
  `PtcRunnerMcp.Application` resolves `${VAR}` placeholders before
  passing the map here.
  """

  @behaviour PtcRunnerMcp.Upstream

  use GenServer

  alias PtcRunnerMcp.Upstream

  @registry __MODULE__.Names

  @default_handshake_timeout_ms 10_000

  # ----------------------------------------------------------------
  # Behaviour callbacks
  # ----------------------------------------------------------------

  @impl Upstream
  @spec start_link(Upstream.server_name(), map()) :: GenServer.on_start()
  def start_link(name, config) when is_binary(name) and is_map(config) do
    # We briefly trap exits around the inner `GenServer.start_link/3`
    # so that an `init/1` returning `{:stop, _}` does NOT propagate
    # as an EXIT signal that would crash the caller (typical case:
    # the owning Connection has not yet enabled trap_exit at the
    # moment its `init/1` is calling our `start_link/2`). Restoring
    # `parent_trap` afterwards leaves the caller's trap-exit setting
    # unchanged.
    #
    # We do NOT drain a follow-up EXIT message here: codex review
    # of `46b4466` [P2] #3 verified that `:proc_lib.start_link` (the
    # primitive `GenServer.start_link/3` is built on) already
    # internalizes the link-signal on init failure under trap_exit,
    # so the caller's mailbox is clean by the time `start_link/3`
    # returns. The previous catch-all `{:EXIT, _, _}` drain instead
    # silently consumed UNRELATED exit messages — including a
    # supervisor's shutdown signal sent to the Connection
    # mid-handshake, which left graceful shutdown waiting on the
    # supervisor's `:kill` timeout.
    parent_trap = Process.flag(:trap_exit, true)

    try do
      GenServer.start_link(__MODULE__, {name, config}, name: via(name))
    after
      Process.flag(:trap_exit, parent_trap)
    end
  end

  @impl Upstream
  @spec list_tools(Upstream.server_name()) ::
          {:ok, [Upstream.tool_schema()]} | {:error, Upstream.reason(), String.t()}
  def list_tools(name) when is_binary(name) do
    case whereis(name) do
      nil ->
        {:error, :upstream_unavailable, "stdio upstream '#{name}' is not running"}

      pid ->
        GenServer.call(pid, :list_tools)
    end
  end

  @impl Upstream
  @spec call(Upstream.server_name(), Upstream.tool_name(), map(), Upstream.call_opts()) ::
          {:ok, Upstream.json()} | {:error, Upstream.reason(), String.t()}
  def call(name, tool_name, args, opts)
      when is_binary(name) and is_binary(tool_name) and is_map(args) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    max_bytes = Keyword.get(opts, :max_response_bytes, 2 * 1024 * 1024)

    case whereis(name) do
      nil ->
        {:error, :upstream_unavailable, "stdio upstream '#{name}' is not running"}

      pid ->
        # The GenServer.call timeout is a *transport* deadline; we
        # add a small buffer over the application timeout so the
        # subprocess gets a chance to report `:timeout` before the
        # transport gives up. If the GenServer call itself times
        # out, the caller gets `:upstream_error` rather than
        # `:timeout` (which would be misleading).
        try do
          GenServer.call(
            pid,
            {:call, tool_name, args, timeout, max_bytes},
            timeout + 1_000
          )
        catch
          :exit, {:timeout, _} ->
            {:error, :upstream_error, "stdio transport timeout"}

          :exit, {:noproc, _} ->
            {:error, :upstream_unavailable, "stdio upstream '#{name}' exited"}

          :exit, reason ->
            {:error, :upstream_error, "stdio call exited: #{inspect(reason, limit: 50)}"}
        end
    end
  rescue
    e -> {:error, :upstream_error, "stdio call raised: #{Exception.message(e)}"}
  end

  @impl Upstream
  @spec stop(Upstream.server_name()) :: :ok
  def stop(name) when is_binary(name) do
    case whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5_000)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  # ----------------------------------------------------------------
  # Public helper for the supervision tree
  # ----------------------------------------------------------------

  @doc false
  @spec child_spec_for_registry() :: {module(), keyword()}
  def child_spec_for_registry do
    {Registry, keys: :unique, name: @registry}
  end

  # ----------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------

  @impl GenServer
  def init({name, config}) do
    Process.flag(:trap_exit, true)

    # Snapshot the parent pid (the owning Connection in production,
    # or the test caller in standalone setups). Codex review of
    # `fe72ff6` flagged that without this, a Connection that dies
    # before its `terminate/2` runs `Stdio.stop/1` would leave the
    # Stdio GenServer running, the subprocess leaked, and the
    # `Stdio.Names` registration occupied — future `start_link/2`
    # for the same upstream returns `{:already_started, _}`.
    parent_pid =
      case Process.info(self(), :links) do
        {:links, [pid | _]} when is_pid(pid) -> pid
        _ -> nil
      end

    case open_port(config) do
      {:ok, port} ->
        state = %{
          name: name,
          port: port,
          parent_pid: parent_pid,
          buffer: "",
          discarding_until_newline?: false,
          next_id: 1,
          pending: %{},
          tools: [],
          handshake_done?: false,
          max_response_bytes: nil
        }

        timeout = Map.get(config, :handshake_timeout_ms, @default_handshake_timeout_ms)

        case do_handshake(state, timeout) do
          {:ok, new_state} ->
            {:ok, new_state}

          {:error, detail, _new_state} ->
            # Tear down the port so the subprocess does not leak.
            close_port(port)
            {:stop, {:upstream_unavailable, detail}}
        end

      {:error, detail} ->
        {:stop, {:upstream_unavailable, detail}}
    end
  end

  @impl GenServer
  def handle_call(:list_tools, _from, state) do
    {:reply, {:ok, state.tools}, state}
  end

  def handle_call({:call, tool_name, args, timeout_ms, max_bytes}, from, state) do
    id = state.next_id
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => tool_name, "arguments" => args}
    }

    case send_frame(state.port, request) do
      :ok ->
        # Schedule a per-call timeout. The timer is cancelled when
        # the response arrives.
        timer_ref = Process.send_after(self(), {:call_timeout, id}, timeout_ms)

        new_pending =
          Map.put(state.pending, id, %{
            from: from,
            timer: timer_ref,
            max_bytes: max_bytes,
            deadline: deadline
          })

        new_state = %{
          state
          | next_id: id + 1,
            pending: new_pending,
            max_response_bytes: largest_pending_max_bytes(new_pending)
        }

        {:noreply, new_state}

      {:error, reason} ->
        {:reply, {:error, :upstream_unavailable, "stdio write failed: #{inspect(reason)}"}, state}
    end
  end

  @impl GenServer
  def handle_info({port, {:data, chunk}}, %{port: port} = state) when is_binary(chunk) do
    new_state = consume_chunk(state, chunk)
    {:noreply, new_state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # Subprocess exited. Reply to all in-flight callers with
    # `:upstream_unavailable`, then stop the GenServer with a
    # status-derived reason — exit 0 is `:normal`, anything else
    # is a crash. The owning Connection's `:DOWN` handler
    # classifies the reason via `abnormal_exit?/1`; for non-zero
    # exits this arms the recovery-backoff window per §4.3 third
    # bullet. Codex review of `3c2754d` flagged that we previously
    # always stopped with `:normal`, so a real upstream that
    # crashed with status 1 bypassed backoff entirely.
    reason =
      case status do
        0 -> :normal
        n -> {:upstream_exited, n}
      end

    fail_all_pending(state, :upstream_unavailable, "subprocess exited (status=#{status})")
    {:stop, reason, %{state | port: nil}}
  end

  def handle_info({:call_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {entry, rest} ->
        GenServer.reply(entry.from, {:error, :timeout, "stdio call timeout (id=#{id})"})

        {:noreply, %{state | pending: rest, max_response_bytes: largest_pending_max_bytes(rest)}}
    end
  end

  def handle_info({:EXIT, pid, reason}, %{parent_pid: parent} = state)
      when is_pid(pid) and pid == parent do
    # Parent (owning `Upstream.Connection` in production; test caller
    # in standalone fallback) is shutting us down via a link signal.
    # Stop cleanly so `terminate/2` closes the Port (stdin EOF) and
    # frees the `Stdio.Names` registration. Codex review of
    # `fe72ff6` flagged that without this, a Connection killed
    # before its `terminate/2` could run `Stdio.stop/1` would leave
    # us running, the subprocess leaked, and future
    # `Stdio.start_link/2` for the same name would hit
    # `{:already_started, _}`.
    {:stop, reason, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    # Trap-exit also catches the Port's exit (we re-raise the
    # subprocess death as `{:stop, {:upstream_exited, n}, state}`
    # via the dedicated `{:exit_status, _}` clause above) plus any
    # other linked process. The Port's runtime death is handled
    # there; this clause is the fall-through.
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{port: port} = state) when is_port(port) do
    fail_all_pending(state, :upstream_unavailable, "stdio shutdown")
    close_port(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ----------------------------------------------------------------
  # Handshake
  # ----------------------------------------------------------------

  defp do_handshake(state, timeout_ms) do
    # 1. initialize
    init_id = state.next_id
    state = %{state | next_id: init_id + 1}

    init_req = %{
      "jsonrpc" => "2.0",
      "id" => init_id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{},
        "clientInfo" => %{
          "name" => "ptc-runner-mcp",
          "version" => "0.1.0"
        }
      }
    }

    with :ok <- send_frame(state.port, init_req),
         {:ok, _init_result, state} <-
           await_response(state, init_id, timeout_ms),
         :ok <-
           send_frame(state.port, %{
             "jsonrpc" => "2.0",
             "method" => "notifications/initialized"
           }) do
      list_id = state.next_id
      state = %{state | next_id: list_id + 1}

      list_req = %{
        "jsonrpc" => "2.0",
        "id" => list_id,
        "method" => "tools/list"
      }

      with :ok <- send_frame(state.port, list_req),
           {:ok, list_result, state} <- await_response(state, list_id, timeout_ms) do
        tools = extract_tools(list_result)
        {:ok, %{state | tools: tools, handshake_done?: true}}
      else
        {:error, detail, new_state} -> {:error, detail, new_state}
      end
    else
      {:error, detail, new_state} -> {:error, detail, new_state}
      {:error, reason} -> {:error, "handshake write failed: #{inspect(reason)}", state}
    end
  end

  # Synchronous response wait used during handshake. We CANNOT use
  # GenServer.call here because we ARE the GenServer's init/1 — the
  # mailbox is ours to drain directly. We accumulate Port data into
  # the buffer until a complete JSON-RPC frame correlates back to
  # `id`.
  defp await_response(state, id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case wait_for_id(state, id, deadline) do
      {:ok, value, new_state} -> {:ok, value, new_state}
      {:error, detail, new_state} -> {:error, detail, new_state}
    end
  end

  defp wait_for_id(state, id, deadline) do
    now = System.monotonic_time(:millisecond)
    remaining = deadline - now

    if remaining <= 0 do
      {:error, "handshake timeout waiting for id=#{id}", state}
    else
      port = state.port

      receive do
        {^port, {:data, chunk}} when is_binary(chunk) ->
          new_state = %{state | buffer: state.buffer <> chunk}

          case extract_id_from_buffer(new_state, id) do
            {:found, value, leftover_state} ->
              {:ok, value, leftover_state}

            {:error, detail, leftover_state} ->
              {:error, detail, leftover_state}

            :continue ->
              wait_for_id(new_state, id, deadline)
          end

        {^port, {:exit_status, status}} ->
          {:error, "subprocess exited during handshake (status=#{status})", %{state | port: nil}}
      after
        remaining ->
          {:error, "handshake timeout waiting for id=#{id}", state}
      end
    end
  end

  # During handshake, scan the buffer for any complete JSON-RPC frame.
  # If it's the response we want (`id`-matching), return its `result`.
  # If it's a JSON-RPC error for that id, return `{:error, ...}`. Any
  # OTHER complete frame on the buffer (e.g. an unsolicited
  # notification) is silently discarded.
  defp extract_id_from_buffer(state, id) do
    case extract_one_line(state.buffer) do
      :more ->
        :continue

      {:line, line, rest} ->
        new_state = %{state | buffer: rest}

        case Jason.decode(line) do
          {:ok, %{"id" => ^id, "result" => result}} ->
            {:found, result, new_state}

          {:ok, %{"id" => ^id, "error" => error}} ->
            {:error, "upstream initialize error: #{format_jsonrpc_error(error)}", new_state}

          {:ok, _other} ->
            extract_id_from_buffer(new_state, id)

          {:error, _decode_error} ->
            # Discard malformed line; continue scanning.
            extract_id_from_buffer(new_state, id)
        end
    end
  end

  defp extract_tools(%{"tools" => tools}) when is_list(tools) do
    Enum.map(tools, fn t ->
      base = %{
        name: Map.get(t, "name") || "",
        input_schema: Map.get(t, "inputSchema") || Map.get(t, "input_schema") || %{}
      }

      base
      |> maybe_put_description(Map.get(t, "description"))
      |> maybe_put_output_schema(Map.get(t, "outputSchema") || Map.get(t, "output_schema"))
      |> maybe_put_map(:annotations, Map.get(t, "annotations"))
    end)
  end

  defp extract_tools(_), do: []

  defp maybe_put_description(tool, nil), do: tool
  defp maybe_put_description(tool, ""), do: tool

  defp maybe_put_description(tool, description) when is_binary(description),
    do: Map.put(tool, :description, description)

  defp maybe_put_description(tool, _description), do: tool

  defp maybe_put_output_schema(tool, nil), do: tool

  defp maybe_put_output_schema(tool, value) when is_map(value),
    do: Map.put(tool, :output_schema, value)

  defp maybe_put_output_schema(tool, _value), do: tool

  defp maybe_put_map(tool, _key, value) when value in [nil, %{}], do: tool
  defp maybe_put_map(tool, key, value) when is_map(value), do: Map.put(tool, key, value)
  defp maybe_put_map(tool, _key, _value), do: tool

  defp format_jsonrpc_error(%{"message" => msg}) when is_binary(msg), do: msg
  defp format_jsonrpc_error(other), do: inspect(other, limit: 50)

  # ----------------------------------------------------------------
  # Streaming consumption (post-handshake)
  # ----------------------------------------------------------------
  #
  # Two phases:
  #
  #   1. Normal accumulation: append the chunk to `:buffer` and
  #      drain complete `\n`-terminated lines. If the buffer grows
  #      past the cap before a newline is seen, fail the oldest
  #      pending call with `:response_too_large` and ENTER
  #      discard-mode for the rest of the oversized line.
  #
  #   2. Discard-mode (`:discarding_until_newline?` true): the
  #      remainder of the oversized line is still arriving across
  #      subsequent Port chunks. Codex review of `fe72ff6` flagged
  #      that the previous implementation cleared the flag at the
  #      end of `fail_oldest_pending_too_large/2` and accumulated
  #      the next chunk as if it were a fresh frame, re-tripping
  #      the cap on the trailing bytes and failing an UNRELATED
  #      pending call. The fix: every chunk that arrives in
  #      discard-mode is sliced at the next `\n` BEFORE it touches
  #      the buffer; once we see the newline we resume normal
  #      accumulation with whatever followed it.

  defp consume_chunk(%{discarding_until_newline?: true} = state, chunk) do
    case :binary.match(chunk, "\n") do
      :nomatch ->
        # Whole chunk is still part of the oversized line. Discard
        # in full; remain in discard-mode.
        state

      {pos, 1} ->
        <<_discarded::binary-size(^pos), _newline::binary-size(1), rest::binary>> = chunk
        # Found the terminating newline of the oversized line.
        # Resume normal accumulation with whatever followed it.
        state = %{state | discarding_until_newline?: false, buffer: ""}
        consume_chunk(state, rest)
    end
  end

  defp consume_chunk(state, chunk) do
    new_buffer = state.buffer <> chunk
    state = %{state | buffer: new_buffer}
    drain_buffer(state)
  end

  defp drain_buffer(state) do
    # Pre-decode size enforcement: if no newline exists in the
    # buffer AND the buffer exceeds the largest in-flight call's
    # `:max_response_bytes`, drop it and fail the corresponding
    # call(s) with `:response_too_large`. The wire format (NDJSON)
    # makes this a simple linear scan.
    case extract_one_line(state.buffer) do
      :more ->
        maybe_overflow(state)

      {:line, line, rest} ->
        state = %{state | buffer: rest}
        state = enforce_line_cap_and_process(state, line)
        drain_buffer(state)
    end
  end

  # Pre-decode size enforcement for lines that arrive newline-
  # complete in a single Port chunk. Codex review of `46b4466` [P2] #1
  # flagged that the previous code only checked the cap when no
  # newline existed (the "split across chunks" path) — a chunk
  # carrying `<oversized line>\n` would skip the cap check, hand
  # the full payload to `Jason.decode!`, and only enforce the post-
  # decode size check (which doesn't help against a malicious /
  # malformed multi-megabyte line that crashes the decoder).
  #
  # The cap is enforced HERE, before any decode work, by inspecting
  # the framed line's `byte_size`.
  defp enforce_line_cap_and_process(state, line) do
    cap = state.max_response_bytes

    if is_integer(cap) and byte_size(line) > cap do
      fail_oldest_for_oversized_line(state, byte_size(line), cap)
    else
      process_line(state, line)
    end
  end

  defp fail_oldest_for_oversized_line(state, line_size, cap) do
    case oldest_pending(state.pending) do
      nil ->
        # No in-flight call to attribute to — drop the line silently
        # and resume parsing.
        state

      {id, entry} ->
        cancel_timer(entry.timer)

        GenServer.reply(
          entry.from,
          {:error, :response_too_large,
           "stdio response #{line_size} bytes exceeds max_response_bytes (#{cap}) (pre-decode)"}
        )

        new_pending = Map.delete(state.pending, id)

        %{
          state
          | pending: new_pending,
            max_response_bytes: largest_pending_max_bytes(new_pending)
        }
    end
  end

  defp maybe_overflow(state) do
    cap = state.max_response_bytes

    if is_integer(cap) and byte_size(state.buffer) > cap do
      # We exceeded the cap before seeing a newline. Fail the
      # oldest in-flight call with `:response_too_large` and
      # arm the discard-mode flag so the trailing bytes (still
      # arriving across subsequent Port chunks) are dropped at
      # the source instead of re-accumulating.
      fail_oldest_pending_too_large(state, cap)
    else
      state
    end
  end

  defp fail_oldest_pending_too_large(state, cap) do
    # The bytes on the buffer are not yet attributed to any specific
    # JSON-RPC id (we couldn't parse). The conservative behavior:
    # fail the oldest in-flight call (smallest id) with
    # `:response_too_large` so the LLM sees a deterministic outcome.
    state =
      case oldest_pending(state.pending) do
        nil ->
          state

        {id, entry} ->
          cancel_timer(entry.timer)

          GenServer.reply(
            entry.from,
            {:error, :response_too_large,
             "stdio response exceeded max_response_bytes (#{cap}) before newline"}
          )

          new_pending = Map.delete(state.pending, id)

          %{
            state
            | pending: new_pending,
              max_response_bytes: largest_pending_max_bytes(new_pending)
          }
      end

    # The buffer holds the leading portion of the oversized line
    # (the bit that arrived in this chunk). The trailing portion
    # is still in transit. Decide based on whether THIS buffer
    # already contains the terminating newline:
    #
    #   * newline present → consume up-to-and-including it; resume
    #     normal accumulation on the rest. Discard-mode stays off.
    #   * no newline      → drop the buffer in full and arm
    #     discard-mode; subsequent chunks will be sliced before
    #     they touch the buffer.
    case :binary.match(state.buffer, "\n") do
      :nomatch ->
        %{state | buffer: "", discarding_until_newline?: true}

      {pos, 1} ->
        <<_::binary-size(^pos), _newline::binary-size(1), rest::binary>> = state.buffer
        %{state | buffer: rest, discarding_until_newline?: false}
    end
  end

  defp process_line(state, line) do
    case Jason.decode(line) do
      {:ok, %{"id" => id} = frame} when is_integer(id) ->
        handle_response(state, id, frame)

      {:ok, _notification_or_request} ->
        # Server-side notifications / requests we don't act on.
        state

      {:error, _decode_error} ->
        # Drop malformed line.
        state
    end
  end

  defp handle_response(state, id, frame) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        # Late response after timeout / cancellation. Drop.
        state

      {entry, rest_pending} ->
        cancel_timer(entry.timer)

        # Per-call size cap also enforced post-decode for the
        # complete encoded response, defending against frames that
        # squeak under the buffer-watermark check (e.g. exactly
        # newline-terminated at the cap).
        encoded_size = byte_size(Jason.encode!(frame))

        reply =
          cond do
            encoded_size > entry.max_bytes ->
              {:error, :response_too_large,
               "stdio response #{encoded_size} bytes exceeds max_response_bytes (#{entry.max_bytes})"}

            Map.has_key?(frame, "error") ->
              {:error, :upstream_error, format_jsonrpc_error(frame["error"])}

            true ->
              {:ok, extract_call_result(frame["result"])}
          end

        GenServer.reply(entry.from, reply)

        %{
          state
          | pending: rest_pending,
            max_response_bytes: largest_pending_max_bytes(rest_pending)
        }
    end
  end

  # MCP `tools/call` returns a `result` map with `content` /
  # `structuredContent` / `isError`. The behaviour contract returns
  # the JSON value the upstream considered the answer; we surface
  # the FULL result map so the program can pluck whichever field it
  # needs. Callers that want to special-case `isError` can do so
  # via `(get result "isError")`.
  defp extract_call_result(result) when is_map(result), do: result
  defp extract_call_result(other), do: other

  defp oldest_pending(pending) do
    case Map.keys(pending) do
      [] ->
        nil

      ids ->
        id = Enum.min(ids)
        {id, Map.fetch!(pending, id)}
    end
  end

  defp largest_pending_max_bytes(pending) when map_size(pending) == 0, do: nil

  defp largest_pending_max_bytes(pending) do
    pending
    |> Map.values()
    |> Enum.map(& &1.max_bytes)
    |> Enum.max()
  end

  defp fail_all_pending(state, reason, detail) do
    Enum.each(state.pending, fn {_id, entry} ->
      cancel_timer(entry.timer)
      GenServer.reply(entry.from, {:error, reason, detail})
    end)
  end

  defp cancel_timer(timer) when is_reference(timer) do
    Process.cancel_timer(timer)
  end

  defp cancel_timer(_), do: :ok

  # ----------------------------------------------------------------
  # Framing helpers
  # ----------------------------------------------------------------

  defp extract_one_line(buffer) do
    case :binary.match(buffer, "\n") do
      :nomatch ->
        :more

      {pos, 1} ->
        <<line::binary-size(^pos), _newline::binary-size(1), rest::binary>> = buffer
        {:line, line, rest}
    end
  end

  defp send_frame(port, frame) do
    case Jason.encode(frame) do
      {:ok, encoded} ->
        try do
          true = Port.command(port, encoded <> "\n")
          :ok
        rescue
          e -> {:error, Exception.message(e)}
        end

      {:error, reason} ->
        {:error, "encode failed: #{inspect(reason)}"}
    end
  end

  # ----------------------------------------------------------------
  # Port lifecycle
  # ----------------------------------------------------------------

  defp open_port(config) do
    cd = Map.get(config, :cd, nil)

    with {:ok, command} <- fetch_command(config),
         {:ok, executable} <- locate_executable(command, cd) do
      args = Map.get(config, :args, []) || []
      env = Map.get(config, :env, %{}) || %{}

      port_opts = [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        {:args, args},
        {:env, env_to_charlist(env)}
      ]

      port_opts =
        case cd do
          nil -> port_opts
          dir when is_binary(dir) -> [{:cd, dir} | port_opts]
        end

      try do
        port = Port.open({:spawn_executable, executable}, port_opts)
        {:ok, port}
      rescue
        e -> {:error, "Port.open raised: #{Exception.message(e)}"}
      end
    end
  end

  defp fetch_command(config) do
    # Atom keys only — JSON-loaded configs are normalized at the
    # `PtcRunnerMcp.Application.normalize_stdio_config/1` boundary,
    # so Stdio never sees string keys. A misnamed key here is a
    # programmer error and should fail loudly rather than fall
    # through silently.
    case Map.get(config, :command) do
      cmd when is_binary(cmd) and cmd != "" -> {:ok, cmd}
      _ -> {:error, "stdio config missing :command"}
    end
  end

  # Resolve `command` to an absolute filesystem path, honoring the
  # configured `:cd`. Codex review of `0f6c1cd` flagged that a
  # relative `command` like `"./bin/server"` was previously
  # `File.regular?`-checked against PtcRunner's CWD, not the
  # configured upstream `cd`, so project-local binaries could not
  # be configured this way unless PtcRunner itself was launched
  # from the upstream's directory.
  #
  # Three cases:
  #
  #   1. Absolute path — used verbatim, just check it exists.
  #   2. Path-shaped (contains "/") and relative — resolved against
  #      `:cd` if set, otherwise against PtcRunner's CWD.
  #   3. Bare name (no "/") — `System.find_executable/1` walks PATH
  #      as before. PATH-lookup is intentionally CWD-independent;
  #      we DO NOT join bare names against `:cd` because that would
  #      change the meaning of `npx`/`mix`/etc. (and break the
  #      MockServer's `command: "mix"` test path).
  defp locate_executable(command, cd) do
    cond do
      Path.type(command) == :absolute ->
        if File.regular?(command),
          do: {:ok, command},
          else: {:error, "command not found: #{command}"}

      String.contains?(command, "/") ->
        base = if is_binary(cd), do: cd, else: File.cwd!()
        resolved = Path.expand(command, base)

        if File.regular?(resolved),
          do: {:ok, resolved},
          else:
            {:error, "command not found: #{resolved} (resolved from #{command} against #{base})"}

      true ->
        case System.find_executable(command) do
          nil -> {:error, "command not found in PATH: #{command}"}
          path -> {:ok, path}
        end
    end
  end

  defp env_to_charlist(env) when is_map(env) do
    Enum.map(env, fn {k, v} ->
      {to_charlist(k), to_charlist(v)}
    end)
  end

  defp close_port(port) when is_port(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    :ok
  end

  # ----------------------------------------------------------------
  # Registry helpers (parallel to Upstream.Fake)
  # ----------------------------------------------------------------

  defp via(name) do
    {:via, Registry, {@registry, name}}
  end

  defp whereis(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # ----------------------------------------------------------------
  # Test seams (NOT public API)
  # ----------------------------------------------------------------
  #
  # These helpers expose the streaming-consumption state machine for
  # unit tests. The `consume_chunk/2` invariants (split-line carry,
  # discard-mode preservation across chunks) are difficult to drive
  # deterministically through a real subprocess because OS pipe
  # chunking is non-deterministic. Tests that need to assert
  # "fragment 1 trips the cap, fragment 2 does NOT trip an unrelated
  # call" go through these seams instead.

  @doc false
  @spec __test_initial_state__(keyword()) :: map()
  def __test_initial_state__(opts \\ []) do
    %{
      name: Keyword.get(opts, :name, "test"),
      port: Keyword.get(opts, :port, nil),
      parent_pid: Keyword.get(opts, :parent_pid, nil),
      buffer: "",
      discarding_until_newline?: false,
      next_id: Keyword.get(opts, :next_id, 1),
      pending: Keyword.get(opts, :pending, %{}),
      tools: [],
      handshake_done?: true,
      max_response_bytes: Keyword.get(opts, :max_response_bytes, nil)
    }
  end

  @doc false
  @spec __test_consume_chunk__(map(), binary()) :: map()
  def __test_consume_chunk__(state, chunk) when is_map(state) and is_binary(chunk) do
    consume_chunk(state, chunk)
  end
end
