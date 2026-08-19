defmodule PtcRunner.Kernel.SettingDiagnosticTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.AgentConfigDiagnostic
  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.DiagnosticCatalog
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic

  # Catalog rows whose dynamic message describes a document, a fixture, or a
  # contract rule rather than a setting the caller chose. Listed so the sweep
  # below stays a catalog walk instead of a hand-picked sample: a new dynamic
  # message has to land in one list or the other.
  @prose_rows [
    {:application, :contract_invalid},
    {:bundle, :duplicate_definition},
    {:bundle, :undefined_variable},
    {:bundle, :unknown_namespace},
    {:execution, :replay_fixture_missing},
    {:local_preflight, :environment_unavailable},
    {:local_preflight, :fixtures_unreadable},
    {:provider_acquisition, :capability_requirement_missing},
    {:provider_acquisition, :provider_tool_missing},
    {:result_cleanup, :result_contract_failed}
  ]

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
        phase: :result_cleanup,
        code: :result_limit_exceeded,
        source: nil,
        setting: "terminal_result_bytes",
        value: "1000000",
        remedy: "raise limits.terminal_result_bytes in the manifest",
        build: fn -> RuntimeLimitDiagnostic.result_limit_message(1_000_000) end
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
        code: :runtime_limit_exceeded,
        source: nil,
        setting: "max_turns",
        value: "4",
        remedy: remedy,
        build: fn -> RuntimeLimitDiagnostic.agent_turns_message(4, reason) end
      }
    end
  end

  defp agent_config_rows do
    for {option, minimum, maximum} <- AgentConfigDiagnostic.options() do
      %{
        phase: :execution,
        code: :workflow_failed,
        source: nil,
        setting: option,
        value: "#{minimum} to #{maximum}",
        remedy: "set #{option} in the agent configuration",
        build: fn -> AgentConfigDiagnostic.message(option, minimum, maximum) end
      }
    end
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
