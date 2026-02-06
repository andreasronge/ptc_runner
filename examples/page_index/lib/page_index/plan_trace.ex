defmodule PageIndex.PlanTrace do
  @moduledoc """
  File-based tracing for PlanExecutor events.

  Writes events to JSONL files compatible with PtcRunner's trace_viewer.html.

  ## Usage

      {:ok, tracer} = PlanTrace.start("traces")
      handler = PlanTrace.handler(tracer)

      PlanExecutor.run(mission,
        llm: llm,
        on_event: handler
      )

      PlanTrace.stop(tracer)
  """

  use GenServer

  defstruct [:file, :path, :trace_id, :start_time]

  @doc """
  Starts a new trace collector.

  ## Options

    * `:trace_dir` - Directory for trace files (default: "traces")
    * `:trace_id` - Custom trace ID (auto-generated if not provided)
  """
  def start(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Stops the trace collector and closes the file.

  Returns `{:ok, path}` with the path to the trace file.
  """
  def stop(tracer) do
    GenServer.call(tracer, :stop)
  end

  @doc """
  Returns the trace file path.
  """
  def path(tracer) do
    GenServer.call(tracer, :path)
  end

  @doc """
  Creates an event handler function for PlanExecutor.
  """
  def handler(tracer) do
    fn event -> handle_event(tracer, event) end
  end

  @doc """
  Handles a PlanExecutor event.
  """
  def handle_event(tracer, event) do
    GenServer.cast(tracer, {:event, event})
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    trace_dir = Keyword.get(opts, :trace_dir, "traces")
    trace_id = Keyword.get(opts, :trace_id) || generate_trace_id()

    # Ensure traces directory exists
    File.mkdir_p!(trace_dir)

    path = Path.join(trace_dir, "plan_trace_#{trace_id}.jsonl")

    case File.open(path, [:write, :utf8]) do
      {:ok, file} ->
        state = %__MODULE__{
          file: file,
          path: path,
          trace_id: trace_id,
          start_time: System.monotonic_time(:millisecond)
        }

        # Write trace start event
        write_event(file, %{
          "event" => "trace.start",
          "trace_id" => trace_id,
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

        {:ok, state}

      {:error, reason} ->
        {:stop, {:cannot_open_file, path, reason}}
    end
  end

  @impl true
  def handle_cast({:event, event}, state) do
    json_event = convert_event(event, state)
    write_event(state.file, json_event)
    {:noreply, state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    # Write trace stop event
    duration_ms = System.monotonic_time(:millisecond) - state.start_time

    write_event(state.file, %{
      "event" => "trace.stop",
      "trace_id" => state.trace_id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "duration_ms" => duration_ms
    })

    File.close(state.file)
    {:stop, :normal, {:ok, state.path}, %{state | file: nil}}
  end

  @impl true
  def handle_call(:path, _from, state) do
    {:reply, state.path, state}
  end

  # Private helpers

  defp generate_trace_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp write_event(file, event) do
    case Jason.encode(event) do
      {:ok, json} -> IO.puts(file, json)
      {:error, _} -> :ok
    end
  end

  defp convert_event(event, state) do
    base = %{
      "trace_id" => state.trace_id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case event do
      {:planning_started, %{mission: mission}} ->
        Map.merge(base, %{
          "event" => "run.start",
          "metadata" => %{"mission" => mission, "phase" => "planning"}
        })

      {:planning_finished, %{task_count: count}} ->
        Map.merge(base, %{
          "event" => "llm.stop",
          "metadata" => %{"phase" => "planning", "task_count" => count}
        })

      {:planning_failed, %{reason: reason}} ->
        Map.merge(base, %{
          "event" => "llm.stop",
          "metadata" => %{"phase" => "planning", "error" => inspect(reason)}
        })

      {:planning_retry, %{validation_errors: count}} ->
        Map.merge(base, %{
          "event" => "llm.start",
          "metadata" => %{"phase" => "planning_retry", "validation_errors" => count}
        })

      {:execution_started, %{mission: mission, task_count: count}} ->
        Map.merge(base, %{
          "event" => "run.start",
          "metadata" => %{"mission" => mission, "task_count" => count, "phase" => "execution"}
        })

      {:execution_finished, %{status: status, duration_ms: ms}} ->
        Map.merge(base, %{
          "event" => "run.stop",
          "duration_ms" => ms,
          "metadata" => %{"status" => to_string(status)}
        })

      {:task_started, %{task_id: id, attempt: attempt}} ->
        Map.merge(base, %{
          "event" => "tool.start",
          "span_id" => id,
          "metadata" => %{"tool_name" => id, "attempt" => attempt}
        })

      {:task_succeeded, %{task_id: id, duration_ms: ms}} ->
        Map.merge(base, %{
          "event" => "tool.stop",
          "span_id" => id,
          "duration_ms" => ms,
          "metadata" => %{"tool_name" => id, "status" => "success"}
        })

      {:task_failed, %{task_id: id, reason: reason}} ->
        Map.merge(base, %{
          "event" => "tool.stop",
          "span_id" => id,
          "metadata" => %{"tool_name" => id, "status" => "failed", "error" => inspect(reason)}
        })

      {:task_skipped, %{task_id: id, reason: reason}} ->
        Map.merge(base, %{
          "event" => "tool.stop",
          "span_id" => id,
          "metadata" => %{"tool_name" => id, "status" => "skipped", "reason" => to_string(reason)}
        })

      {:verification_failed, %{task_id: id, diagnosis: diagnosis}} ->
        Map.merge(base, %{
          "event" => "tool.stop",
          "span_id" => "verify_#{id}",
          "metadata" => %{"tool_name" => "verify_#{id}", "diagnosis" => diagnosis}
        })

      {:replan_started, %{task_id: id, diagnosis: diagnosis, total_replans: n}} ->
        Map.merge(base, %{
          "event" => "llm.start",
          "metadata" => %{
            "phase" => "replan",
            "task_id" => id,
            "diagnosis" => diagnosis,
            "replan_number" => n
          }
        })

      {:replan_finished, %{new_tasks: count}} ->
        Map.merge(base, %{
          "event" => "llm.stop",
          "metadata" => %{"phase" => "replan", "new_task_count" => count}
        })

      _ ->
        Map.merge(base, %{
          "event" => "unknown",
          "metadata" => %{"raw" => inspect(event)}
        })
    end
  end
end
