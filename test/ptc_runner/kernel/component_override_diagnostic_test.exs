defmodule PtcRunner.Kernel.ComponentOverrideDiagnosticTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.ComponentOverrideDiagnostic
  alias PtcRunner.Kernel.DiagnosticCatalog

  test "every verification reason has one message and one schema-authorized path" do
    reasons = ComponentOverrideDiagnostic.reasons()

    assert Enum.uniq(reasons) == reasons
    assert length(ComponentOverrideDiagnostic.messages()) == length(reasons)

    for reason <- reasons do
      assert {:ok, _message} = ComponentOverrideDiagnostic.message(reason)
      assert [{:property, field}] = ComponentOverrideDiagnostic.path(reason)
      assert {:ok, path} = CommandPath.component_override([{:property, field}])
      assert CommandPath.to_pointer(path) == "/" <> field
    end
  end

  test "every rule message is admitted by the catalog and the published schema" do
    fallback = DiagnosticCatalog.fetch!(:application, :override_invalid).message
    admitted = ComponentOverrideDiagnostic.message_schema(fallback)["enum"]
    source = CommandSource.fixed(:component_override)

    for message <- ComponentOverrideDiagnostic.messages() do
      assert ComponentOverrideDiagnostic.valid_message?(message)
      assert DiagnosticCatalog.valid_message?(:application, :override_invalid, message)
      assert message in admitted

      assert {:ok, _diagnostic} =
               CommandDiagnostic.new(:application, :override_invalid,
                 source: source,
                 message: message
               )
    end

    assert fallback in admitted
    refute ComponentOverrideDiagnostic.valid_message?(fallback)
    refute ComponentOverrideDiagnostic.valid_message?("the component override is bad")
  end

  test "a field pointer cannot be attached to a different document role" do
    assert {:ok, path} = CommandPath.component_override([{:property, "source_hash"}])
    source = CommandSource.fixed(:component_override)
    {:ok, message} = ComponentOverrideDiagnostic.message(:override_source_hash_mismatch)

    assert {:ok, _diagnostic} =
             CommandDiagnostic.new(:application, :override_invalid,
               source: source,
               path: path,
               message: message
             )

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:application, :override_invalid,
               source: CommandSource.fixed(:application),
               path: path,
               message: message
             )
  end
end
