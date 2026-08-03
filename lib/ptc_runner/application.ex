defmodule PtcRunner.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      PtcRunner.Kernel.MCPOAuth.ManagerCleanup
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: PtcRunner.Supervisor)
  end
end
