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
        plt_add_apps: [:ex_unit, :mix, :req, :req_llm, :llm_db, :recon],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {PtcRunner.Application, []},
      extra_applications: [:crypto, :logger, :public_key, :ssl],
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
      {:jsv, "== 0.21.2"},
      {:nimble_parsec, "~> 1.4"},
      {:mint, "~> 1.9"},
      {:req, "== 0.6.3"},
      {:telemetry, "~> 1.0"},
      {:stream_data, "~> 1.1", only: [:test, :dev]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:req_llm, "~> 1.8", optional: true, runtime: false},
      launcher_dep(),
      {:ptc_viewer, path: "ptc_viewer", only: [:test, :dev]},
      {:usage_rules, "~> 1.2", only: :dev, runtime: false},
      {:recon, "~> 2.5", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: [:dev, :test], runtime: false}
    ]
  end

  # Local development exercises the companion from this checkout. Published
  # package metadata instead carries the compatible optional Hex requirement,
  # so HTTP-only consumers are not forced to install native support.
  defp launcher_dep do
    launcher_path = Path.expand("ptc_runner_launcher", __DIR__)

    if Mix.env() in [:dev, :test] and File.dir?(launcher_path) do
      {:ptc_runner_launcher, "~> 0.1.0", path: "ptc_runner_launcher", optional: true}
    else
      {:ptc_runner_launcher, "~> 0.1.0", optional: true}
    end
  end

  defp aliases do
    [
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "xref graph --format cycles --label compile-connected --fail-above 0",
        "credo --strict",
        "ptc.validate_spec",
        "ptc.gen_docs --check",
        "ptc.gen_semantic_revision --check",
        "ptc.conformance_report --check-inventory",
        "test --warnings-as-errors",
        "cmd --cd ptc_viewer mix test --color",
        "cmd --cd ptc_runner_launcher mix precommit",
        "cmd bash scripts/verify_core_package.sh"
      ],
      # Slower checks kept out of the per-commit loop; run before pushing.
      # PR CI runs these as individual steps. The upstream audit attests all
      # exact Java descriptors when Java 11 or newer is available.
      prepush: [
        "ptc.audit_upstream",
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
          PtcRunner.Kernel.ApplicationPackage,
          PtcRunner.Kernel.Capability,
          PtcRunner.Kernel.Component,
          PtcRunner.Kernel.Error,
          PtcRunner.Kernel.EventSink,
          PtcRunner.Kernel.ExecutionInput,
          PtcRunner.Kernel.ExecutionPolicy,
          PtcRunner.Kernel.FrozenBundle,
          PtcRunner.Kernel.InspectionArtifact,
          PtcRunner.Kernel.InspectionSink,
          PtcRunner.Kernel.Library,
          PtcRunner.Kernel.Limits,
          PtcRunner.Kernel.LLMCapability,
          PtcRunner.Kernel.Manifest,
          PtcRunner.Kernel.MCPSource,
          PtcRunner.Kernel.MissionInventory,
          PtcRunner.Kernel.MissionEnvironment,
          PtcRunner.Kernel.ProviderError,
          PtcRunner.Kernel.ProviderRegistry,
          PtcRunner.Kernel.ReplSession,
          PtcRunner.Kernel.Result,
          PtcRunner.Kernel.RunBuilder,
          PtcRunner.Kernel.RunConfig,
          PtcRunner.Kernel.RunRequest,
          PtcRunner.Kernel.TraceCapability,
          PtcRunner.Kernel.TraceLog,
          PtcRunner.Kernel.WorkflowEnvironment
        ],
        "Kernel internals": [
          PtcRunner.Kernel.ApplicationSource,
          PtcRunner.Kernel.Attestation,
          PtcRunner.Kernel.BoundedWorker,
          PtcRunner.Kernel.BundleCompiler,
          PtcRunner.Kernel.DeterministicJSON,
          PtcRunner.Kernel.Dispatcher,
          PtcRunner.Kernel.Environment,
          PtcRunner.Kernel.Evaluation,
          PtcRunner.Kernel.Events,
          PtcRunner.Kernel.JSONValue,
          PtcRunner.Kernel.JSONSchema,
          PtcRunner.Kernel.MCPProtocol,
          PtcRunner.Kernel.Program,
          PtcRunner.Kernel.RunState,
          PtcRunner.Kernel.Runner,
          PtcRunner.Kernel.RuntimeTools,
          PtcRunner.Kernel.SemanticRevision,
          PtcRunner.Kernel.StrictJSON,
          PtcRunner.Kernel.TypedCanonicalJSON,
          PtcRunner.Kernel.ViewerAdapter
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
          "docs/signature-syntax.md",
          "docs/trace-log-contract.md",
          "docs/conformance/index.md",
          "docs/guides/getting-started.md",
          "docs/guides/manifests-and-capabilities.md",
          "docs/guides/host-configuration.md",
          "docs/guides/building-agents.md",
          "docs/guides/running-and-debugging.md",
          "docs/guides/kernel-repl.md",
          "docs/guides/components-and-preludes.md",
          "docs/guides/embedding-in-elixir.md",
          "docs/guides/documentation-guidelines.md",
          "docs/guides/kernel-maintainer.md"
        ] ++ Path.wildcard("docs/conformance/*-audit.md"),
      groups_for_extras: [
        Maintainers: ~r/docs\/guides\/kernel-maintainer\.md/,
        Contracts: ~r/docs\/trace-log-contract\.md/,
        Guides: ~r/docs\/guides\/.+\.md/,
        Reference: ~r/docs\/(ptc-lisp|clojure|function-reference|java-|signature-).+\.md/,
        Conformance: ~r/docs\/conformance\/.+\.md/
      ]
    ]
  end

  defp package do
    [
      files:
        ~w(lib docs examples/kernel-tutorial examples/kernel-inspection-lab .formatter.exs mix.exs README.md LICENSE CHANGELOG.md priv/function_audit.exs priv/functions.exs priv/java_interop.exs priv/java_interop_oracle_cases.exs priv/java_interop_oracle_baseline.json priv/java_oracle_versions.exs priv/preludes priv/schemas priv/spec priv/semantic_build_inventory.exs priv/semantic_build_projection.json),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/andreasronge/ptc_runner",
        "Changelog" => "https://github.com/andreasronge/ptc_runner/blob/main/CHANGELOG.md"
      }
    ]
  end
end
