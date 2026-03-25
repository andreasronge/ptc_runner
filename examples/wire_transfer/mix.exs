defmodule WireTransfer.MixProject do
  use Mix.Project

  def project do
    [
      app: :wire_transfer,
      version: "0.1.0",
      elixir: "~> 1.15",
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
      {:req, "~> 0.5"},
      {:req_llm, "~> 1.8"}
    ]
  end
end
