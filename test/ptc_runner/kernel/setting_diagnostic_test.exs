defmodule PtcRunner.Kernel.SettingDiagnosticTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.AgentConfigDiagnostic
  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.DiagnosticCatalog
  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.ModelOutputDiagnostic
  alias PtcRunner.Kernel.OptionalBudgetDiagnostic
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.Kernel.SchemaViolationDiagnostic

  # Catalog rows whose dynamic message describes a document, a fixture, or a
  # contract rule rather than a setting the caller chose. Listed so the sweep
  # below stays a catalog walk instead of a hand-picked sample: a new dynamic
  # message has to land in one list or the other.
  @prose_rows [
    {:application, :contract_invalid},
    {:application, :override_invalid},
    {:application, :required_property_missing},
    {:application, :schema_violation},
    {:bundle, :duplicate_definition},
    {:bundle, :undefined_variable},
    {:bundle, :unknown_namespace},
    {:execution, :replay_fixture_missing},
    {:execution, :model_output_truncated},
    {:host, :host_schema_invalid},
    {:host, :installed_limit_invalid},
    {:local_preflight, :environment_unavailable},
    {:local_preflight, :fixtures_unreadable},
    {:project, :project_schema_invalid},
    {:provider_acquisition, :capability_requirement_missing},
    {:provider_acquisition, :provider_protocol_version_unsupported},
    {:provider_acquisition, :provider_tool_missing},
    {:provider_declaration, :selection_invalid},
    {:result_cleanup, :result_contract_failed}
  ]

  test "model output truncation messages retain tied bindings and reject suffixes" do
    details = %{
      limit: :max_tokens,
      limit_value: 4_096,
      limit_bindings: [:adapter_default, :model_output_limit],
      alias: "hy3"
    }

    assert {:ok, message} = ModelOutputDiagnostic.message(details)
    assert message =~ "adapter_default and model_output_limit max_tokens 4096"
    assert message =~ "Select a model with a larger output limit"
    assert ModelOutputDiagnostic.valid_message?(message)
    refute ModelOutputDiagnostic.valid_message?(message <> "\n")
  end

  test "model output truncation uses the stable generic message without cap provenance" do
    assert {:ok, message} = ModelOutputDiagnostic.message(%{alias: "hy3"})
    assert message == "model output was truncated before producing a usable agent action"
    assert ModelOutputDiagnostic.valid_message?(message)
  end

  test "every breached setting names the setting, its configured value, and a remedy" do
    for row <- setting_rows() do
      assert {:ok, message} = row.build.()

      assert message =~ row.setting,
             "#{row.phase}/#{row.code} does not name #{row.setting}: #{message}"

      assert message =~ row.value,
             "#{row.phase}/#{row.code} does not report #{row.value}: #{message}"

      assert message =~ row.remedy,
             "#{row.phase}/#{row.code} does not carry its remedy: #{message}"
    end
  end

  # `DiagnosticPattern` publishes each of these messages as an exact JSON Schema
  # pattern, and a message edited without its branch stops validating — the
  # command then falls back to the catalog sentence without saying so. Each row
  # is therefore built, validated, admitted, rendered, and matched against the
  # published schema, then mutated by one byte to prove the pattern is keyed to
  # this exact text rather than to a prefix.
  test "every setting message survives its own validator, admission, and published schema" do
    assert {:ok, schema} =
             JSV.build(CommandContract.catalog_diagnostic_schema(),
               atoms: false,
               warnings: :silent
             )

    for row <- setting_rows() do
      {:ok, message} = row.build.()
      catalog_row = DiagnosticCatalog.fetch!(row.phase, row.code)

      assert catalog_row.message != message
      assert DiagnosticCatalog.valid_message?(row.phase, row.code, message)
      refute DiagnosticCatalog.valid_message?(row.phase, row.code, message <> ".")

      assert {:ok, diagnostic} =
               CommandDiagnostic.new(row.phase, row.code, diagnostic_opts(row, message))

      rendered = CommandDiagnostic.to_map(diagnostic)
      assert rendered["message"] == message
      assert {:ok, _validated} = JSV.validate(rendered, schema, cast: false)

      assert {:error, _appended} =
               JSV.validate(Map.put(rendered, "message", message <> "."), schema, cast: false)

      assert {:error, :invalid_command_diagnostic} =
               CommandDiagnostic.new(row.phase, row.code, diagnostic_opts(row, message <> "."))
    end
  end

  # The Live card reads the terminal error's details, not the command envelope.
  # Every breach the command can name has to be nameable there too, or the card
  # falls back to a bare reason atom for a ceiling that knows its own name.
  test "every runtime limit detail shape resolves to its setting and message" do
    details = [
      {%{limit: :run_duration_ms, limit_ms: 120_000, phase: :execution}, "run_duration_ms"},
      {%{limit: :workflow_timeout_ms, limit_ms: 120_000, phase: :compilation},
       "workflow_timeout_ms"},
      {%{limit: :parallel_timeout_ms, limit_ms: 60_000, phase: :execution},
       "parallel_timeout_ms"},
      {%{limit: :evaluation_timeout_ms, limit_ms: 30_000, phase: :execution},
       "evaluation_timeout_ms"},
      {%{limit: :subordinate_evaluations, limit_value: 128}, "subordinate_evaluations"},
      {%{limit: :agent_turns, limit_value: 4, limit_reason: :turn_limit_exceeded}, "max_turns"},
      {%{limit: :max_transcript_chars, limit_value: 262_144}, "max_transcript_chars"},
      {%{limit: :terminal_result_bytes, limit_value: 1_000_000}, "terminal_result_bytes"},
      {%{limit: :workflow_heap_words, limit_value: 8_000_000}, "workflow_heap_words"},
      {%{limit: :max_calls, alias: "deepseek", limit_value: 4}, "max_calls"},
      {%{limit: :workflow_capability_calls_per_name, name: "llm-request", limit_value: 2},
       "workflow_capability_calls_per_name"},
      {%{limit: :protocol_errors, limit_value: 64}, "protocol_errors"},
      {%{limit: :llm_total_tokens, limit_value: 1, requested: 4_096, remaining: 1},
       "llm_total_tokens"},
      {%{limit: :llm_cost_microusd, limit_value: 2_400, requested: 2_419, remaining: 2_338},
       "llm_cost_microusd"}
    ]

    for {detail, expected_limit} <- details do
      assert {:ok, ^expected_limit, message} = RuntimeLimitDiagnostic.details_message(detail)
      assert message =~ expected_limit
    end

    assert :error = RuntimeLimitDiagnostic.details_message(%{})
    assert :error = RuntimeLimitDiagnostic.details_message(%{failure_kind: "invalid-input"})
    assert :error = RuntimeLimitDiagnostic.details_message(%{limit: :agent_turns, limit_value: 4})

    assert :error =
             RuntimeLimitDiagnostic.details_message(%{
               limit: :run_duration_ms,
               limit_ms: 0,
               phase: :execution
             })
  end

  test "every catalog row with a dynamic message either names a setting or is listed as prose" do
    dynamic =
      DiagnosticCatalog.rows()
      |> Enum.filter(&(DiagnosticCatalog.message_schema(&1) != %{"const" => &1.message}))
      |> Enum.map(&{&1.phase, &1.code})
      |> Enum.sort()

    covered =
      setting_rows()
      |> Enum.map(&{&1.phase, &1.code})
      |> Enum.concat(@prose_rows)
      |> Enum.uniq()
      |> Enum.sort()

    assert dynamic == covered
  end

  test "application schema diagnostics refuse rules its schema cannot produce" do
    for {rule, message} <- [
          {:contains, "the application manifest violates the contains schema rule"},
          {:duplicate_property, "the application manifest contains a duplicate property"},
          {:not, "the application manifest violates the not schema rule"}
        ] do
      assert :error = SchemaViolationDiagnostic.message(:application, rule)
      refute DiagnosticCatalog.valid_message?(:application, :schema_violation, message)

      assert {:error, :invalid_command_diagnostic} =
               CommandDiagnostic.new(:application, :schema_violation,
                 source: CommandSource.fixed(:application),
                 message: message
               )
    end
  end

  test "project schema diagnostics refuse rules its schema cannot produce" do
    for {rule, message} <- [
          {:contains, "the project configuration violates the contains schema rule"},
          {:one_of, "the project configuration violates the oneOf schema rule"},
          {:unique_items, "the project configuration violates the uniqueItems schema rule"}
        ] do
      assert :error = SchemaViolationDiagnostic.message(:project, rule)
      refute DiagnosticCatalog.valid_message?(:project, :project_schema_invalid, message)

      assert {:error, :invalid_command_diagnostic} =
               CommandDiagnostic.new(:project, :project_schema_invalid,
                 source: CommandSource.fixed(:project),
                 message: message
               )
    end
  end

  # The published schema concatenates two independent integer groups and cannot
  # express `requested > ceiling`. That is deliberate: every dynamic message is
  # a regex superset of what the constructor will admit. Pin the asymmetry so a
  # later edit cannot loosen the runtime validator to match the schema.
  test "the published installed-ceiling schema accepts text the constructor refuses" do
    assert {:ok, schema} =
             JSV.build(CommandContract.catalog_diagnostic_schema(),
               atoms: false,
               warnings: :silent
             )

    assert :error = RuntimeLimitDiagnostic.installed_ceiling_message("run_duration_ms", 1, 2)

    assert {:ok, producible} =
             RuntimeLimitDiagnostic.installed_ceiling_message("run_duration_ms", 2, 1)

    assert {:ok, diagnostic} =
             CommandDiagnostic.new(:application, :installed_limit_exceeded,
               message: producible,
               source: CommandSource.fixed(:application),
               provider_activity: false
             )

    inverted =
      "run_duration_ms 1 exceeds the installed ceiling 2; lower the manifest value to at most the ceiling, or raise the ceiling in the host document"

    rendered = CommandDiagnostic.to_map(diagnostic)
    assert {:ok, _validated} = JSV.validate(rendered, schema, cast: false)

    assert {:ok, _schema_superset} =
             JSV.validate(Map.put(rendered, "message", inverted), schema, cast: false)

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:application, :installed_limit_exceeded,
               message: inverted,
               source: CommandSource.fixed(:application),
               provider_activity: false
             )
  end

  test "optional-budget messages enforce cataloged names, prerequisites, values, and suffixes" do
    assert {:ok, schema} =
             JSV.build(CommandContract.catalog_diagnostic_schema(),
               atoms: false,
               warnings: :silent
             )

    for row <- LimitCatalog.rows(:optional_manifest_narrowable),
        requested <- [row.minimum, row.maximum] do
      assert {:ok, message} = OptionalBudgetDiagnostic.unavailable_message(row.name, requested)
      assert OptionalBudgetDiagnostic.valid_unavailable_message?(message)

      assert {:ok, diagnostic} =
               CommandDiagnostic.new(:application, :limit_unavailable,
                 source: CommandSource.fixed(:application),
                 message: message
               )

      rendered = CommandDiagnostic.to_map(diagnostic)
      assert {:ok, _validated} = JSV.validate(rendered, schema, cast: false)

      for malformed <- [message <> ".", message <> " private-value"] do
        refute OptionalBudgetDiagnostic.valid_unavailable_message?(malformed)
        assert {:error, _invalid} = JSV.validate(Map.put(rendered, "message", malformed), schema)
      end
    end

    assert :error = OptionalBudgetDiagnostic.unavailable_message("caller-secret", 1)
    assert :error = OptionalBudgetDiagnostic.unavailable_message("llm_total_tokens", 0)
    assert :error = OptionalBudgetDiagnostic.unavailable_message("llm_total_tokens", nil)

    assert :error =
             OptionalBudgetDiagnostic.unavailable_message(
               "llm_total_tokens",
               9_007_199_254_740_992
             )

    oversized =
      "llm_total_tokens " <>
        String.duplicate("9", 100_000) <>
        " is unavailable because the host has not enabled it; enable llm_total_tokens in the host document before declaring it in the manifest"

    refute OptionalBudgetDiagnostic.valid_unavailable_message?(oversized)

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:application, :limit_unavailable,
               source: CommandSource.fixed(:application),
               message: oversized
             )

    for row <- LimitCatalog.rows(:optional_manifest_narrowable),
        prerequisite <- row.prerequisites do
      assert {:ok, message} =
               OptionalBudgetDiagnostic.prerequisite_message(row.name, prerequisite)

      assert OptionalBudgetDiagnostic.valid_prerequisite_message?(message)

      assert {:ok, diagnostic} =
               CommandDiagnostic.new(:host, :installed_limit_invalid,
                 source: CommandSource.fixed(:host),
                 message: message
               )

      rendered = CommandDiagnostic.to_map(diagnostic)
      assert {:ok, _validated} = JSV.validate(rendered, schema, cast: false)
      refute OptionalBudgetDiagnostic.valid_prerequisite_message?(message <> ".")

      assert {:error, _invalid} =
               JSV.validate(Map.put(rendered, "message", message <> "."), schema)
    end

    assert :error = OptionalBudgetDiagnostic.prerequisite_message("caller-secret", :usage_tokens)

    assert :error =
             OptionalBudgetDiagnostic.prerequisite_message(
               "llm_total_tokens",
               :reservation_tariff
             )
  end

  # Unlike the installed-ceiling regex, these branches can name the accepted
  # range, so an in-range or overflowing integer must fail both the constructor
  # and the published schema — otherwise `CommandDiagnostic.new/3` would admit
  # "max_turns 4 is outside 1–128".
  test "an in-range or overflowing agent option is not an invalid_agent_config message" do
    assert {:ok, schema} =
             JSV.build(CommandContract.catalog_diagnostic_schema(),
               atoms: false,
               warnings: :silent
             )

    {:ok, producible} = AgentConfigDiagnostic.integer_message("max_turns", 1, 128, 129)

    assert {:ok, diagnostic} =
             CommandDiagnostic.new(
               :execution,
               :invalid_agent_config,
               diagnostic_opts(
                 %{phase: :execution, code: :invalid_agent_config, source: nil},
                 producible
               )
             )

    rendered = CommandDiagnostic.to_map(diagnostic)

    for {option, minimum, maximum} <- AgentConfigDiagnostic.options() do
      {:ok, out_of_range} =
        AgentConfigDiagnostic.integer_message(option, minimum, maximum, maximum + 1)

      in_range =
        String.replace(
          out_of_range,
          Integer.to_string(maximum + 1),
          Integer.to_string(minimum),
          global: false
        )

      overflow =
        String.replace(
          out_of_range,
          Integer.to_string(maximum + 1),
          "9223372036854775808",
          global: false
        )

      refute AgentConfigDiagnostic.valid_message?(in_range),
             "#{option} in-range sentence was admitted: #{in_range}"

      refute AgentConfigDiagnostic.valid_message?(overflow),
             "#{option} overflow sentence was admitted: #{overflow}"

      assert {:error, :invalid_command_diagnostic} =
               CommandDiagnostic.new(
                 :execution,
                 :invalid_agent_config,
                 diagnostic_opts(
                   %{phase: :execution, code: :invalid_agent_config, source: nil},
                   in_range
                 )
               )

      assert {:error, _in_range} =
               JSV.validate(Map.put(rendered, "message", in_range), schema, cast: false)

      assert {:error, _overflow} =
               JSV.validate(Map.put(rendered, "message", overflow), schema, cast: false)
    end

    int64_max = 9_223_372_036_854_775_807
    {:ok, max_message} = AgentConfigDiagnostic.integer_message("max_turns", 1, 128, int64_max)
    assert AgentConfigDiagnostic.valid_message?(max_message)

    assert {:ok, _int64_max} =
             JSV.validate(Map.put(rendered, "message", max_message), schema, cast: false)
  end

  defp setting_rows do
    limit_rows() ++ agent_turn_rows() ++ agent_config_rows()
  end

  # Every ceiling a run can breach, with the setting it must name, the
  # configured value it must quote, and the remedy that says what to change —
  # the three things `max_turns` supplied and the rest of the family did not.
  defp limit_rows do
    [
      %{
        phase: :execution,
        code: :runtime_limit_exceeded,
        source: :runtime,
        setting: "subordinate_evaluations",
        value: "16",
        remedy: "raise limits.subordinate_evaluations in the manifest",
        build: fn -> RuntimeLimitDiagnostic.subordinate_evaluations_message(16) end
      },
      %{
        phase: :execution,
        code: :runtime_limit_exceeded,
        source: :runtime,
        setting: "evaluation_timeout_ms",
        value: "1000",
        remedy: "raise limits.evaluation_timeout_ms in the manifest",
        build: fn ->
          RuntimeLimitDiagnostic.timeout_message(:evaluation_timeout_ms, 1_000, :execution)
        end
      },
      %{
        phase: :execution,
        code: :runtime_limit_exceeded,
        source: :runtime,
        setting: "workflow_timeout_ms",
        value: "30000",
        remedy: "raise limits.workflow_timeout_ms in the manifest",
        build: fn ->
          RuntimeLimitDiagnostic.timeout_message(:workflow_timeout_ms, 30_000, :compilation)
        end
      },
      %{
        phase: :execution,
        code: :runtime_limit_exceeded,
        source: :runtime,
        setting: "parallel_timeout_ms",
        value: "30000",
        remedy: "raise limits.parallel_timeout_ms in the manifest",
        build: fn ->
          RuntimeLimitDiagnostic.timeout_message(:parallel_timeout_ms, 30_000, :execution)
        end
      },
      %{
        phase: :execution,
        code: :run_timeout,
        source: :runtime,
        setting: "run_duration_ms",
        value: "30000",
        remedy: "raise limits.run_duration_ms in the manifest",
        build: fn ->
          RuntimeLimitDiagnostic.live_timeout_message(:run_duration_ms, 30_000, :execution)
        end
      },
      %{
        phase: :execution,
        code: :runtime_limit_exceeded,
        source: nil,
        setting: "max_transcript_chars",
        value: "262144",
        remedy: "raise max_transcript_chars for this agent.core/run call",
        build: fn -> RuntimeLimitDiagnostic.transcript_chars_message(262_144) end
      },
      %{
        phase: :execution,
        code: :runtime_limit_exceeded,
        source: :runtime,
        setting: "workflow_heap_words",
        value: "8000000",
        remedy: "raise limits.workflow_heap_words in the manifest",
        build: fn -> RuntimeLimitDiagnostic.heap_words_message(8_000_000) end
      },
      %{
        phase: :execution,
        code: :capability_quota_exceeded,
        source: :runtime,
        setting: "max_calls",
        value: "4",
        remedy: "raise config.max_calls for this model alias",
        build: fn -> RuntimeLimitDiagnostic.max_calls_message("deepseek", 4) end
      },
      %{
        phase: :execution,
        code: :capability_quota_exceeded,
        source: :runtime,
        setting: "workflow_capability_calls_per_name",
        value: "2",
        remedy: "raise limits.workflow_capability_calls_per_name in the manifest",
        build: fn ->
          RuntimeLimitDiagnostic.capability_quota_message(
            :workflow_capability_calls_per_name,
            "llm-request",
            2
          )
        end
      },
      %{
        phase: :execution,
        code: :runtime_limit_exceeded,
        source: :runtime,
        setting: "protocol_errors",
        value: "64",
        remedy: "raise limits.protocol_errors in the manifest",
        build: fn -> RuntimeLimitDiagnostic.protocol_errors_message(64) end
      },
      %{
        phase: :execution,
        code: :runtime_limit_exceeded,
        source: :runtime,
        setting: "llm_total_tokens",
        value: "1",
        remedy: "raise limits.llm_total_tokens in the manifest",
        build: fn -> RuntimeLimitDiagnostic.budget_message(:llm_total_tokens, 1, 4_096, 1) end
      },
      %{
        phase: :execution,
        code: :runtime_limit_exceeded,
        source: :runtime,
        setting: "llm_cost_microusd",
        value: "2400",
        remedy: "raise limits.llm_cost_microusd in the manifest",
        build: fn ->
          RuntimeLimitDiagnostic.budget_message(:llm_cost_microusd, 2_400, 2_419, 2_338)
        end
      },
      %{
        phase: :result_cleanup,
        code: :result_limit_exceeded,
        source: nil,
        setting: "terminal_result_bytes",
        value: "1000000",
        remedy: "raise limits.terminal_result_bytes in the manifest",
        build: fn -> RuntimeLimitDiagnostic.result_limit_message(1_000_000) end
      },
      # Not a breach at all: the refusal a manifest gets for asking above the
      # installed ceiling. It belongs here because it is the one message that
      # tells a reader how to raise a limit, so it must name the same three
      # things.
      %{
        phase: :application,
        code: :installed_limit_exceeded,
        source: :application,
        setting: "workflow_capability_calls_per_name",
        value: "4096",
        remedy: "lower the manifest value to at most the ceiling",
        build: fn ->
          RuntimeLimitDiagnostic.installed_ceiling_message(
            "workflow_capability_calls_per_name",
            4_096,
            2_048
          )
        end
      },
      %{
        phase: :application,
        code: :limit_unavailable,
        source: :application,
        setting: "llm_total_tokens",
        value: "5000",
        remedy: "enable llm_total_tokens in the host document",
        build: fn -> OptionalBudgetDiagnostic.unavailable_message("llm_total_tokens", 5_000) end
      }
    ]
  end

  # The agent loop reports why it stopped, and only three of its five reasons
  # are answered by buying turns. Each still names `max_turns` and the
  # configured count; only the remedy differs.
  defp agent_turn_rows do
    remedies = [
      {:turn_limit_exceeded, "raise max_turns in the agent configuration"},
      {:intermediate_result, "raise max_turns in the agent configuration"},
      {:evaluation_error, "raise max_turns in the agent configuration"},
      {:protocol_error, "raising max_turns repeats it"},
      {:terminal_source_required, "raising max_turns only helps"}
    ]

    assert Enum.map(remedies, &elem(&1, 0)) |> Enum.sort() ==
             Enum.sort(RuntimeLimitDiagnostic.agent_turns_reasons())

    for {reason, remedy} <- remedies do
      %{
        phase: :execution,
        code: :turn_limit_exceeded,
        source: nil,
        setting: "max_turns",
        value: "4",
        remedy: remedy,
        build: fn -> RuntimeLimitDiagnostic.agent_turns_message(4, reason) end
      }
    end
  end

  defp agent_config_rows do
    integer_rows =
      for {option, minimum, maximum} <- AgentConfigDiagnostic.options() do
        value = maximum + 1

        %{
          phase: :execution,
          code: :invalid_agent_config,
          source: nil,
          setting: option,
          value: "#{value}",
          remedy: "lower it",
          build: fn ->
            AgentConfigDiagnostic.integer_message(option, minimum, maximum, value)
          end
        }
      end

    type_rows =
      for {option, minimum, maximum} <- AgentConfigDiagnostic.options(),
          type <- AgentConfigDiagnostic.types() do
        phrase =
          case type do
            nil -> "nil"
            :other -> "unsupported"
            _other -> Atom.to_string(type)
          end

        %{
          phase: :execution,
          code: :invalid_agent_config,
          source: nil,
          setting: option,
          value: phrase,
          remedy: "must be an integer",
          build: fn ->
            AgentConfigDiagnostic.type_message(option, minimum, maximum, type)
          end
        }
      end

    integer_rows ++ type_rows
  end

  defp diagnostic_opts(row, message) do
    [
      message: message,
      provider_activity: DiagnosticCatalog.provider_activity_policy(row.phase, row.code) == true
    ] ++ source_opt(row.source)
  end

  defp source_opt(nil), do: []
  defp source_opt(kind), do: [source: CommandSource.fixed(kind)]
end
