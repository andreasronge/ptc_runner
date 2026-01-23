defmodule GapAnalyzer.MixProject do
  use Mix.Project

  def project do
    [
      app: :gap_analyzer,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ptc_runner, path: "../../"},
      {:llm_client, path: "../../llm_client"}
    ]
  end
end
