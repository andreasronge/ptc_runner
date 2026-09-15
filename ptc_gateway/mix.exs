defmodule PtcGateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :ptc_gateway,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: [
        {:ptc_runner, path: ".."},
        {:req_llm, "~> 1.20", runtime: false},
        {:plug, "~> 1.18"},
        {:bandit, "~> 1.6"}
      ]
    ]
  end

  def application, do: [mod: {PtcGateway.Application, []}, extra_applications: [:logger]]
end
