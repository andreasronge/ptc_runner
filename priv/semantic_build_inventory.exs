%{
  semantic_roots: [
    %{
      root: "lib/ptc_runner",
      exclusions: [
        "lib/ptc_runner/kernel/command_arguments.ex",
        "lib/ptc_runner/kernel/command_contract.ex",
        "lib/ptc_runner/kernel/command_contract_authority.ex",
        "lib/ptc_runner/kernel/command_diagnostic.ex",
        "lib/ptc_runner/kernel/command_engine.ex",
        "lib/ptc_runner/kernel/command_outcome.ex",
        "lib/ptc_runner/kernel/command_parser.ex",
        "lib/ptc_runner/kernel/command_path.ex",
        "lib/ptc_runner/kernel/command_preparation.ex",
        "lib/ptc_runner/kernel/command_run_ref.ex",
        "lib/ptc_runner/kernel/command_source.ex",
        "lib/ptc_runner/kernel/command_subject.ex",
        "lib/ptc_runner/kernel/diagnostic_catalog.ex",
        "lib/ptc_runner/kernel/value_contract_classification.ex"
      ]
    }
  ],
  semantic_files: [
    "lib/ptc_runner.ex",
    "mix.exs",
    "priv/function_audit.exs",
    "priv/functions.exs",
    "priv/java_interop.exs",
    "priv/shipped_export_owners.json",
    "priv/schemas/mcp-input-request-2026-07-28.schema.json"
  ],
  conditional_semantic_modules: [
    PtcRunner.LLM.ReqLLMAdapter
  ],
  runtime_dependency_roots: [
    :jason,
    :jsv,
    :mint,
    :nimble_parsec,
    :ptc_runner_launcher,
    :req,
    :req_llm,
    :telemetry
  ],
  runtime_dependencies: [
    :abnf_parsec,
    :dotenvy,
    :finch,
    :hpax,
    :idna,
    :jason,
    :jsv,
    :llm_db,
    :mime,
    :mint,
    :nimble_options,
    :nimble_parsec,
    :nimble_pool,
    :ptc_runner_launcher,
    :req,
    :req_llm,
    :server_sent_events,
    :splode,
    :telemetry,
    :texture,
    :toml,
    :websockex,
    :zoi
  ],
  path_dependencies: %{
    ptc_runner_launcher: %{
      root: "ptc_runner_launcher",
      version_file: "ptc_runner_launcher/release_config.exs",
      semantic_roots: [
        %{
          root: "ptc_runner_launcher",
          exclusions: [
            "ptc_runner_launcher/.formatter.exs",
            "ptc_runner_launcher/.gitignore",
            "ptc_runner_launcher/CHANGELOG.md",
            "ptc_runner_launcher/LICENSE",
            "ptc_runner_launcher/README.md",
            "ptc_runner_launcher/_build",
            "ptc_runner_launcher/checksum.exs",
            "ptc_runner_launcher/cover",
            "ptc_runner_launcher/deps",
            "ptc_runner_launcher/doc",
            "ptc_runner_launcher/erl_crash.dump",
            "ptc_runner_launcher/ptc_runner_launcher-*.tar",
            "ptc_runner_launcher/test",
            "ptc_runner_launcher/tmp"
          ]
        }
      ]
    }
  }
}
