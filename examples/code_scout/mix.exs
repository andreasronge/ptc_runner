defmodule CodeScout.MixProject do
  use Mix.Project

  def project do
    [
      app: :code_scout,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ptc_runner, path: "../../"},
      {:llm_client, path: "../../llm_client"}
    ]
  end
end
