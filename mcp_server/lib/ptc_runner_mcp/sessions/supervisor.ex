defmodule PtcRunnerMcp.Sessions.Supervisor do
  @moduledoc """
  Dynamic supervisor for per-session PTC-Lisp REPL processes.
  """

  use DynamicSupervisor

  alias PtcRunnerMcp.Sessions.Session

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a new session child under the named dynamic supervisor."
  @spec start_session(keyword(), GenServer.server()) :: DynamicSupervisor.on_start_child()
  def start_session(opts, supervisor \\ __MODULE__) when is_list(opts) do
    child = {Session, opts}
    DynamicSupervisor.start_child(supervisor, child)
  end
end
