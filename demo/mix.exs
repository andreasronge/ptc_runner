defmodule PtcDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :ptc_demo,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      escript: escript(),
      aliases: aliases()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp escript do
    [main_module: PtcDemo.LispCLI]
  end

  defp deps do
    [
      {:ptc_runner, path: ".."},
      {:llm_client, path: "../llm_client"},
      {:dotenvy, "~> 1.1"}
    ]
  end

  defp aliases do
    [
      lisp: "run --no-halt -e \"PtcDemo.LispCLI.main(System.argv())\" --"
    ]
  end
end
