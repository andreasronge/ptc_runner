defmodule PtcRunnerLauncher.MixProject do
  use Mix.Project

  @release_config "release_config.exs"
                  |> Path.expand(__DIR__)
                  |> Code.eval_file()
                  |> elem(0)
  @version @release_config.version
  @source_url "https://github.com/andreasronge/ptc_runner"
  @release_url "#{@source_url}/releases/download/#{@release_config.tag_prefix}#{@version}"

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
      package: package(),
      make_precompiler: {:port, CCPrecompiler},
      make_precompiler_url: precompiled_url(),
      make_precompiler_filename: "ptc_runner_launcher",
      make_precompiler_priv_paths: ["ptc_runner_launcher"],
      make_force_build: System.get_env("PTC_RUNNER_LAUNCHER_BUILD_FROM_SOURCE") == "1",
      make_env: %{"MACOSX_DEPLOYMENT_TARGET" => @release_config.macos_deployment_target},
      cc_precompiler: [
        compilers: precompiled_targets()
      ]
    ]
  end

  def application, do: []

  def cli, do: [preferred_envs: [precommit: :test]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:elixir_make, "~> 0.10.0", runtime: false},
      {:cc_precompiler, "~> 0.1.11", runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: &precommit/1
    ]
  end

  defp precommit(test_args) do
    test_args = precommit_test_args!(test_args)
    Application.put_env(:elixir_make, :force_build, ptc_runner_launcher: true)

    Mix.Task.run("deps.get")
    Mix.Task.run("format", ["--check-formatted"])
    Mix.Task.run("compile", ["--warnings-as-errors"])
    Mix.Task.run("test", ["--warnings-as-errors" | test_args])
    Mix.Task.run("cmd", ["bash", "scripts/verify_package.sh"])
  end

  defp precommit_test_args!([]), do: []

  defp precommit_test_args!(["--max-cases", value]) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> ["--max-cases", value]
      _invalid -> Mix.raise("mix precommit requires --max-cases to be a positive integer")
    end
  end

  defp precommit_test_args!(_args) do
    Mix.raise("mix precommit accepts only the optional --max-cases N argument")
  end

  defp precompiled_url do
    System.get_env("PTC_RUNNER_LAUNCHER_PRECOMPILED_URL") ||
      "#{@release_url}/@{artefact_filename}"
  end

  defp precompiled_targets do
    case System.get_env("PTC_RUNNER_LAUNCHER_PRECOMPILE_TARGET") do
      nil ->
        @release_config.precompiled_targets

      selected ->
        case for {os, targets} <- @release_config.precompiled_targets,
                 {:ok, compiler} <- [Map.fetch(targets, selected)],
                 do: {os, %{selected => compiler}} do
          [target] -> Map.new([target])
          [] -> raise "unsupported precompile target"
        end
    end
  end

  defp package do
    [
      files: ~w(
        c_src
        lib
        checksum.exs
        CHANGELOG.md
        LICENSE
        Makefile
        README.md
        mix.exs
        release_config.exs
      ),
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
