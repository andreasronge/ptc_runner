defmodule PtcGateway.Application do
  @moduledoc "The gateway application starts an empty supervisor; listeners require explicit startup."
  use Application

  @impl true
  def start(_type, _args) do
    DynamicSupervisor.start_link(strategy: :one_for_one, name: PtcGateway.Supervisor)
  end
end
