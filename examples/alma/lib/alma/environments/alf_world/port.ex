defmodule Alma.Environments.ALFWorld.Port do
  @moduledoc """
  Elixir Port wrapper for the ALFWorld Python bridge.

  Communicates with `priv/alfworld_bridge.py` via JSON-line protocol over stdin/stdout.
  """

  use GenServer

  require Logger

  @default_timeout 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def stop(pid) do
    GenServer.call(pid, :shutdown, @default_timeout)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Sends a command to the Python bridge and returns the parsed JSON response.
  """
  def command(pid, cmd, timeout \\ @default_timeout) do
    GenServer.call(pid, {:command, cmd}, timeout)
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    python = Keyword.get(opts, :python, "python3")
    bridge_path = Keyword.get(opts, :bridge_script, bridge_script_path())

    port =
      Port.open(
        {:spawn_executable, System.find_executable(python)},
        [
          :binary,
          :use_stdio,
          {:line, 1_048_576},
          {:args, [bridge_path]},
          {:env, [{~c"PYTHONUNBUFFERED", ~c"1"}]}
        ]
      )

    {:ok, %{port: port, buffer: "", pending: nil, shutting_down: false}}
  end

  @impl true
  def handle_call({:command, cmd}, from, state) do
    json_line = Jason.encode!(cmd) <> "\n"
    Port.command(state.port, json_line)
    {:noreply, %{state | pending: from}}
  end

  def handle_call(:shutdown, from, state) do
    json_line = Jason.encode!(%{cmd: "shutdown"}) <> "\n"

    try do
      Port.command(state.port, json_line)
    rescue
      ArgumentError -> :ok
    end

    # Give Python a moment to exit gracefully
    Process.send_after(self(), :force_close, 2000)
    {:noreply, %{state | pending: from, shutting_down: true}}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Jason.decode(line) do
      {:ok, response} ->
        if state.pending do
          GenServer.reply(state.pending, {:ok, response})

          if state.shutting_down do
            {:stop, :normal, %{state | pending: nil}}
          else
            {:noreply, %{state | pending: nil}}
          end
        else
          Logger.warning("ALFWorld bridge: unexpected response: #{inspect(response)}")
          {:noreply, state}
        end

      {:error, _} ->
        # Non-JSON output (Python stderr, debug prints)
        Logger.debug("ALFWorld bridge output: #{line}")
        {:noreply, state}
    end
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if state.pending do
      GenServer.reply(state.pending, {:error, "Python bridge exited with status #{status}"})
    end

    {:stop, :normal, %{state | pending: nil}}
  end

  def handle_info(:force_close, state) do
    if state.pending do
      GenServer.reply(state.pending, {:ok, %{"status" => "ok"}})
    end

    {:stop, :normal, %{state | pending: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    try do
      Port.close(state.port)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  defp bridge_script_path do
    Path.join(:code.priv_dir(:alma), "alfworld_bridge.py")
  end
end
