defmodule PtcRunner.MixProject do
  use Mix.Project

  @app :ptc_runner

  def project do
    [
      app: @app,
      version: "0.14.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
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
        plt_core_path: dialyzer_plt_core_path(),
        plt_file: {:no_warn, "priv/plts/project.plt"},
        plt_add_apps: [:earmark_parser, :ex_unit, :mix, :req, :req_llm, :llm_db, :recon],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true
      ]
    ]
  end

  # The core PLT (Erlang/Elixir/OTP plus `plt_add_apps`) is identical across
  # every worktree of this repo: mise.toml pins the same Elixir/OTP build,
  # and worktree branches share one mix.lock unless a branch deliberately
  # changes deps. Keeping it worktree-local means the first Dialyzer run in
  # every fresh worktree rebuilds it from scratch. Outside CI, share one
  # copy under the user's cache directory instead. `plt_file` (this
  # project's own module signatures) stays worktree-local: unlike the core
  # PLT, it legitimately differs between branches with diverging code, and
  # concurrent worktree sessions writing the same project PLT would race.
  #
  # CI keeps the repo-local "priv/plts" path because `setup-elixir`
  # restores/saves it via `actions/cache`, keyed by OS/arch/OTP/Elixir/
  # mix.lock — an external-cache scheme that expects a path inside the
  # checkout, not the user cache directory of an ephemeral runner.
  defp dialyzer_plt_core_path do
    if System.get_env("CI") do
      "priv/plts"
    else
      Path.expand("~/.cache/ptc_runner/dialyzer_plts")
    end
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {PtcRunner.Application, []},
      extra_applications: [:crypto, :logger, :public_key, :ssl],
      env: [
        llm_adapter: PtcRunner.LLM.ReqLLMAdapter
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        prepush: :test,
        coverage: :test,
        soak: :test,
        nightly: :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  # Generated dependency rules in AGENTS.md. Inline the short instructions
  # that tell agents how to consult dependency documentation, but link the
  # bulky language and runtime rules so the repository instructions stay
  # readable.
  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [
        {:usage_rules, sub_rules: []},
        {"usage_rules:elixir", link: :markdown, main: false},
        {"usage_rules:otp", link: :markdown, main: false}
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:jsv, "~> 0.22.0"},
      {:nimble_parsec, "~> 1.4"},
      {:mint, "~> 1.9"},
      {:req, "~> 0.7.3"},
      {:telemetry, "~> 1.0"},
      {:stream_data, "~> 1.1", only: [:test, :dev]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      ex_dna_dep(),
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:earmark_parser, "~> 1.4.44", only: [:dev, :test], runtime: false},
      {:req_llm, "~> 1.20", optional: true, runtime: false},
      {:ptc_llm_http, "== 0.1.0", only: [:dev, :test], runtime: false},
      launcher_dep(),
      {:usage_rules, "~> 1.2", only: :dev, runtime: false},
      {:recon, "~> 2.5", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: [:dev, :test], runtime: false}
    ] ++ viewer_dep()
  end

  # Keep published and ordinary development builds on Hex while allowing an
  # unreleased ExDNA checkout to be exercised by an isolated compatibility
  # build. The caller must keep this environment variable set for every Mix
  # command in that build so dependency resolution stays consistent.
  defp ex_dna_dep do
    options = [only: [:dev, :test], runtime: false]

    case {Mix.env(), System.get_env("PTC_EX_DNA_PATH")} do
      {env, path} when env in [:dev, :test] and is_binary(path) and path != "" ->
        {:ex_dna, Keyword.put(options, :path, Path.expand(path))}

      {_env, _path} ->
        {:ex_dna, "~> 1.5", options}
    end
  end

  # Development, tests, and a release built from this checkout exercise the
  # companion beside it. Ordinary production tasks retain package metadata's
  # compatible optional Hex requirement, so HTTP-only consumers are not forced
  # to install native support and `mix hex.build` never sees a path dependency.
  defp launcher_dep do
    launcher_path = Path.expand("ptc_runner_launcher", __DIR__)

    if local_launcher_checkout?(launcher_path) do
      {:ptc_runner_launcher, "~> 0.1.0", path: "ptc_runner_launcher", optional: true}
    else
      {:ptc_runner_launcher, "~> 0.1.0", optional: true}
    end
  end

  # The sentinel is the companion's own version file rather than its directory:
  # `ptc_runner_launcher/mix.exs` evaluates `release_config.exs` while it is
  # being loaded, so a directory holding only the mix file is an unloadable
  # path dependency. Tooling that reconstructs a project from the mix files it
  # fetched — Dependabot's Hex updater does exactly this — produces precisely
  # that tree, and pointing at it fails the whole run before any dependency is
  # resolved.
  defp local_launcher_checkout?(launcher_path) do
    File.regular?(Path.join(launcher_path, "release_config.exs")) and
      (Mix.env() in [:dev, :test] or Enum.any?(System.argv(), &(&1 == "release")))
  end

  # The Viewer ships inside the assembled release and the container image, and
  # is absent from the Hex package. The activation rule is the launcher's --
  # development, tests, and a release built from this checkout -- because
  # `mix hex.build` must never see a path dependency and the Dockerfile's
  # single `mix do deps.get --only prod + release ...` must.
  #
  # Unlike the launcher, the inactive branch declares nothing at all rather
  # than an optional Hex requirement. The launcher is published to Hex; this
  # companion is not, and a requirement naming a package absent from the
  # registry would fail the next `mix hex.publish`. Declaring nothing is also
  # what is true: a Hex-only install has no Viewer, which is exactly what
  # `PtcRunner.Kernel.DoctorEnvironment` already reports.
  #
  # `runtime: false` is load-bearing. `bandit`, `plug`, and `plug_crypto` all
  # declare application modules, so an ordinary runtime dependency would enter
  # `ptc_runner.app` and every command's `ensure_all_started(:ptc_runner)`
  # would start three supervision trees that only `ptc viewer` needs.
  # `PtcViewer.start/1` starts its own applications instead.
  defp viewer_dep do
    viewer_path = Path.expand("ptc_viewer", __DIR__)

    if File.regular?(Path.join(viewer_path, "mix.exs")) and
         (Mix.env() in [:dev, :test] or Enum.any?(System.argv(), &(&1 == "release"))) do
      [{:ptc_viewer, path: "ptc_viewer", runtime: false}]
    else
      []
    end
  end

  defp aliases do
    [
      ptc: &run_ptc/1,
      # Nested fetch then quality. The suite, Viewer, launcher package, and
      # release belong to the pre-push hook and GitHub Actions, so an agent
      # that runs this before commit does not pay for them again on push.
      precommit: [
        "cmd scripts/ci/preflight.sh",
        "cmd scripts/ci/core-quality.sh"
      ],
      # Slower static and Dialyzer checks kept out of the per-commit loop.
      # This diagnostic alias delegates to the same repository-owned scripts
      # as the pre-push hook and GitHub Actions; it is not a second gate
      # implementation.
      #
      # `ptc.gen_semantic_revision --check` is deliberately absent from both:
      # it is a release gate, not a per-commit one. See `.gitattributes`.
      prepush: [
        "cmd scripts/ci/core-static.sh",
        "cmd scripts/ci/core-dialyzer.sh"
      ],
      coverage: [
        "test --cover"
      ],
      # Tests that spawn Mix/OS processes or wait on multi-second deadlines.
      # Excluded from `mix test` by default (test/test_helper.exs); the
      # `Nightly` workflow runs them. `--trace` is retained here and only
      # here: the downstream-consumer case exceeds the default 60 s per-test
      # timeout, and trace mode sets the timeout to `:infinity`. Everywhere
      # else `--trace` is a bug -- it pins `--max-cases` to 1.
      nightly: [
        "test --only nightly --trace"
      ],
      # Memory-leak soak suite. Excluded from `mix test` by default
      # (test/test_helper.exs) because it is long-running and its signal is a
      # trend rather than a per-commit gate; the scheduled `Soak` workflow runs
      # it at PTC_SOAK_ITERATIONS=3000.
      soak: [
        "test --only soak"
      ],
      # Regenerates the derived projection. Run this once before tagging a
      # release -- the release gate rejects a stale projection, and ordinary
      # branches no longer regenerate it at all. Also the correct fix when a
      # merge or rebase kept one side of it. See `.gitattributes` for why the
      # hashes cannot be merged.
      regen: [
        "ptc.gen_semantic_revision",
        "cmd git add priv/semantic_build_projection.json"
      ]
    ]
  end

  defp run_ptc(args) do
    Mix.Task.run(ptc_prepare_task(args), ptc_prepare_args(Mix.Project.app_path()))
    Mix.Task.run("ptc", args)
  end

  @doc false
  @spec ptc_prepare_args(binary()) :: [binary()]
  def ptc_prepare_args(app_path) when is_binary(app_path) do
    # The app compiler runs after the language compilers, so this artifact is
    # an O(1) signal that the initial dependency-aware build completed. Calling
    # Mix.Dep.cached/0 here would restore much of the warm-start cost this path
    # deliberately avoids.
    app_file = Path.join([app_path, "ebin", Atom.to_string(@app) <> ".app"])

    if File.regular?(app_file), do: ["--no-deps-check"], else: []
  end

  # These raw forms are only preparation hints; the shared parser remains the
  # authority for acceptance and rendering. They cover the common commands
  # whose frontend deliberately never starts the application runtime.
  defp ptc_prepare_task([]), do: "compile"

  defp ptc_prepare_task([command | _rest])
       when command in ["help", "version", "--version", "repl", "viewer"],
       do: "compile"

  defp ptc_prepare_task(_args), do: "app.config"

  defp releases do
    [
      ptc_runner: [
        include_erts: true,
        # Both are `runtime: false`, so they are named here to travel with the
        # release at all. `:load` keeps them out of the boot start phase; the
        # provider activity boundary and `ptc viewer` start them explicitly.
        applications: [req_llm: :load, ptc_viewer: :load],
        overlays: ["rel/overlays"],
        steps: [:assemble, &copy_release_notices/1]
      ]
    ]
  end

  defp copy_release_notices(%Mix.Release{path: release_path} = release) do
    licenses_path = Path.join(release_path, "LICENSES")
    File.mkdir_p!(licenses_path)

    File.cp!(
      Path.join(__DIR__, "THIRD_PARTY_NOTICES.md"),
      Path.join(release_path, "THIRD_PARTY_NOTICES.md")
    )

    for license <- ["Apache-2.0.txt", "MIT.txt"] do
      File.cp!(Path.join([__DIR__, "LICENSES", license]), Path.join(licenses_path, license))
    end

    release
  end

  # Mermaid renders natively on GitHub. HexDocs needs the renderer injected;
  # EPUB has no JavaScript, so its diagrams stay readable as source text.
  defp before_closing_body_tag(:html) do
    """
    <script defer src="https://cdn.jsdelivr.net/npm/mermaid@10.2.3/dist/mermaid.min.js"></script>
    <script>
      let mermaidInitialized = false;

      window.addEventListener("exdoc:loaded", () => {
        if (!mermaidInitialized) {
          mermaid.initialize({
            startOnLoad: false,
            theme: document.body.className.includes("dark") ? "dark" : "default"
          });
          mermaidInitialized = true;
        }

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

  defp before_closing_body_tag(_format), do: ""

  defp docs do
    [
      main: "readme",
      assets: %{"docs/maintainers/assets" => "assets"},
      before_closing_body_tag: &before_closing_body_tag/1,
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
          PtcRunner.Kernel.ProjectConfig,
          PtcRunner.Kernel.ReplSession,
          PtcRunner.Kernel.Result,
          PtcRunner.Kernel.RunBuilder,
          PtcRunner.Kernel.RunConfig,
          PtcRunner.Kernel.RunRequest,
          PtcRunner.Kernel.RunAnalysis,
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
          PtcRunner.Kernel.ExecutionOutcome,
          PtcRunner.Kernel.Events,
          PtcRunner.Kernel.JSONValue,
          PtcRunner.Kernel.JSONSchema,
          PtcRunner.Kernel.MCPProtocol,
          PtcRunner.Kernel.Program,
          PtcRunner.Kernel.PublicationAuthority,
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
          PtcRunner.LLM.PreparedModel,
          PtcRunner.LLM.Requirements,
          PtcRunner.LLM.ReqLLMAdapter
        ]
      ],
      extras:
        [
          "README.md",
          "LICENSE",
          "docs/ptc-lisp-specification.md",
          "docs/agent-library-reference.md",
          "docs/clojure-conformance-gaps.md",
          "docs/function-reference.md",
          "docs/java-interop.md",
          "docs/kernel-limits-reference.md",
          "docs/prelude-reference.md",
          "docs/signature-syntax.md",
          "docs/conformance/index.md",
          "docs/guides/quickstart.md",
          "docs/guides/getting-started.md",
          "docs/guides/concepts.md",
          "docs/guides/agent-cli-usage.md",
          "docs/guides/ptc-lisp-basics.md",
          "docs/guides/project-configuration.md",
          "docs/guides/manifests-and-capabilities.md",
          "docs/guides/host-configuration.md",
          "docs/guides/using-models.md",
          "docs/guides/connecting-tools-with-mcp.md",
          "docs/guides/building-agents.md",
          "docs/guides/components-and-preludes.md",
          "docs/guides/designing-agent-workflows.md",
          "docs/guides/agent-workflow-patterns.md",
          "docs/guides/running-and-debugging.md",
          "docs/guides/kernel-repl.md",
          "docs/guides/debugging-a-failed-run.md",
          "docs/guides/evaluating-with-replay.md",
          "docs/installation/standalone.md",
          "docs/installation/docker.md",
          "docs/installation/source.md",
          "docs/reference/application-manifest.md",
          "docs/reference/host-installation.md",
          "docs/reference/project-files.md",
          "docs/reference/component-contracts.md",
          "docs/reference/mcp.md",
          "docs/reference/cli.md",
          "docs/reference/repl.md",
          "docs/reference/debug-navigation.md",
          "docs/maintainers/embedding.md",
          "docs/maintainers/coding-agent-review.md",
          "docs/maintainers/duplication-gate.md",
          "docs/maintainers/guide-budget.md",
          "docs/maintainers/documentation.md",
          "docs/maintainers/signature-integration.md",
          "docs/maintainers/kernel.md",
          "docs/maintainers/trace-log-contract.md"
        ] ++ Path.wildcard("docs/conformance/*-audit.md"),
      groups_for_extras: [
        Start: [
          "docs/guides/quickstart.md",
          "docs/guides/getting-started.md",
          "docs/guides/concepts.md",
          "docs/guides/agent-cli-usage.md"
        ],
        Language: [
          "docs/guides/ptc-lisp-basics.md"
        ],
        Configure: [
          "docs/guides/project-configuration.md",
          "docs/guides/manifests-and-capabilities.md",
          "docs/guides/host-configuration.md"
        ],
        Build: [
          "docs/guides/using-models.md",
          "docs/guides/connecting-tools-with-mcp.md",
          "docs/guides/building-agents.md",
          "docs/guides/components-and-preludes.md"
        ],
        Design: [
          "docs/guides/designing-agent-workflows.md",
          "docs/guides/agent-workflow-patterns.md"
        ],
        "Run and debug": [
          "docs/guides/running-and-debugging.md",
          "docs/guides/kernel-repl.md",
          "docs/guides/debugging-a-failed-run.md",
          "docs/guides/evaluating-with-replay.md"
        ],
        Installation: ~r/docs\/installation\/.+\.md/,
        Reference:
          ~r/docs\/(?:reference\/.+|(?:agent-library|ptc-lisp|clojure|function-reference|java-|kernel-limits|prelude-|signature-).+)\.md/,
        Conformance: ~r/docs\/conformance\/.+\.md/,
        Maintainers:
          ~r/docs\/maintainers\/(coding-agent-review|documentation|duplication-gate|embedding|guide-budget|kernel|signature-integration|trace-log-contract)\.md/
      ]
    ]
  end

  defp package do
    [
      files:
        ~w(lib rel docs examples/kernel-tutorial examples/kernel-inspection-lab examples/llm-replay examples/debug-a-failed-run examples/support-triage site/schemas/mcp-2026-07-28.schema.json .formatter.exs mix.exs README.md usage-rules.md LICENSE LICENSES THIRD_PARTY_NOTICES.md CHANGELOG.md priv/function_audit.exs priv/functions.exs priv/java_interop.exs priv/java_interop_oracle_cases.exs priv/java_interop_oracle_baseline.json priv/java_oracle_versions.exs priv/preludes priv/schemas priv/spec priv/semantic_build_inventory.exs priv/semantic_build_projection.json),
      # Hex expands the directories above from the working tree, not from
      # git, so anything ignored but present -- a `.ptc` run directory left by
      # a tutorial walk, a `.env` beside an example -- is published. Ship no
      # dot-entry the list does not name outright: run traces and private
      # inspection records are local evidence, and a credential file is worse.
      exclude_patterns: [~r{(^|/)\.(?!formatter\.exs$)}],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/andreasronge/ptc_runner",
        "Changelog" => "https://github.com/andreasronge/ptc_runner/blob/main/CHANGELOG.md"
      }
    ]
  end
end
