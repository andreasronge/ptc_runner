# Wire the `:ptc_runner_mcp` ebin onto the BEAM code path when the
# bench is driven from the repo root (where `:ptc_runner_mcp` is not a
# dep of the parent Mix project). Idempotent — `Code.prepend_path/1`
# is a no-op if the path is already loaded. The application is then
# started so `PtcRunnerMcp.Stdio.start_link/1` and friends are
# resolvable.
mcp_server_dir = Path.expand(Path.join(__DIR__, ".."))

[mcp_server_dir, "_build", to_string(Mix.env()), "lib", "ptc_runner_mcp", "ebin"]
|> Path.join()
|> tap(fn ebin ->
  if File.dir?(ebin) do
    Code.prepend_path(ebin)
  end
end)

# Suppress production stdio attachment so starting the application
# does not race the bench for OS stdin / stdout.
Application.put_env(:ptc_runner_mcp, :attach_stdio, false)

# Best-effort start; if the application is already running (because
# the bench was launched from `mcp_server/`), this is a no-op.
case Application.ensure_all_started(:ptc_runner_mcp) do
  {:ok, _} -> :ok
  {:error, _} -> :ok
end

# Silence MCP server's per-call info logs during the bench so the
# stdout report stays clean. The `Log` module ships its own atomic
# log-level mechanism independent of `:logger`.
PtcRunnerMcp.Log.set_level("error")

# Two clients used by the Phase 6 benchmarks.
#
#   * `PtcRunnerMcp.Bench.InBeamClient` — drives the production
#     `PtcRunnerMcp.Stdio` GenServer in this BEAM via a `StringIO`
#     device. Exercises the full NDJSON / JSON-RPC / per-call worker /
#     concurrency-gate plumbing — the same code path that an OS-level
#     subprocess client traverses, minus the Unix pipe.
#
#   * `PtcRunnerMcp.Bench.OsProcessClient` — spawns the released
#     binary as a real OS subprocess (via `sh -c`-style pipes that
#     bypass BEAM-on-BEAM Port stdin oddities) and measures
#     full-handshake latency. Used for one-shot startup-cost
#     observation, not per-call hot-loop benchmarking.
#
# Spec sections:
#   § 6.1     — NDJSON framing
#   § 6.3     — concurrency / per-call workers
#   § 7       — handshake (`initialize` / `notifications/initialized`)
#   § 9, § 10 — request / response contract for `lisp_eval`

defmodule PtcRunnerMcp.Bench.InBeamClient do
  @moduledoc false

  alias PtcRunnerMcp.Stdio

  @type t :: %{
          stdio: pid(),
          io: pid(),
          next_id: pos_integer()
        }

  @doc """
  Start the in-BEAM stdio harness. The MCP `Stdio` GenServer is
  launched with `auto_read: false` so we feed bytes synchronously,
  the same way the test suite does. Completes the handshake before
  returning.
  """
  @spec start() :: t()
  def start do
    {:ok, io} = StringIO.open(<<>>, capture_prompt: false)
    name = :"bench_stdio_#{:erlang.unique_integer([:positive])}"

    {:ok, stdio} =
      Stdio.start_link(
        io: io,
        observer: self(),
        auto_read: false,
        name: name
      )

    state = %{stdio: stdio, io: io, next_id: 1}

    {:ok, _init_reply, state} = handshake(state)
    state
  end

  @doc """
  Run `tools/call lisp_eval` and block until the reply arrives.
  Returns the parsed JSON-RPC envelope.
  """
  @spec call_tool(t(), String.t(), map()) :: {:ok, map(), t()} | {:error, map(), t()}
  def call_tool(state, program, arguments_extra \\ %{}) do
    arguments = Map.merge(%{"program" => program}, arguments_extra)

    request(state, "tools/call", %{
      "name" => "lisp_eval",
      "arguments" => arguments
    })
  end

  @doc "Stop the harness."
  @spec close(t()) :: :ok
  def close(%{stdio: stdio, io: io}) do
    if Process.alive?(stdio), do: try_stop(fn -> GenServer.stop(stdio, :normal, 1_000) end)
    if Process.alive?(io), do: try_stop(fn -> StringIO.close(io) end)
    :ok
  end

  defp try_stop(fun) do
    try do
      fun.()
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp handshake(state) do
    {:ok, init_reply, state} =
      request(state, "initialize", %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "ptc-runner-bench", "version" => "0.1.0"}
      })

    :ok = notify(state, "notifications/initialized", %{})
    {:ok, init_reply, state}
  end

  defp request(state, method, params) do
    id = state.next_id
    state = %{state | next_id: id + 1}

    frame = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }

    bytes = Jason.encode!(frame) <> "\n"

    drain_replied_messages()
    _ = StringIO.flush(state.io)
    :ok = Stdio.feed(state.stdio, bytes)

    case wait_for_reply_envelope(id, 30_000) do
      {:ok, envelope} ->
        case envelope do
          %{"id" => ^id, "error" => _} -> {:error, envelope, state}
          %{"id" => ^id} -> {:ok, envelope, state}
        end

      {:error, reason} ->
        {:error, %{"error" => reason}, state}
    end
  end

  defp notify(state, method, params) do
    frame = %{"jsonrpc" => "2.0", "method" => method, "params" => params}
    bytes = Jason.encode!(frame) <> "\n"
    Stdio.feed(state.stdio, bytes)
  end

  defp wait_for_reply_envelope(id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(id, deadline)
  end

  defp do_wait(id, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {Stdio, :replied, frame} ->
        case frame do
          %{"id" => ^id} -> {:ok, frame}
          _ -> do_wait(id, deadline)
        end
    after
      timeout -> {:error, :timeout}
    end
  end

  defp drain_replied_messages do
    receive do
      {Stdio, :replied, _} -> drain_replied_messages()
    after
      0 -> :ok
    end
  end
end

defmodule PtcRunnerMcp.Bench.OsProcessClient do
  @moduledoc false

  @doc """
  Run a single `initialize` round-trip against the released binary
  via a real OS subprocess. Returns `{:ok, ms}` with the wall-clock
  time spent on the handshake (including process startup), or
  `{:error, reason}`.

  Uses `System.shell/2` because BEAM-on-BEAM `Port.open` has
  long-standing stdin-pipe quirks on macOS / Linux that prevent
  byte-flow from the parent BEAM to a child release. A shell pipe
  is the canonical workaround.
  """
  @spec measure_startup_handshake(Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def measure_startup_handshake(release_path) do
    if File.exists?(release_path) do
      frame =
        ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"bench","version":"0.1.0"}}})

      script = """
      RELEASE_DISTRIBUTION=none PTC_RUNNER_MCP_LOG_LEVEL=error \
      printf '%s\\n' '#{frame}' | \
      RELEASE_DISTRIBUTION=none PTC_RUNNER_MCP_LOG_LEVEL=error \
      PTC_RUNNER_MCP_UPSTREAMS=/nonexistent/ptc_runner_mcp_bench_upstreams.json \
      #{release_path} start 2>/dev/null
      """

      t0 = System.monotonic_time(:millisecond)
      {output, exit_code} = System.shell(script, stderr_to_stdout: true)
      wall_ms = System.monotonic_time(:millisecond) - t0

      cond do
        exit_code != 0 ->
          {:error, {:nonzero_exit, exit_code, output}}

        not String.contains?(output, "\"protocolVersion\"") ->
          {:error, {:no_handshake_in_output, output}}

        true ->
          {:ok, wall_ms}
      end
    else
      {:error, {:not_found, release_path}}
    end
  end
end
