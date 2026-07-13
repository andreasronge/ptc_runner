defmodule PtcRunner.MixProject do
  use Mix.Project

  def project do
    [
      app: :ptc_runner,
      version: "0.13.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      usage_rules: usage_rules(),
      name: "PtcRunner",
      description: "BEAM-native sandbox and minimal Kernel for bounded PTC-Lisp workflows.",
      source_url: "https://github.com/andreasronge/ptc_runner",
      docs: docs(),
      package: package(),
      test_coverage: [
        summary: [threshold: 0],
        ignore_modules: [
          ~r/^Mix\.Tasks\./,
          ~r/^PtcRunner\.TestSupport\./,
          PtcRunner.TypeExtractorFixtures,
          # Dev/conformance tool gated behind Babashka + `--include clojure`;
          # only production callers are Mix tasks, not runtime code.
          PtcRunner.Lisp.ClojureValidator,
          # Bare display structs: they only carry data for their
          # Inspect/String.Chars/Jason.Encoder impls (separate modules);
          # zero executable lines of their own.
          PtcRunner.Lisp.Format.Fn,
          PtcRunner.Lisp.Format.Builtin,
          PtcRunner.Lisp.Format.Var,
          PtcRunner.Lisp.Format.SymbolRef,
          PtcRunner.Lisp.Format.RegexLiteral
        ]
      ],
      dialyzer: [
        plt_core_path: "priv/plts",
        plt_file: {:no_warn, "priv/plts/project.plt"},
        plt_add_apps: [:ex_unit, :mix, :req, :req_llm, :recon],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      env: [
        model_registry: PtcRunner.LLM.DefaultRegistry,
        llm_adapter: PtcRunner.LLM.ReqLLMAdapter
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, prepush: :test, coverage: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Generated dependency rules in AGENTS.md. Link bulky rules rather than
  # inlining them so the repo's own instructions stay readable.
  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [
        {:usage_rules, link: :markdown, sub_rules: []},
        {"usage_rules:elixir", link: :markdown, main: false},
        {"usage_rules:otp", link: :markdown, main: false}
      ]
    ]
  end

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
      {:req_llm, "~> 1.8", optional: true},
      {:ptc_viewer, path: "ptc_viewer", only: [:test, :dev]},
      {:usage_rules, "~> 1.2", only: :dev, runtime: false},
      {:recon, "~> 2.5", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "xref graph --format cycles --label compile-connected --fail-above 0",
        "credo --strict",
        "ptc.validate_spec",
        "test --warnings-as-errors",
        "cmd --cd ptc_viewer mix test --color"
      ],
      # Slower checks kept out of the per-commit loop; run before pushing.
      # CI runs dialyzer + the unused-deps check on every PR regardless.
      prepush: [
        "dialyzer",
        "deps.unlock --check-unused"
      ],
      coverage: [
        "test --cover"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      groups_for_modules: [
        Kernel: [
          PtcRunner.Kernel,
          PtcRunner.Kernel.Capability,
          PtcRunner.Kernel.Component,
          PtcRunner.Kernel.Limits,
          PtcRunner.Kernel.Manifest,
          PtcRunner.Kernel.MissionEnvironment,
          PtcRunner.Kernel.ProviderRegistry,
          PtcRunner.Kernel.ReplSession,
          PtcRunner.Kernel.RunBuilder,
          PtcRunner.Kernel.RunConfig,
          PtcRunner.Kernel.TraceLog,
          PtcRunner.Kernel.WorkflowEnvironment
        ],
        "PTC-Lisp": [
          PtcRunner.Lisp,
          PtcRunner.Lisp.Context,
          PtcRunner.Lisp.Parser,
          PtcRunner.Lisp.Registry,
          PtcRunner.Lisp.Result,
          PtcRunner.Lisp.Signature,
          PtcRunner.Lisp.Signature.Validator,
          PtcRunner.Lisp.TypeExtractor,
          PtcRunner.Sandbox
        ],
        LLM: [
          PtcRunner.LLM,
          PtcRunner.LLM.Registry,
          PtcRunner.LLM.DefaultRegistry,
          PtcRunner.LLM.ReqLLMAdapter
        ]
      ],
      extras:
        [
          "README.md",
          "LICENSE",
          "docs/ptc-lisp-specification.md",
          "docs/clojure-conformance-gaps.md",
          "docs/function-reference.md",
          "docs/java-interop.md",
          "docs/plans/lisp-kernel/kernel-contract.md",
          "docs/plans/lisp-kernel/tracelog-contract.md",
          "docs/conformance/index.md",
          "docs/guides/capability-prelude.md",
          "docs/guides/kernel-tutorial.md",
          "docs/guides/kernel-repl.md"
        ] ++ Path.wildcard("docs/conformance/*-audit.md"),
      groups_for_extras: [
        Kernel: ~r/docs\/plans\/lisp-kernel\/.+\.md/,
        Guides: ~r/docs\/guides\/.+\.md/,
        Reference: ~r/docs\/(ptc-lisp|clojure|function-reference|java-).+\.md/,
        Conformance: ~r/docs\/conformance\/.+\.md/
      ]
    ]
  end

  defp package do
    [
      files:
        ~w(lib docs examples/kernel-tutorial .formatter.exs mix.exs README.md LICENSE CHANGELOG.md priv/function_audit.exs priv/functions.exs priv/java_compat_audit.exs priv/preludes priv/spec),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/andreasronge/ptc_runner",
        "Changelog" => "https://github.com/andreasronge/ptc_runner/blob/main/CHANGELOG.md"
      }
    ]
  end
end
