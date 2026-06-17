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
  @default_max_event_bytes 1_048_576
  @default_max_mailbox_len 1_000

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
    cond do
      mailbox_full?(collector) ->
        :ok

      prepared = prepare_for_enqueue(event) ->
        GenServer.cast(collector, {:write_event, prepared})

      true ->
        :ok
    end
  end

  @doc """
  Returns the event byte cap applied before enqueueing and writing events.
  """
  @spec max_event_bytes() :: pos_integer()
  def max_event_bytes do
    configured = Application.get_env(:ptc_runner, :trace_collector_max_event_bytes)

    case configured do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_max_event_bytes
    end
  end

  @doc """
  Returns the collector mailbox length at which new events are shed.
  """
  @spec max_mailbox_len() :: non_neg_integer()
  def max_mailbox_len do
    configured = Application.get_env(:ptc_runner, :trace_collector_max_mailbox_len)

    case configured do
      value when is_integer(value) and value >= 0 -> value
      _ -> @default_max_mailbox_len
    end
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

  def handle_cast({:write_event, prepared}, state) do
    # Maybe emit agent.config before this event
    state = maybe_emit_agent_config(prepared.agent_config_event, state)

    # Assign seq and write
    state =
      if prepared.event do
        do_write_event(prepared.event, state)
      else
        state
      end

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

    # Telemetry-sourced events already carry trace_id/timestamp; `write_to_active`
    # callers (e.g. session/SubAgent turn events) need not know the collector's
    # trace_id, so stamp ours when absent. `put_new` never overrides an
    # explicitly-set value (the MCP per-call records set their own).
    event =
      event
      |> Map.put_new("trace_id", state.trace_id)
      |> Map.put_new_lazy("timestamp", fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)

    event = Map.put(event, "seq", seq)
    event = bound_final_event(event)

    if event do
      case Event.encode(event) do
        {:ok, json} -> IO.puts(state.file, json)
        {:error, _} -> :ok
      end
    end

    state
  end

  defp prepare_for_enqueue(event) do
    max_bytes = max_event_bytes()
    {event, agent_config_event} = split_agent_config(event, max_bytes)

    case bound_unstamped_event(event, max_bytes) do
      nil when is_nil(agent_config_event) -> nil
      bounded_event -> %{event: bounded_event, agent_config_event: agent_config_event}
    end
  end

  defp split_agent_config(event, max_bytes) do
    agent_config =
      case event do
        %{"data" => %{"agent_config" => config}} -> config
        _ -> nil
      end

    stripped_event =
      with %{"data" => %{} = data} <- event,
           {:ok, _} <- Map.fetch(data, "agent_config") do
        update_in(event, ["data"], &Map.delete(&1, "agent_config"))
      else
        _ -> event
      end

    {stripped_event, prepare_agent_config_event(stripped_event, agent_config, max_bytes)}
  end

  defp prepare_agent_config_event(%{"agent_id" => agent_id} = event, agent_config, max_bytes)
       when not is_nil(agent_id) and not is_nil(agent_config) do
    config_event = %{
      "schema_version" => @schema_version,
      "event" => "agent.config",
      "agent_id" => agent_id,
      "agent_name" => event["agent_name"],
      "config" => Event.sanitize(agent_config)
    }

    if :erlang.external_size(agent_config) > max_bytes do
      compact_agent_config_event(event, max_bytes)
    else
      case approx_event_bytes(config_event) do
        bytes when bytes <= max_bytes -> config_event
        _ -> compact_agent_config_event(event, max_bytes)
      end
    end
  end

  defp prepare_agent_config_event(_event, _agent_config, _max_bytes), do: nil

  defp compact_agent_config_event(event, max_bytes) do
    config_event = %{
      "schema_version" => @schema_version,
      "event" => "agent.config",
      "agent_id" => event["agent_id"],
      "agent_name" => bounded_binary(event["agent_name"], 128),
      "config" => %{
        "omitted" => true,
        "reason" => "agent_config_too_large",
        "max_event_bytes" => max_bytes
      }
    }

    bound_unstamped_event(config_event, max_bytes)
  end

  defp bound_unstamped_event(event, max_bytes) do
    case approx_event_bytes(event) do
      bytes when bytes <= max_bytes -> event
      bytes -> summarize_oversized_event(event, bytes, max_bytes)
    end
  end

  defp approx_event_bytes(event), do: :erlang.external_size(event)

  defp bound_final_event(event) do
    max_bytes = max_event_bytes()

    case Event.encode(event) do
      {:ok, json} when byte_size(json) <= max_bytes ->
        event

      {:ok, json} ->
        summarize_oversized_event(event, byte_size(json), max_bytes)

      {:error, _reason} ->
        nil
    end
  end

  defp summarize_oversized_event(event, original_bytes, max_bytes) do
    summary =
      %{
        "schema_version" => @schema_version,
        "event" => "trace.event_omitted",
        "trace_id" => event["trace_id"],
        "timestamp" => event["timestamp"],
        "seq" => event["seq"],
        "agent_id" => bounded_binary(event["agent_id"], 128),
        "agent_name" => bounded_binary(event["agent_name"], 128),
        "turn" => bounded_integer(event["turn"]),
        "tool_name" => bounded_binary(event["tool_name"], 128),
        "model" => bounded_binary(event["model"], 128),
        "status" => bounded_binary(event["status"], 64),
        "data" => %{
          "reason" => "trace_event_too_large",
          "original_event" => bounded_binary(event["event"], 128),
          "original_bytes" => original_bytes,
          "max_event_bytes" => max_bytes
        }
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    case Event.encode(summary) do
      {:ok, json} when byte_size(json) <= max_bytes -> summary
      _ -> nil
    end
  end

  defp bounded_binary(value, max_bytes) when is_binary(value) do
    if byte_size(value) <= max_bytes do
      value
    else
      truncate_utf8(value, max_bytes)
    end
  end

  defp bounded_binary(value, max_bytes) when is_atom(value) do
    value |> Atom.to_string() |> bounded_binary(max_bytes)
  end

  defp bounded_binary(value, max_bytes) when is_number(value) do
    value |> to_string() |> bounded_binary(max_bytes)
  end

  defp bounded_binary(_value, _max_bytes), do: nil

  defp truncate_utf8(_value, max_bytes) when max_bytes <= 0, do: ""

  defp truncate_utf8(value, max_bytes) do
    chunk = binary_part(value, 0, max_bytes)

    if String.valid?(chunk) do
      chunk
    else
      truncate_utf8(value, max_bytes - 1)
    end
  end

  defp bounded_integer(value) when is_integer(value), do: value
  defp bounded_integer(_value), do: nil

  defp mailbox_full?(collector) do
    with max_len <- max_mailbox_len(),
         pid when is_pid(pid) <- collector_pid(collector),
         true <- Process.alive?(pid),
         {:message_queue_len, queue_len} <- Process.info(pid, :message_queue_len) do
      if queue_len >= max_len do
        true
      else
        false
      end
    else
      _ -> false
    end
  end

  defp collector_pid(pid) when is_pid(pid), do: pid
  defp collector_pid(name) when is_atom(name), do: Process.whereis(name)
  defp collector_pid({:global, name}), do: :global.whereis_name(name)

  defp collector_pid({:via, registry, name}) do
    if function_exported?(registry, :whereis_name, 1) do
      registry.whereis_name(name)
    end
  end

  defp collector_pid(_collector), do: nil

  # Emit agent.config if this event has an unseen agent_id with agent_config data
  defp maybe_emit_agent_config(nil, state), do: state

  defp maybe_emit_agent_config(event, state) do
    agent_id = event["agent_id"]

    if agent_id && agent_id not in state.emitted_agent_ids do
      state = do_write_event(event, state)
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
