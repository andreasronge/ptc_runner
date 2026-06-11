defmodule PtcRunner.TraceLog.Introspection.Holder do
  @moduledoc """
  Host-side owner of a loaded turn-log event list backing an introspection
  grant (P2 of `docs/plans/sandbox-heap-rebaseline.md`).

  `PtcRunner.TraceLog.Introspection.tools/2` starts one holder per path/list
  source; the granted closures ask the holder for *projections*, so the
  events never enter the sandbox process and a program's heap cost tracks
  each result, not the log.

  **Lifecycle:** the holder monitors the process that created the grant and
  stops when it goes down, so a grant cannot leak past its session. The
  reverse direction is isolated: a holder crash surfaces to callers as a
  failed `query/3`, never as an exit signal into the owner.

  **Bounds:** refuses event lists over `:max_bytes` (serialized size) at
  load — fail closed with a clear error rather than silently truncating,
  because an analysis over silently-dropped events would read as "covered
  everything". (The live `PtcRunner.TraceLog.MemorySink` is different: its
  ring-buffer eviction is the documented retention policy.)
  """

  use GenServer

  # Generous by default — the holder lives in host memory, not under the
  # sandbox budget — but bounded: introspecting a bigger log should be an
  # explicit host decision.
  @default_max_bytes 64 * 1024 * 1024

  @doc """
  Starts a holder owning `events` for the calling process.

  Options: `:max_bytes` — serialized-size load cap (default
  #{@default_max_bytes}). Raises `ArgumentError` when the events exceed it.
  """
  @spec start([map()], keyword()) :: {:ok, pid()}
  def start(events, opts \\ []) when is_list(events) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    size = :erlang.external_size(events)

    if size > max_bytes do
      raise ArgumentError,
            "introspection source is #{size} bytes serialized, which exceeds the " <>
              "#{max_bytes}-byte :max_bytes holder cap — raise :max_bytes explicitly " <>
              "or pre-filter the log"
    end

    GenServer.start(__MODULE__, {events, self()})
  end

  @doc """
  Runs `fun` over the held events inside the holder and returns its result.

  `fun` must be host-trusted code; if it raises, the error is re-raised in
  the caller and the holder survives.
  """
  @spec query(pid(), ([map()] -> term()), timeout()) :: term()
  def query(holder, fun, timeout \\ 5_000) when is_function(fun, 1) do
    case GenServer.call(holder, {:query, fun}, timeout) do
      {:ok, result} -> result
      {:error, exception, stacktrace} -> reraise(exception, stacktrace)
    end
  end

  @impl true
  def init({events, owner}) do
    Process.monitor(owner)
    {:ok, events}
  end

  @impl true
  def handle_call({:query, fun}, _from, events) do
    reply =
      try do
        {:ok, fun.(events)}
      rescue
        exception -> {:error, exception, __STACKTRACE__}
      end

    {:reply, reply, events}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _owner, _reason}, events) do
    {:stop, :normal, events}
  end
end
