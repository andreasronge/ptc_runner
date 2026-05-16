defmodule PtcRunnerMcp.TestSupport.SoakHelpers do
  @moduledoc """
  Shared helpers for MCP soak tests.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias PtcRunnerMcp.{ConcurrencyGate, Sessions, Tools}
  alias PtcRunnerMcp.Sessions.Config, as: SessionsConfig
  alias PtcRunnerMcp.Sessions.Registry, as: SessionsRegistry

  def setup_sessions(config \\ %{enabled: true}) do
    stop_sessions_processes()
    SessionsConfig.set(config)
    ConcurrencyGate.reset()
    assert :ok = Sessions.ensure_started()

    on_exit(fn ->
      stop_sessions_processes()
      SessionsConfig.reset()
      ConcurrencyGate.reset()
    end)

    :ok
  end

  def start_session do
    %{"structuredContent" => sc} =
      Tools.call(%{"name" => "ptc_session_start", "arguments" => %{}})

    sc["session_id"]
  end

  def eval_ok!(session_id, program) do
    response =
      Tools.call(%{
        "name" => "ptc_session_eval",
        "arguments" => %{"session_id" => session_id, "program" => program}
      })

    sc = response["structuredContent"]
    assert sc["status"] == "ok", "eval failed: #{inspect(sc)}"
    sc
  end

  def close_session!(session_id) do
    Tools.call(%{
      "name" => "ptc_session_close",
      "arguments" => %{"session_id" => session_id}
    })
  end

  def stop_sessions_processes do
    stop_if_alive(SessionsRegistry)
    stop_if_alive(PtcRunnerMcp.Sessions.Supervisor)
  end

  defp stop_if_alive(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> stop_process(pid)
    end
  end

  defp stop_process(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 5_000)
    end
  catch
    :exit, _ -> :ok
  end
end
