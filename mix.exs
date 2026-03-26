defmodule PtcRunner.MixProject do
  use Mix.Project

  def project do
    [
      app: :ptc_runner,
      version: "0.10.0",
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
        ignore_modules: [PtcRunner.TestSupport.TestLLM]
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
      {:req_llm, "~> 1.8", optional: true},
      {:kino, "~> 0.14", optional: true},
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
      groups_for_modules: [
        Core: [
          PtcRunner,
          PtcRunner.Context,
          PtcRunner.Step,
          PtcRunner.Tool,
          PtcRunner.Schema,
          PtcRunner.Sandbox,
          PtcRunner.Template,
          PtcRunner.Mustache,
          PtcRunner.Chunker,
          PtcRunner.Dotenv,
          PtcRunner.Turn
        ],
        SubAgent: [
          PtcRunner.SubAgent,
          PtcRunner.SubAgent.Compiler,
          PtcRunner.SubAgent.CompiledAgent,
          PtcRunner.SubAgent.Definition,
          PtcRunner.SubAgent.Chaining,
          PtcRunner.SubAgent.Loop,
          PtcRunner.SubAgent.Loop.Budget,
          PtcRunner.SubAgent.Loop.JsonHandler,
          PtcRunner.SubAgent.Loop.LlmRetry,
          PtcRunner.SubAgent.Loop.Metrics,
          PtcRunner.SubAgent.Loop.ResponseHandler,
          PtcRunner.SubAgent.Loop.ReturnValidation,
          PtcRunner.SubAgent.Loop.State,
          PtcRunner.SubAgent.Loop.StepAssembler,
          PtcRunner.SubAgent.Loop.TextMode,
          PtcRunner.SubAgent.Loop.ToolNormalizer,
          PtcRunner.SubAgent.Loop.TurnFeedback,
          PtcRunner.SubAgent.Compression,
          PtcRunner.SubAgent.Compression.SingleUserCoalesced,
          PtcRunner.SubAgent.Debug,
          PtcRunner.SubAgent.Error,
          PtcRunner.SubAgent.JsonParser,
          PtcRunner.SubAgent.KeyNormalizer,
          PtcRunner.SubAgent.LlmResolver,
          PtcRunner.SubAgent.ProgressRenderer,
          PtcRunner.SubAgent.PromptExpander,
          PtcRunner.SubAgent.Validator
        ],
        "SubAgent — Signatures": [
          PtcRunner.SubAgent.Signature,
          PtcRunner.SubAgent.Signature.Coercion,
          PtcRunner.SubAgent.Signature.Parser,
          PtcRunner.SubAgent.Signature.ParserHelpers,
          PtcRunner.SubAgent.Signature.Renderer,
          PtcRunner.SubAgent.Signature.TypeResolver,
          PtcRunner.SubAgent.Signature.Validator,
          PtcRunner.SubAgent.TypeExtractor,
          PtcRunner.SubAgent.Sigils
        ],
        "SubAgent — Prompts & Tools": [
          PtcRunner.SubAgent.SystemPrompt,
          PtcRunner.SubAgent.SystemPrompt.Output,
          PtcRunner.SubAgent.Namespace,
          PtcRunner.SubAgent.Namespace.Data,
          PtcRunner.SubAgent.Namespace.ExecutionHistory,
          PtcRunner.SubAgent.Namespace.Tool,
          PtcRunner.SubAgent.Namespace.TypeVocabulary,
          PtcRunner.SubAgent.Namespace.User,
          PtcRunner.SubAgent.BuiltinTools,
          PtcRunner.SubAgent.LlmTool,
          PtcRunner.SubAgent.SubAgentTool,
          PtcRunner.SubAgent.ToolSchema,
          PtcRunner.SubAgent.Telemetry,
          PtcRunner.Prompts,
          PtcRunner.PromptLoader
        ],
        "PTC-Lisp": [
          PtcRunner.Lisp,
          PtcRunner.Lisp.Parser,
          PtcRunner.Lisp.ParserHelpers,
          PtcRunner.Lisp.Analyze,
          PtcRunner.Lisp.Analyze.Conditionals,
          PtcRunner.Lisp.Analyze.Definitions,
          PtcRunner.Lisp.Analyze.Iteration,
          PtcRunner.Lisp.Analyze.Patterns,
          PtcRunner.Lisp.Analyze.Predicates,
          PtcRunner.Lisp.Analyze.ShortFn,
          PtcRunner.Lisp.AST,
          PtcRunner.Lisp.CoreAst,
          PtcRunner.Lisp.CoreToSource,
          PtcRunner.Lisp.Env,
          PtcRunner.Lisp.LanguageSpec,
          PtcRunner.Lisp.Registry,
          PtcRunner.Lisp.SpecValidator,
          PtcRunner.Lisp.ClojureValidator,
          PtcRunner.Lisp.DataKeys,
          PtcRunner.Lisp.SymbolCounter,
          PtcRunner.Lisp.Formatter
        ],
        "PTC-Lisp — Evaluation": [
          PtcRunner.Lisp.Eval,
          PtcRunner.Lisp.Eval.Apply,
          PtcRunner.Lisp.Eval.Context,
          PtcRunner.Lisp.Eval.Helpers,
          PtcRunner.Lisp.Eval.Patterns,
          PtcRunner.Lisp.Eval.Where,
          PtcRunner.Lisp.Runtime,
          PtcRunner.Lisp.Runtime.Callable,
          PtcRunner.Lisp.Runtime.Collection,
          PtcRunner.Lisp.Runtime.Collection.Normalize,
          PtcRunner.Lisp.Runtime.Collection.Select,
          PtcRunner.Lisp.Runtime.Collection.Transform,
          PtcRunner.Lisp.Runtime.FlexAccess,
          PtcRunner.Lisp.Runtime.Interop,
          PtcRunner.Lisp.Runtime.MapOps,
          PtcRunner.Lisp.Runtime.Math,
          PtcRunner.Lisp.Runtime.Predicates,
          PtcRunner.Lisp.Runtime.Regex,
          PtcRunner.Lisp.Runtime.SpecialValues,
          PtcRunner.Lisp.Runtime.String,
          PtcRunner.Lisp.ExecutionError,
          PtcRunner.Lisp.ToolExecutionError,
          PtcRunner.Lisp.TypeError
        ],
        LLM: [
          PtcRunner.LLM,
          PtcRunner.LLM.Registry,
          PtcRunner.LLM.DefaultRegistry,
          PtcRunner.LLM.ReqLLMAdapter
        ],
        Observability: [
          PtcRunner.Tracer,
          PtcRunner.Tracer.Timeline,
          PtcRunner.TraceContext,
          PtcRunner.TraceLog,
          PtcRunner.TraceLog.Analyzer,
          PtcRunner.TraceLog.Collector,
          PtcRunner.TraceLog.Event,
          PtcRunner.TraceLog.Handler,
          PtcRunner.Metrics.Statistics,
          PtcRunner.Metrics.TurnAnalysis,
          PtcRunner.Kino.TraceTree
        ]
      ],
      extras: [
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
        # SubAgent Guides (learning path)
        "docs/guides/subagent-getting-started.md",
        "docs/guides/subagent-llm-setup.md",
        "docs/guides/subagent-text-mode.md",
        "docs/guides/subagent-concepts.md",
        "docs/guides/subagent-patterns.md",
        "docs/guides/subagent-navigator.md",
        "docs/guides/subagent-rlm-patterns.md",
        "docs/guides/subagent-testing.md",
        "docs/guides/subagent-troubleshooting.md",
        "docs/guides/subagent-observability.md",
        "docs/guides/subagent-compression.md",
        "docs/guides/subagent-advanced.md",
        "docs/guides/subagent-prompts.md",
        # Integration Guides
        "docs/guides/phoenix-streaming.md",
        "docs/guides/structured-output-callbacks.md",
        # Reference
        "docs/signature-syntax.md",
        "docs/benchmark-eval.md",
        # PTC-Lisp
        "docs/ptc-lisp-specification.md",
        "docs/clojure-conformance-gaps.md",
        # Generated Reference (mix ptc.gen_docs)
        "docs/function-reference.md",
        "docs/clojure-core-audit.md",
        "docs/clojure-string-audit.md",
        "docs/clojure-set-audit.md",
        "docs/java-math-audit.md",
        "docs/java-interop.md",
        # Livebooks
        "livebooks/ptc_runner_playground.livemd",
        "livebooks/ptc_runner_llm_agent.livemd",
        "livebooks/joke_workflow.livemd",
        "livebooks/observability_and_tracing.livemd"
      ],
      groups_for_extras: [
        "SubAgent Guides": ~r/docs\/guides\/subagent-.+\.md/,
        "Integration Guides": ~r/docs\/guides\/(phoenix-|structured-).+\.md/,
        Reference:
          ~r/docs\/(signature-syntax|benchmark-eval|ptc-lisp-.+|clojure-.+|function-reference|java-.+|reference\/.+)\.md/,
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
