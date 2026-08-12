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
        plt_add_apps: [:ex_unit, :mix, :req, :req_llm, :llm_db, :recon],
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
      {:jsv, "~> 0.22.0"},
      {:nimble_parsec, "~> 1.4"},
      {:mint, "~> 1.9"},
      {:req, "~> 0.6.3"},
      {:telemetry, "~> 1.0"},
      {:stream_data, "~> 1.1", only: [:test, :dev]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      ex_dna_dep(),
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:req_llm, "~> 1.19", optional: true, runtime: false},
      launcher_dep(),
      {:ptc_viewer, path: "ptc_viewer", only: [:test, :dev]},
      {:usage_rules, "~> 1.2", only: :dev, runtime: false},
      {:recon, "~> 2.5", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: [:dev, :test], runtime: false}
    ]
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

  defp aliases do
    [
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "xref graph --format cycles --label compile-connected --fail-above 0",
        "credo --strict",
        "cmd bash scripts/duplication_gate.sh check",
        "ptc.validate_spec",
        "ptc.gen_docs --check",
        "ptc.conformance_report --check-inventory",
        "test --warnings-as-errors",
        "cmd --cd ptc_viewer mix test --color",
        "cmd --cd ptc_runner_launcher mix precommit",
        "cmd bash scripts/verify_core_package.sh",
        "cmd bash scripts/verify_standalone_release.sh"
      ],
      # Slower checks kept out of the per-commit loop; run before pushing.
      # PR CI runs these as individual steps. The upstream audit attests all
      # exact Java descriptors when Java 11 or newer is available.
      #
      # The two staleness checks are also in `precommit`, and are repeated
      # here on purpose. A generated artifact goes stale from an ordinary edit
      # to the sources it projects, `AGENTS.md` tells you not to run `precommit`
      # before an ordinary push because the hook already gates it, and the hook
      # runs the suite and this alias rather than `precommit`. Without them a
      # push that touches `lib/` clears every local gate and still fails CI on
      # an artifact the author never had a chance to regenerate. They cost a few
      # seconds inside a run that already spends minutes.
      #
      # `ptc.gen_semantic_revision --check` is deliberately absent from both:
      # it is a release gate, not a per-commit one. See `.gitattributes`.
      prepush: [
        # Credo is repeated here for the same reason as the staleness checks
        # below: the hook runs this alias, not `precommit`, so without it a
        # lint the CI Credo step rejects only surfaces after the push.
        "credo --strict",
        "ptc.gen_docs --check",
        "ptc.conformance_report --check-inventory",
        "ptc.audit_upstream",
        "dialyzer",
        "deps.unlock --check-unused"
      ],
      coverage: [
        "test --cover"
      ],
      # Tests costing tens of seconds each. Excluded from `mix test` by default
      # (test/test_helper.exs); the `Nightly` workflow runs them. `--trace` is
      # retained here and only here: these tests exceed the default 60 s
      # per-test timeout, and trace mode sets the timeout to `:infinity`.
      # Everywhere else `--trace` is a bug -- it pins `--max-cases` to 1.
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

  defp releases do
    [
      ptc_runner: [
        include_erts: true,
        applications: [req_llm: :load],
        overlays: ["rel/overlays"]
      ]
    ]
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
      assets: %{"docs/guides/assets" => "assets"},
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
          "docs/guides/quickstart.md",
          "docs/guides/getting-started.md",
          "docs/guides/manifests-and-capabilities.md",
          "docs/guides/host-configuration.md",
          "docs/guides/building-agents.md",
          "docs/guides/running-and-debugging.md",
          "docs/guides/kernel-repl.md",
          "docs/guides/components-and-preludes.md",
          "docs/guides/embedding-in-elixir.md",
          "docs/guides/coding-agent-review-workflow.md",
          "docs/guides/duplication-gate.md",
          "docs/guides/documentation-guidelines.md",
          "docs/guides/kernel-maintainer.md"
        ] ++ Path.wildcard("docs/conformance/*-audit.md"),
      groups_for_extras: [
        Maintainers:
          ~r/docs\/guides\/(coding-agent-review-workflow|documentation-guidelines|duplication-gate|kernel-maintainer)\.md/,
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
        ~w(lib rel docs examples/kernel-tutorial examples/kernel-inspection-lab .formatter.exs mix.exs README.md LICENSE CHANGELOG.md priv/function_audit.exs priv/functions.exs priv/java_interop.exs priv/java_interop_oracle_cases.exs priv/java_interop_oracle_baseline.json priv/java_oracle_versions.exs priv/preludes priv/schemas priv/spec priv/semantic_build_inventory.exs priv/semantic_build_projection.json),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/andreasronge/ptc_runner",
        "Changelog" => "https://github.com/andreasronge/ptc_runner/blob/main/CHANGELOG.md"
      }
    ]
  end
end
