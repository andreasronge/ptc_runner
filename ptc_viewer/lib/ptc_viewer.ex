defmodule PtcViewer do
  @moduledoc """
  PTC Trace Viewer — a web UI for browsing PTC traces and plans.

  ## Usage

      {:ok, pid} = PtcViewer.start(port: 4123, trace_dir: "traces", plan_dir: "data")
      PtcViewer.stop(pid)
  """

  @doc """
  Starts the PTC Viewer web server.

  ## Options

    * `:port` - Port to listen on (default: 4123)
    * `:trace_dir` - Directory containing .jsonl trace files (default: "traces")
    * `:plan_dir` - Directory containing .json plan files (default: "data")
    * `:open` - Whether to auto-open the browser (default: true)
  """
  def start(opts \\ []) do
    port = Keyword.get(opts, :port, 4123)
    trace_dir = Keyword.get(opts, :trace_dir, "traces")
    plan_dir = Keyword.get(opts, :plan_dir, "data")
    open = Keyword.get(opts, :open, true)

    Application.put_env(:ptc_viewer, :trace_dir, trace_dir)
    Application.put_env(:ptc_viewer, :plan_dir, plan_dir)

    result = Bandit.start_link(plug: PtcViewer.Router, port: port)

    if open && match?({:ok, _}, result) do
      System.cmd("open", ["http://localhost:#{port}"])
    end

    result
  end

  @doc "Stops the PTC Viewer web server."
  def stop(pid) do
    Supervisor.stop(pid)
  end
end
