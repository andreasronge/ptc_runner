defmodule PtcRunner.MixProject do
  use Mix.Project

  def project do
    [
      app: :ptc_runner,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      name: "PtcRunner",
      description: "A BEAM-native Elixir library for Programmatic Tool Calling (PTC)",
      source_url: "https://github.com/devoteam-se/ptc_runner",
      docs: docs(),
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:req_llm, "~> 1.0.0-rc", only: :test}
    ]
  end

  defp aliases do
    [
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test --warnings-as-errors"
      ]
    ]
  end

  defp docs do
    [
      main: "PtcRunner",
      extras: ["README.md", "docs/architecture.md"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/devoteam-se/ptc_runner"},
      homepage_url: "https://github.com/devoteam-se/ptc_runner"
    ]
  end
end
