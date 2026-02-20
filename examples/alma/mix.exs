defmodule Alma.MixProject do
  use Mix.Project

  def project do
    [
      app: :alma,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: false,
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
