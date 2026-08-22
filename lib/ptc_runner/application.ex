defmodule PtcRunner.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children =
      [PtcRunner.Kernel.MCPOAuth.ManagerCleanup] ++ ptc_llm_http_runtime()

    Supervisor.start_link(children, strategy: :one_for_one, name: PtcRunner.Supervisor)
  end

  defp ptc_llm_http_runtime do
    if Code.ensure_loaded?(PtcRunner.LLM.PtcLlmHttpRuntime),
      do: [PtcRunner.LLM.PtcLlmHttpRuntime],
      else: []
  end
end
