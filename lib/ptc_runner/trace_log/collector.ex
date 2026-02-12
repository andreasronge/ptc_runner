defmodule PtcRunner.TraceLog.Collector do
  @moduledoc """
  GenServer that collects trace events and writes them to a JSONL file.

  The Collector holds an open file handle and writes events as they arrive.
  It tracks write errors and closes the file cleanly when stopped or terminated.

  If the underlying file device process crashes, the collector logs a warning
  on the first write error and stops attempting further writes.
  """

  use GenServer

  require Logger

  alias PtcRunner.TraceLog.Event

  defstruct [:file, :path, :trace_id, :meta, :write_errors, :start_time, :parent_ref]

  @type t :: %__MODULE__{
          file: File.io_device() | nil,
          path: String.t(),
          trace_id: String.t(),
          meta: map(),
          write_errors: non_neg_integer(),
          start_time: integer(),
          parent_ref: reference() | nil
        }

  @doc """
  Starts a new Collector process.

  ## Options

    * `:path` - File path for the JSONL output. Defaults to a timestamped file in the
      directory configured by `Application.get_env(:ptc_runner, :trace_dir)`, or CWD if unset.
    * `:trace_id` - Unique identifier for this trace. Defaults to a random hex string.
    * `:meta` - Additional metadata to include with the trace. Defaults to `%{}`.

  ## Examples

      {:ok, collector} = Collector.start_link(path: "/tmp/trace.jsonl")
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
  Writes a JSON line to the trace file.

  This is an asynchronous operation that never blocks the caller.
  Write errors are tracked but do not crash the caller.
  """
  @spec write(GenServer.server(), String.t()) :: :ok
  def write(collector, json_line) when is_binary(json_line) do
    GenServer.cast(collector, {:write, json_line})
  end

  @doc """
  Writes an event map to the trace file.

  The event is encoded to JSON before writing.
  """
  @spec write_event(GenServer.server(), map()) :: :ok
  def write_event(collector, event) when is_map(event) do
    case Event.encode(event) do
      {:ok, json} -> write(collector, json)
      {:error, _reason} -> :ok
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
          write_errors: 0,
          start_time: System.monotonic_time(:millisecond),
          parent_ref: parent_ref
        }

        # Write initial metadata event
        write_meta_event(state)

        {:ok, state}

      {:error, reason} ->
        {:stop, {:cannot_open_file, path, reason}}
    end
  end

  @impl true
  def handle_cast({:write, _json_line}, %{file: nil} = state) do
    {:noreply, %{state | write_errors: state.write_errors + 1}}
  end

  def handle_cast({:write, json_line}, state) do
    IO.puts(state.file, json_line)
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
    # Parent process died (e.g., killed by Task.async_stream timeout).
    # Close the file gracefully so the trace data is preserved,
    # then stop since nobody will call stop/1.
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

  defp close_file(%{file: nil}), do: :ok

  defp close_file(state) do
    duration_ms = System.monotonic_time(:millisecond) - state.start_time

    try do
      write_stop_event(state, duration_ms)
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

  defp write_meta_event(state) do
    event = %{
      "event" => "trace.start",
      "trace_id" => state.trace_id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "meta" => state.meta
    }

    case Event.encode(event) do
      {:ok, json} -> IO.puts(state.file, json)
      {:error, _} -> :ok
    end
  end

  defp write_stop_event(state, duration_ms) do
    event = %{
      "event" => "trace.stop",
      "trace_id" => state.trace_id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "duration_ms" => duration_ms
    }

    case Event.encode(event) do
      {:ok, json} -> IO.puts(state.file, json)
      {:error, _} -> :ok
    end
  end
end
