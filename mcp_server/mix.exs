defmodule PtcRunnerMcp.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/andreasronge/ptc_runner"

  def project do
    [
      app: :ptc_runner_mcp,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      description: "MCP server exposing PtcRunner's PTC-Lisp sandbox over stdio JSON-RPC.",
      source_url: @source_url,
      dialyzer: [
        plt_core_path: "priv/plts",
        plt_file: {:no_warn, "priv/plts/project.plt"},
        plt_add_apps: [:ex_unit, :mix]
      ]
    ]
  end

  # Mix release configuration — see Plans/ptc-runner-mcp-server.md § 15
  # Phase 5. Produces a runnable artifact at
  # `_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp`. The release
  # bundles the path-dep `:ptc_runner` library and the OTP app starts
  # `PtcRunnerMcp.Application` (already wired via `application/0`).
  defp releases do
    [
      ptc_runner_mcp: [
        include_executables_for: [:unix, :windows],
        rel_templates_path: "rel",
        applications: [
          ptc_runner: :permanent,
          ptc_runner_mcp: :permanent
        ],
        strip_beams: true
      ]
    ]
  end

  def application do
    [
      mod: {PtcRunnerMcp.Application, []},
      # `:crypto` is required by `PtcRunnerMcp.TracePayload.sha256_hex/1`,
      # which `JsonRpc.traced_tools_call/3` calls unconditionally on every
      # `tools/call`. In dev/test `:crypto` is loaded by default, but a
      # Mix release boot script only loads applications listed here, so
      # without this entry the release would raise
      # `:crypto.hash/2 is undefined` for every tool call. Caught by
      # Phase 6a integration tests against the release artifact.
      extra_applications: [:logger, :crypto]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Path dep because the MCP server is built from this repository as a
      # standalone release artifact, not published as its own package.
      {:ptc_runner, path: "..", override: true},
      {:jason, "~> 1.4"},
      {:req_llm, "~> 1.11"},
      # `Plans/http-transport-credentials.md` §4.5: `:req` is the HTTP
      # client used by `Upstream.Http`. Marked `optional: true` so
      # the HTTP transport still owns its direct dependency contract.
      # Agentic planner mode also pulls `:req` transitively through
      # `:req_llm`; keep this direct optional entry so publishing
      # metadata still documents the HTTP transport's requirement.
      # `Application.load_aggregator_config/1` raises at config load if
      # any upstream entry declares `transport: "http"` and `:req` is
      # not loaded.
      {:req, "~> 0.5", optional: true},
      # Phase 2F (`Plans/http-transport-credentials.md` §13.2): the
      # local HTTP fixture is a Plug served by Bandit. Test/dev only;
      # never shipped in the release.
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:recon, "~> 2.5", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "test"
      ],
      "mcp.start": ["run --no-halt"],
      "mcp.run": ["run --no-halt"]
    ]
  end
end
