defmodule PtcRunner.CLIProgress do
  @moduledoc false
  use GenServer

  alias PtcRunner.CLIProgress.Format
  alias PtcRunner.Kernel.CommandPresentation
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.LiveStatus.Target

  @heartbeat_ms 10_000

  def start(arguments, opts) do
    writer = Keyword.get(opts, :progress_writer, &IO.write(:stderr, &1))
    columns = Keyword.get(opts, :progress_columns, fn -> :io.columns(:standard_error) end)
    clock = Keyword.get(opts, :progress_clock, fn -> System.monotonic_time(:millisecond) end)
    guarded_start(self(), {arguments, writer, columns, clock})
  end

  def attach(runtime, nil), do: {:ok, runtime}

  def attach(runtime, pid) do
    {:ok, progress} =
      Target.new(fn _run_id, frame -> send(pid, {:frame, frame}) end, append_external?: true)

    target =
      case runtime.live_status do
        nil -> progress
        existing -> elem(Target.compose([progress, existing]), 1)
      end

    CommandRuntime.with_live_status(runtime, target)
  end

  def finish(nil, _presentation), do: :ok

  def finish(pid, presentation) do
    GenServer.call(pid, {:finish, presentation}, 250)
  catch
    :exit, _ ->
      Process.exit(pid, :kill)
      :ok
  end

  defp guarded_start(owner, init) do
    request = make_ref()

    spawn(fn ->
      owner_ref = Process.monitor(owner)
      result = GenServer.start(__MODULE__, init)
      send(owner, {request, result})

      case result do
        {:ok, progress} -> guard(owner, owner_ref, progress)
        _failure -> :ok
      end
    end)

    receive do
      {^request, {:ok, pid}} -> pid
      {^request, _failure} -> nil
    end
  end

  defp guard(owner, owner_ref, progress) do
    progress_ref = Process.monitor(progress)

    receive do
      {:DOWN, ^owner_ref, :process, ^owner, _reason} -> Process.exit(progress, :kill)
      {:DOWN, ^progress_ref, :process, ^progress, _reason} -> :ok
    end
  end

  @impl GenServer
  def init({arguments, writer, columns, clock}) do
    now = clock.()

    width =
      case columns.() do
        {:ok, value} when value > 0 -> value
        _ -> nil
      end

    title = safe_title(arguments.application)

    state = %{
      writer: writer,
      clock: clock,
      started: now,
      width: width,
      previous: if(width, do: String.length("preparing 00:00"), else: 0),
      last_frame: nil,
      last_key: nil,
      last_write: now
    }

    initial =
      if width,
        do: title <> "\n\rpreparing 00:00",
        else: "[00:00] preparing " <> title <> "\n"

    {:ok, Map.put(state, :initial, initial), {:continue, :write_initial}}
  rescue
    _ -> :ignore
  catch
    _, _ -> :ignore
  end

  @impl GenServer
  def handle_continue(:write_initial, state),
    do: {:noreply, state |> write(state.initial) |> Map.delete(:initial)}

  @impl GenServer
  def handle_info({:frame, frame}, state) do
    frame =
      Map.put(
        frame,
        :elapsed_ms,
        max(Map.get(frame, :elapsed_ms, 0), state.clock.() - state.started)
      )

    {:noreply, render(state, frame)}
  rescue
    _ -> {:noreply, state}
  catch
    _, _ -> {:noreply, state}
  end

  @impl GenServer
  def handle_call({:finish, %CommandPresentation{exit_status: status}}, _from, state) do
    frame = state.last_frame || %{elapsed_ms: state.clock.() - state.started, usage: nil}
    event = if status == 0, do: "completed", else: "failed"
    state = terminal(state, frame, event)
    {:stop, :normal, :ok, state}
  rescue
    _ -> {:stop, :normal, :ok, state}
  catch
    _, _ -> {:stop, :normal, :ok, state}
  end

  defp render(%{width: width} = state, frame) when is_integer(width) do
    line = Format.interactive(with_agents(frame), width)

    write(
      state,
      "\r" <> line <> String.duplicate(" ", max(state.previous - String.length(line), 0))
    )

    %{state | previous: String.length(line), last_frame: frame}
  end

  defp render(state, frame) do
    display_frame = with_agents(frame)
    now = state.clock.()
    key = milestone_key(display_frame)

    if key != state.last_key or now - state.last_write >= @heartbeat_ms do
      event = if key == state.last_key, do: "still running", else: milestone_event(display_frame)
      write(state, Format.milestone(display_frame, event) <> "\n")
      %{state | last_frame: frame, last_key: key, last_write: now}
    else
      %{state | last_frame: frame}
    end
  end

  defp terminal(%{width: width} = state, frame, event) when is_integer(width) do
    write(
      state,
      "\r" <>
        String.duplicate(" ", state.previous) <> "\r" <> Format.milestone(frame, event) <> "\n"
    )
  end

  defp terminal(state, frame, event) do
    if milestone_event(frame) == event,
      do: state,
      else: write(state, Format.milestone(frame, event) <> "\n")
  end

  defp milestone_key(frame), do: {Map.get(frame, :phase), Map.get(frame, :agents)}
  defp milestone_event(%{phase: phase}) when phase in ["ok", "completed"], do: "completed"
  defp milestone_event(%{phase: phase}) when phase in ["error", "failed"], do: "failed"

  defp milestone_event(%{agents: [%{invocation: id, turn: turn, max_turns: max, kind: kind}]}) do
    "agent #{String.slice(id, 6, 4)} turn #{turn}/#{max} · #{kind}"
  end

  defp milestone_event(_), do: "running"

  defp with_agents(%{activity: activity} = frame) when is_list(activity) do
    agents =
      activity
      |> Enum.filter(&match?(%{kind: "agent", name: name} when is_binary(name), &1))
      |> Enum.uniq_by(& &1.name)
      |> Enum.map(fn entry ->
        %{
          invocation: entry.name,
          turn: entry.turn + 1,
          max_turns: entry.max_turns,
          kind: entry.status
        }
      end)

    Map.put(frame, :agents, agents)
  end

  defp with_agents(frame), do: frame

  defp safe_title(application) do
    application
    |> then(&Path.basename(&1 || "run"))
    |> String.replace(~r/[\x00-\x1F\x7F-\x{9F}]/u, "?")
    |> PtcRunner.Utf8.truncate_valid(128)
  end

  defp write(state, data) do
    _ = state.writer.(data)
    state
  rescue
    _ -> state
  catch
    _, _ -> state
  end
end
