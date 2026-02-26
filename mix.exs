defmodule PtcRunner.MixProject do
  use Mix.Project

  def project do
    [
      app: :ptc_runner,
      version: "0.8.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      name: "PtcRunner",
      description:
        "A BEAM-native Elixir library for Programmatic Tool Calling (PTC) with a lispy DSL (subset of Clojure). PTC lets LLMs generate small programs that orchestrate multiple tool calls and data transformations in code.",
      source_url: "https://github.com/andreasronge/ptc_runner",
      docs: docs(),
      package: package(),
      test_coverage: [
        ignore_modules: [PtcRunner.TestSupport.LLMClient]
      ],
      dialyzer: [
        plt_core_path: "priv/plts",
        plt_file: {:no_warn, "priv/plts/project.plt"},
        plt_add_apps: [:ex_unit, :mix, :req, :req_llm]
      ]
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
      {:nimble_parsec, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:stream_data, "~> 1.1", only: [:test, :dev]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:req, "~> 0.5", optional: true},
      {:req_llm, "~> 1.2", optional: true},
      {:kino, "~> 0.14", optional: true},
      {:llm_client, path: "llm_client", only: [:test, :dev]},
      {:ptc_viewer, path: "ptc_viewer", only: [:test, :dev]},
      {:usage_rules, "~> 1.2", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "format --check-formatted",
        "compile --force --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "schema.gen",
        "ptc.validate_spec",
        "test --warnings-as-errors",
        "cmd --cd llm_client mix test --color",
        "cmd --cd demo mix test --color",
        "cmd --cd ptc_viewer mix test --color"
      ],
      "schema.gen": [
        "run -e 'File.write!(\"priv/ptc_schema.json\", Jason.encode!(PtcRunner.Schema.to_json_schema(), pretty: true))'"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
        # SubAgent Guides (learning path)
        "docs/guides/subagent-getting-started.md",
        "docs/guides/subagent-text-mode.md",
        "docs/guides/subagent-concepts.md",
        "docs/guides/subagent-patterns.md",
        "docs/guides/subagent-navigator.md",
        "docs/guides/subagent-meta-planner.md",
        "docs/guides/subagent-rlm-patterns.md",
        "docs/guides/subagent-testing.md",
        "docs/guides/subagent-troubleshooting.md",
        "docs/guides/subagent-observability.md",
        "docs/guides/subagent-compression.md",
        "docs/guides/subagent-advanced.md",
        "docs/guides/subagent-prompts.md",
        # Reference
        "docs/signature-syntax.md",
        "docs/benchmark-eval.md",
        # PTC-Lisp
        "docs/ptc-lisp-specification.md",
        # Livebooks
        "livebooks/ptc_runner_playground.livemd",
        "livebooks/ptc_runner_llm_agent.livemd",
        "livebooks/meta_planner.livemd",
        "livebooks/joke_workflow.livemd",
        "livebooks/observability_and_tracing.livemd"
      ],
      groups_for_extras: [
        "SubAgent Guides": ~r/docs\/guides\/subagent-.+\.md/,
        Reference: ~r/docs\/(signature-syntax|benchmark-eval|ptc-lisp-.+|reference\/.+)\.md/,
        Livebooks: ~r/livebooks\/.+\.livemd/
      ],
      assets: %{"images" => "images"},
      before_closing_body_tag: &before_closing_body_tag/1
    ]
  end

  defp before_closing_body_tag(:html) do
    """
    <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
    <script>
      document.addEventListener("DOMContentLoaded", function () {
        mermaid.initialize({
          startOnLoad: false,
          theme: document.body.className.includes("dark") ? "dark" : "default"
        });
        let id = 0;
        for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
          const preEl = codeEl.parentElement;
          const graphDefinition = codeEl.textContent;
          const graphEl = document.createElement("div");
          const graphId = "mermaid-graph-" + id++;
          mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
            graphEl.innerHTML = svg;
            bindFunctions?.(graphEl);
            preEl.insertAdjacentElement("afterend", graphEl);
            preEl.remove();
          });
        }
      });
    </script>
    """
  end

  defp before_closing_body_tag(_), do: ""

  defp package do
    [
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE CHANGELOG.md priv/prompts),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/andreasronge/ptc_runner",
        "Changelog" => "https://github.com/andreasronge/ptc_runner/blob/main/CHANGELOG.md"
      }
    ]
  end
end
