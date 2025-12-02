defmodule PtcDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :ptc_demo,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp escript do
    [main_module: PtcDemo.CLI]
  end

  defp deps do
    [
      {:ptc_runner, path: ".."},
      {:req_llm, "~> 1.0.0-rc"}
    ]
  end
end
