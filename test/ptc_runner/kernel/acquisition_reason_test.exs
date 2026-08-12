defmodule PtcRunner.Kernel.AcquisitionReasonTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.AcquisitionReason
  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.DiagnosticCatalog

  @occurrence %{provider: "selected", destination: :workflow, index: 3}

  # One representative per branch. The table is a closed contract, and every
  # branch of it is a pair that must survive a catalog or contract tightening —
  # the module rescues a refused construction into `internal_error`, so without
  # this a later narrowing would silently degrade every affected reason into
  # "the command failed internally" with nothing failing.
  @expected [
    {:mcp_transport_error, :provider_acquisition, :provider_unavailable, :acquisition},
    {:mcp_timeout, :provider_acquisition, :provider_unavailable, :acquisition},
    {:mcp_remote_error, :provider_acquisition, :provider_unavailable, :acquisition},
    {:invalid_mcp_transport, :provider_acquisition, :provider_unavailable, :acquisition},
    {:resource_registrar_unavailable, :provider_acquisition, :provider_unavailable, :acquisition},
    {:provider_prepare_failed, :provider_acquisition, :provider_unavailable, :acquisition},
    {:provider_preflight_failed, :provider_acquisition, :provider_unavailable, :acquisition},
    {:provider_acquisition_failed, :provider_acquisition, :provider_unavailable, :acquisition},
    {:mcp_protocol_error, :provider_acquisition, :provider_protocol_error, :acquisition},
    {:mcp_invalid_catalog, :provider_acquisition, :provider_protocol_error, :acquisition},
    {:mcp_invalid_tool_schema, :provider_acquisition, :provider_protocol_error, :acquisition},
    {:mcp_response_exceeded, :provider_acquisition, :provider_protocol_error, :acquisition},
    {:mcp_catalog_exceeded, :provider_acquisition, :provider_protocol_error, :acquisition},
    {:mcp_invalid_snapshot_identity, :provider_acquisition, :provider_protocol_error,
     :acquisition},
    {:invalid_provider_preparation, :provider_acquisition, :provider_protocol_error,
     :acquisition},
    {:invalid_provider_build, :provider_acquisition, :provider_protocol_error, :acquisition},
    {:provider_declaration_mismatch, :provider_acquisition, :provider_policy_changed,
     :acquisition},
    {:provider_data_policy_changed, :provider_acquisition, :provider_policy_changed,
     :acquisition},
    {:mcp_authentication_failed, :active_preflight, :authentication_rejected, :acquisition},
    {:mcp_authorization_required, :active_preflight, :authorization_required, :authorization},
    {:invalid_compatibility_environment, :local_preflight, :environment_unavailable, :local},
    {:invalid_mcp_executable, :local_preflight, :environment_unavailable, :local},
    {:invalid_replay_fixtures, :local_preflight, :environment_unavailable, :local},
    {:source_unavailable, :local_preflight, :environment_unavailable, :local},
    {:invalid_snapshot, :local_preflight, :environment_unavailable, :local},
    {:mcp_stdio_launcher_unavailable, :local_preflight, :launcher_unavailable, :local},
    {:unsupported_mcp_stdio_platform, :local_preflight, :launcher_unavailable, :local},
    {:invalid_llm_model, :local_preflight, :adapter_unavailable, :local},
    {:provider_destination_denied, :active_preflight, :selection_rejected, :selection},
    {:invalid_mcp_selection, :active_preflight, :selection_rejected, :selection}
  ]

  test "every reason the table knows maps to its closed pair and names its occurrence" do
    for {reason, phase, code, operation} <- @expected do
      diagnostic = AcquisitionReason.diagnostic(reason, @occurrence)

      assert {diagnostic.phase, diagnostic.code} == {phase, code},
             "#{reason} produced #{diagnostic.phase}/#{diagnostic.code}"

      assert diagnostic.subject.name == "selected"
      assert diagnostic.subject.operation == operation
      assert diagnostic.subject.occurrence == %{destination: :workflow, index: 3}
      assert diagnostic.provider_activity
    end
  end

  test "every pair the table can emit is admissible where it can surface" do
    # Acquisition runs for a run and acquisition-mode `doctor --connect`. A pair the
    # contract refuses would be unrenderable at exactly the moment it matters.
    for {reason, phase, code, _operation} <- @expected do
      assert CommandContract.diagnostic_allowed?(:run, phase, code),
             "#{reason} -> #{phase}/#{code} is not admissible for a run"

      assert CommandContract.diagnostic_allowed?({:doctor, :connect}, phase, code),
             "#{reason} -> #{phase}/#{code} is not admissible for connect"
    end
  end

  test "every subject the table builds satisfies the catalog's occurrence policy" do
    # The occurrence is what a bare reason lacks and this module exists to
    # attach, so a pair that forbids one would be constructed without it and the
    # translation would report less than it knows.
    for {reason, phase, code, operation} <- @expected do
      refute DiagnosticCatalog.subject_occurrence_policy(phase, code, operation) == :forbidden,
             "#{reason} -> #{phase}/#{code} forbids the occurrence it is given"

      assert operation in DiagnosticCatalog.subject_operations(phase, code),
             "#{reason} -> #{phase}/#{code} does not admit a #{operation} subject"
    end
  end

  test "an unrecognised reason fails closed rather than reaching for a near-enough code" do
    for reason <- [:something_no_producer_returns, :ok, nil, {:unexpected, :shape}] do
      diagnostic = AcquisitionReason.diagnostic(reason, @occurrence)
      assert diagnostic.phase == :internal
      assert diagnostic.code == :internal_error
    end
  end

  test "a retained-source ceiling arrives as a tuple and is still classified" do
    diagnostic = AcquisitionReason.diagnostic({:source_retained_limit_exceeded, 4}, @occurrence)

    assert diagnostic.phase == :local_preflight
    assert diagnostic.code == :environment_unavailable
    assert diagnostic.subject.operation == :local
  end

  test "an unsupported inspection schema tuple remains a local environment failure" do
    reason =
      {:unsupported_inspection_schema_version, %{artifact_version: 4, supported_version: 5}}

    diagnostic = AcquisitionReason.diagnostic(reason, @occurrence)

    assert diagnostic.phase == :local_preflight
    assert diagnostic.code == :environment_unavailable
    assert diagnostic.subject.operation == :local
  end

  test "a malformed occurrence is this module's defect, not an escaping exception" do
    # Classification runs inside an acquisition loop holding provisional roots,
    # so it must not raise past them.
    for bad <- [%{provider: "selected", destination: :workflow}, %{}, %{provider: 12}] do
      diagnostic = AcquisitionReason.diagnostic(:mcp_transport_error, bad)
      assert diagnostic.phase == :internal
      assert diagnostic.code == :internal_error
    end
  end
end
