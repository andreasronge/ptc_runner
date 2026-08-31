defmodule PtcRunner.Kernel.MissionCapabilityDiagnosticTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.DiagnosticCatalog
  alias PtcRunner.Kernel.MissionCapabilityDiagnostic

  test "singular, plural, and fallback forms satisfy the command schema" do
    assert {:ok, singular} = MissionCapabilityDiagnostic.message("draft", ["vault.read"])

    assert singular ==
             ~s(mission "draft" has no providers; missing capability requirement: vault.read)

    assert {:ok, plural} =
             MissionCapabilityDiagnostic.message("draft", ["alpha", "vault.read"])

    assert plural ==
             ~s(mission "draft" has no providers; missing capability requirements: alpha, vault.read)

    fallback =
      DiagnosticCatalog.fetch!(:bundle, :mission_capability_ungranted).message

    assert :error =
             MissionCapabilityDiagnostic.message(
               "draft",
               Enum.map(1..9, &"capability-#{&1}")
             )

    assert {:ok, schema} =
             JSV.build(CommandContract.catalog_diagnostic_schema(),
               atoms: false,
               warnings: :silent
             )

    for message <- [singular, plural, fallback] do
      assert {:ok, diagnostic} =
               CommandDiagnostic.new(:bundle, :mission_capability_ungranted,
                 message: message,
                 provider_activity: false
               )

      assert {:ok, _validated} =
               diagnostic |> CommandDiagnostic.to_map() |> JSV.validate(schema, cast: false)
    end
  end

  test "messages are sorted, deduplicated, bounded, and provenance-free" do
    refute MissionCapabilityDiagnostic.valid_message?(
             ~s(mission "draft" has no providers; missing capability requirements: zeta, alpha)
           )

    refute MissionCapabilityDiagnostic.valid_message?(
             ~s(mission "draft" has no providers; missing capability requirements: alpha, alpha)
           )

    assert :error =
             MissionCapabilityDiagnostic.message("draft", [String.duplicate("x", 129)])

    assert {:ok, message} = MissionCapabilityDiagnostic.message("draft", ["vault.read"])

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:bundle, :mission_capability_ungranted,
               message: message,
               provider_activity: false,
               source: CommandSource.fixed(:application)
             )

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:bundle, :mission_capability_ungranted,
               message: message,
               provider_activity: false,
               path: "/missions/draft"
             )

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:bundle, :mission_capability_ungranted,
               message: message,
               provider_activity: false,
               span: %{start_byte: 0, end_byte: 1}
             )
  end
end
