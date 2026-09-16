defmodule PtcGateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :ptc_gateway,
      version: "0.1.0",
      elixir: "~> 1.15",
      # In an assembled production release this sibling is compiled as a
      # load-only dependency before its ptc_runner host. Remote core calls are
      # resolved when both applications are loaded; dev/test retain the path
      # dependency below and therefore get ordinary cross-app checking.
      elixirc_options: [no_warn_undefined: :all],
      start_permanent: Mix.env() == :prod,
      deps: [
        {:ptc_runner, path: "..", only: [:dev, :test]},
        {:req_llm, "~> 1.20", runtime: false},
        {:plug, "~> 1.18"},
        {:bandit, "~> 1.6"}
      ]
    ]
  end

  def application, do: [mod: {PtcGateway.Application, []}, extra_applications: [:logger]]
end
