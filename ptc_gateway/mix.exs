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
      aliases: aliases(),
      deps: [
        {:ptc_runner, path: "..", only: [:dev, :test]},
        launcher_dep(),
        {:req_llm, "~> 1.20", runtime: false},
        {:plug, "~> 1.18"},
        {:bandit, "~> 1.6"}
      ]
    ]
  end

  def cli, do: [preferred_envs: [soak: :test]]

  def application, do: [mod: {PtcGateway.Application, []}, extra_applications: [:logger]]

  # The load and leak probe. Excluded from `mix test` (test/test_helper.exs)
  # because its signal is a slope and a peak measured over thousands of calls,
  # not a per-commit gate, and because it measures VM-wide counters that a
  # parallel suite would perturb.
  defp aliases, do: [{:soak, ["test --only soak"]}, {:"ptc.gateway", &run_gateway/1}]

  defp run_gateway(args) do
    Mix.shell(Mix.Shell.Quiet)
    System.put_env("MIX_QUIET", "1")
    app_file = Path.join([Mix.Project.app_path(), "ebin", "ptc_gateway.app"])
    prepare_args = if File.regular?(app_file), do: ["--no-deps-check"], else: []
    Mix.Task.run("app.config", prepare_args)
    Mix.Task.run("ptc.gateway", args)
  end

  defp launcher_dep do
    launcher_path = Path.expand("../ptc_runner_launcher/release_config.exs", __DIR__)

    if File.regular?(launcher_path) do
      {:ptc_runner_launcher, "~> 0.2.0", path: "../ptc_runner_launcher", override: true}
    else
      {:ptc_runner_launcher, "~> 0.2.0", override: true}
    end
  end
end
