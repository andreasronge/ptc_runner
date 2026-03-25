defmodule PtcRunner.TraceLog.Collector do
  @moduledoc """
  GenServer that collects trace events and writes them to a JSONL file.

  The Collector holds an open file handle and writes events as they arrive.
  It manages a monotonic `seq` counter for deterministic event ordering and
  deduplicates `agent.config` events by `agent_id`.

  Events are written in v2 format with `schema_version: 2`.
  """

  use GenServer

  require Logger

  alias PtcRunner.TraceLog.Event

  @schema_version 2
  @trace_header_keys [:trace_kind, :producer, :trace_label, :model, :query]

  defstruct [
    :file,
    :path,
    :trace_id,
    :meta,
    :header,
    :write_errors,
    :start_time,
    :parent_ref,
    :seq,
    :emitted_agent_ids
  ]

  @type t :: %__MODULE__{
          file: File.io_device() | nil,
          path: String.t(),
          trace_id: String.t(),
          meta: map(),
          write_errors: non_neg_integer(),
          start_time: integer(),
          parent_ref: reference() | nil,
          seq: non_neg_integer(),
          emitted_agent_ids: MapSet.t(String.t())
        }

  @doc """
  Starts a new Collector process.

  ## Options

    * `:path` - File path for the JSONL output. Defaults to a timestamped file in the
      directory configured by `Application.get_env(:ptc_runner, :trace_dir)`, or CWD if unset.
    * `:trace_id` - Unique identifier for this trace. Defaults to a random hex string.
    * `:trace_kind` - Discriminator for the type of trace (e.g., `"benchmark"`, `"analysis"`, `"planning"`).
    * `:producer` - Identifier for the component that created this trace (e.g., `"demo.benchmark"`).
    * `:trace_label` - Human-readable label for this trace (e.g., test case name).
    * `:model` - LLM model used for this trace.
    * `:query` - The input query or question for this trace.
    * `:meta` - Producer-specific metadata to include under `data`. Defaults to `%{}`.

  ## Examples

      {:ok, collector} = Collector.start_link(
        path: "/tmp/trace.jsonl",
        trace_kind: "benchmark",
        producer: "demo.benchmark",
        query: "How many products?"
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    # Use start (not start_link) to decouple from the parent process.
    # With start_link, OTP's gen_server terminates the Collector when the
    # parent dies (e.g., Task.async_stream :kill_task), bypassing handle_info.
    # Instead, we monitor the parent and auto-cleanup on parent death.
    GenServer.start(__MODULE__, [{:parent, self()} | opts])
  end

  @doc """
  Writes an event map to the trace file.

  The event is assigned a monotonic `seq` number server-side, then encoded
  to JSON and written. If the event carries an `agent_id` with an
  `agent_config` in its data, the collector will emit an `agent.config`
  event first (deduplicated by agent_id).

  This is an asynchronous operation that never blocks the caller.
  """
  @spec write_event(GenServer.server(), map()) :: :ok
  def write_event(collector, event) when is_map(event) do
    GenServer.cast(collector, {:write_event, event})
  end

  @doc """
  Stops the Collector and closes the file.

  Returns the path to the trace file and the number of write errors.

  ## Examples

      {:ok, path, errors} = Collector.stop(collector)
  """
  @spec stop(GenServer.server()) :: {:ok, String.t(), non_neg_integer()}
  def stop(collector) do
    GenServer.call(collector, :stop)
  end

  @doc """
  Returns the trace_id for this collector.
  """
  @spec trace_id(GenServer.server()) :: String.t()
  def trace_id(collector) do
    GenServer.call(collector, :trace_id)
  end

  @doc """
  Returns the file path for this collector's trace output.
  """
  @spec path(GenServer.server()) :: String.t()
  def path(collector) do
    GenServer.call(collector, :path)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    trace_id = Keyword.get(opts, :trace_id) || generate_trace_id()
    path = Keyword.get(opts, :path) || default_path(trace_id)
    meta = Keyword.get(opts, :meta, %{})
    parent = Keyword.get(opts, :parent)

    # Extract typed trace header fields
    header = Map.new(@trace_header_keys, fn key -> {key, Keyword.get(opts, key)} end)

    # Ensure parent directory exists
    path |> Path.dirname() |> File.mkdir_p!()

    # Trap exits so terminate/2 is called on shutdown and
    # file device crashes become messages instead of killing us.
    Process.flag(:trap_exit, true)

    # Monitor the parent so we auto-cleanup when it dies
    parent_ref = if parent, do: Process.monitor(parent)

    case File.open(path, [:write, :utf8]) do
      {:ok, file} ->
        state = %__MODULE__{
          file: file,
          path: path,
          trace_id: trace_id,
          meta: meta,
          header: header,
          write_errors: 0,
          start_time: System.monotonic_time(:millisecond),
          parent_ref: parent_ref,
          seq: 0,
          emitted_agent_ids: MapSet.new()
        }

        # Write initial trace.start event with seq 0
        state = write_trace_start(state)

        {:ok, state}

      {:error, reason} ->
        {:stop, {:cannot_open_file, path, reason}}
    end
  end

  @impl true
  def handle_cast({:write_event, _event}, %{file: nil} = state) do
    {:noreply, %{state | write_errors: state.write_errors + 1}}
  end

  def handle_cast({:write_event, event}, state) do
    # Maybe emit agent.config before this event
    state = maybe_emit_agent_config(event, state)

    # Assign seq and write
    state = do_write_event(event, state)
    {:noreply, state}
  rescue
    error ->
      if state.write_errors == 0 do
        Logger.warning("Trace collector write failed: #{inspect(error)}, path: #{state.path}")
      end

      {:noreply, %{state | write_errors: state.write_errors + 1, file: nil}}
  end

  @impl true
  def handle_call(:stop, _from, %{file: nil} = state) do
    {:stop, :normal, {:ok, state.path, state.write_errors}, state}
  end

  def handle_call(:stop, _from, state) do
    close_file(state)
    {:stop, :normal, {:ok, state.path, state.write_errors}, %{state | file: nil}}
  end

  @impl true
  def handle_call(:trace_id, _from, state) do
    {:reply, state.trace_id, state}
  end

  @impl true
  def handle_call(:path, _from, state) do
    {:reply, state.path, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{parent_ref: ref} = state)
      when ref != nil do
    close_file(state)
    {:stop, :normal, %{state | file: nil, parent_ref: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{file: nil}), do: :ok

  def terminate(_reason, %{file: file}) do
    File.close(file)
  end

  # Private helpers

  defp do_write_event(event, state) do
    {seq, state} = next_seq(state)

    # Strip agent_config from data (it was used for agent.config emission)
    event =
      with %{"data" => %{} = data} <- event,
           {:ok, _} <- Map.fetch(data, "agent_config") do
        update_in(event, ["data"], &Map.delete(&1, "agent_config"))
      else
        _ -> event
      end

    event = Map.put(event, "seq", seq)

    case Event.encode(event) do
      {:ok, json} -> IO.puts(state.file, json)
      {:error, _} -> :ok
    end

    state
  end

  # Emit agent.config if this event has an unseen agent_id with agent_config data
  defp maybe_emit_agent_config(event, state) do
    agent_id = event["agent_id"]

    agent_config =
      case event do
        %{"data" => %{"agent_config" => config}} -> config
        _ -> nil
      end

    if agent_id && agent_config && agent_id not in state.emitted_agent_ids do
      {seq, state} = next_seq(state)

      config_event = %{
        "schema_version" => @schema_version,
        "event" => "agent.config",
        "trace_id" => state.trace_id,
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "seq" => seq,
        "agent_id" => agent_id,
        "agent_name" => event["agent_name"],
        "config" => Event.sanitize(agent_config)
      }

      case Event.encode(config_event) do
        {:ok, json} -> IO.puts(state.file, json)
        {:error, _} -> :ok
      end

      %{state | emitted_agent_ids: MapSet.put(state.emitted_agent_ids, agent_id)}
    else
      state
    end
  end

  defp next_seq(state) do
    seq = state.seq + 1
    {seq, %{state | seq: seq}}
  end

  defp close_file(%{file: nil}), do: :ok

  defp close_file(state) do
    duration_ms = System.monotonic_time(:millisecond) - state.start_time

    try do
      write_trace_stop(state, duration_ms)
    rescue
      _ -> :ok
    end

    File.close(state.file)
  end

  defp generate_trace_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp default_path(trace_id) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic)
    filename = "trace_#{timestamp}_#{String.slice(trace_id, 0, 8)}.jsonl"

    case Application.get_env(:ptc_runner, :trace_dir) do
      nil -> filename
      dir -> Path.join(dir, filename)
    end
  end

  defp write_trace_start(state) do
    # Build typed header from state
    header =
      state.header
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

    # Producer-specific metadata goes under "data"
    data = if state.meta == %{}, do: nil, else: Event.sanitize(state.meta)

    event =
      %{
        "schema_version" => @schema_version,
        "event" => "trace.start",
        "trace_id" => state.trace_id,
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "seq" => 0,
        "data" => data
      }
      |> Map.merge(header)

    case Event.encode(event) do
      {:ok, json} -> IO.puts(state.file, json)
      {:error, _} -> :ok
    end

    state
  end

  defp write_trace_stop(state, duration_ms) do
    {seq, _state} = next_seq(state)

    event = %{
      "schema_version" => @schema_version,
      "event" => "trace.stop",
      "trace_id" => state.trace_id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "seq" => seq,
      "duration_ms" => duration_ms
    }

    case Event.encode(event) do
      {:ok, json} -> IO.puts(state.file, json)
      {:error, _} -> :ok
    end
  end
end
