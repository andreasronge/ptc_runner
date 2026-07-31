defmodule PtcRunner.Application do
  @moduledoc false

  use Application

  alias PtcRunner.Kernel.SemanticRevision

  @impl Application
  def start(_type, _args) do
    _revision = SemanticRevision.current()

    children = [
      PtcRunner.Kernel.MCPOAuth.ManagerCleanup
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: PtcRunner.Supervisor)
  end
end
