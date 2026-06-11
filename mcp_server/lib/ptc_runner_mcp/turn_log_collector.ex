defmodule PtcRunnerMcp.TurnLogCollector do
  @moduledoc """
  Supervised owner for the MCP server's canonical session turn-log file.
  """

  use GenServer

  alias PtcRunner.TraceLog.Collector
  alias PtcRunnerMcp.TurnLogConfig

  defstruct [:collector, :path]

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @spec path(GenServer.server()) :: String.t()
  def path(server \\ __MODULE__), do: GenServer.call(server, :path)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    dir = Keyword.fetch!(opts, :dir)
    path = Keyword.get(opts, :path) || default_path(dir)

    {:ok, collector} =
      Collector.start_link(
        path: path,
        trace_kind: "mcp.turn_log",
        producer: "ptc_runner_mcp",
        trace_label: "stateful sessions"
      )

    TurnLogConfig.put_collector(collector)

    {:ok, %__MODULE__{collector: collector, path: path}}
  end

  @impl GenServer
  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  @impl GenServer
  def terminate(_reason, %{collector: collector}) do
    TurnLogConfig.put_collector(nil)

    if is_pid(collector) and Process.alive?(collector) do
      _ = Collector.stop(collector)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp default_path(dir) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic)
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    Path.join(dir, "#{timestamp}-#{suffix}-turns.jsonl")
  end
end
