defmodule PtcRunnerLauncher.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/andreasronge/ptc_runner"

  def project do
    [
      app: :ptc_runner_launcher,
      version: @version,
      elixir: "~> 1.15",
      compilers: [:elixir_make] ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      description: "Native POSIX process launcher for PtcRunner MCP stdio transports.",
      source_url: @source_url,
      package: package()
    ]
  end

  def application, do: []

  def cli, do: [preferred_envs: [precommit: :test]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:elixir_make, "~> 0.10.0", runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test --warnings-as-errors",
        "cmd bash scripts/verify_package.sh"
      ]
    ]
  end

  defp package do
    [
      files: ~w(
        c_src
        lib
        CHANGELOG.md
        LICENSE
        Makefile
        README.md
        mix.exs
      ),
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
