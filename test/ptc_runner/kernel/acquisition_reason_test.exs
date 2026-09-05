defmodule PtcRunner.Kernel.AcquisitionReasonTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.AcquisitionReason
  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.DiagnosticCatalog
  alias PtcRunner.Kernel.ModelContractPricingCause

  @occurrence %{provider: "selected", destination: :workflow, index: 3}

  # One representative per branch. The table is a closed contract, and every
  # branch of it is a pair that must survive a catalog or contract tightening —
  # the module rescues a refused construction into `internal_error`, so without
  # this a later narrowing would silently degrade every affected reason into
  # "the command failed internally" with nothing failing.
  @expected [
    {:mcp_endpoint_connection_refused, :provider_acquisition,
     :provider_endpoint_connection_refused, :acquisition},
    {:mcp_endpoint_name_unresolved, :provider_acquisition, :provider_endpoint_name_unresolved,
     :acquisition},
    {:mcp_endpoint_tls_failed, :provider_acquisition, :provider_endpoint_tls_failed,
     :acquisition},
    {:mcp_transport_error, :provider_acquisition, :provider_unavailable, :acquisition},
    {:mcp_timeout, :provider_acquisition, :provider_acquisition_timeout, :acquisition},
    {:mcp_discovery_method_unsupported, :provider_acquisition,
     :provider_protocol_version_unsupported, :acquisition},
    {:mcp_protocol_version_unsupported, :provider_acquisition,
     :provider_protocol_version_unsupported, :acquisition},
    {:mcp_remote_error, :provider_acquisition, :provider_unavailable, :acquisition},
    {:invalid_mcp_transport, :provider_acquisition, :provider_unavailable, :acquisition},
    {:resource_registrar_unavailable, :provider_acquisition, :provider_unavailable, :acquisition},
    {:provider_prepare_failed, :provider_acquisition, :provider_unavailable, :acquisition},
    {:provider_preflight_failed, :provider_acquisition, :provider_unavailable, :acquisition},
    {:provider_acquisition_failed, :provider_acquisition, :provider_unavailable, :acquisition},
    {:mcp_protocol_error, :provider_acquisition, :provider_protocol_error, :acquisition},
    {:mcp_invalid_catalog, :provider_acquisition, :provider_protocol_error, :acquisition},
    {{:mcp_mapped_tool_missing, "structuredMissing"}, :provider_acquisition,
     :provider_tool_missing, :acquisition},
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
    {:mcp_command_not_found, :local_preflight, :environment_unavailable, :local},
    {:invalid_mcp_executable, :local_preflight, :environment_unavailable, :local},
    {:replay_fixtures_unreadable, :local_preflight, :environment_unavailable, :local},
    {:replay_fixtures_empty, :local_preflight, :environment_unavailable, :local},
    {:replay_fixtures_too_large, :local_preflight, :environment_unavailable, :local},
    {:replay_owner_unavailable, :local_preflight, :environment_unavailable, :local},
    {:source_unavailable, :local_preflight, :environment_unavailable, :local},
    {:invalid_snapshot, :local_preflight, :environment_unavailable, :local},
    {:mcp_stdio_launcher_unavailable, :local_preflight, :launcher_unavailable, :local},
    {:unsupported_mcp_stdio_platform, :local_preflight, :launcher_unavailable, :local},
    {:invalid_llm_model, :local_preflight, :adapter_unavailable, :local},
    {:unsupported_model_option, :local_preflight, :model_contract_unsupported, :local},
    {:provider_destination_denied, :active_preflight, :selection_rejected, :selection},
    {:invalid_mcp_selection, :active_preflight, :selection_rejected, :selection}
  ]

  test "every reason the table knows maps to its closed pair and names its occurrence" do
    for {reason, phase, code, operation} <- @expected do
      diagnostic = AcquisitionReason.diagnostic(reason, @occurrence)

      assert {diagnostic.phase, diagnostic.code} == {phase, code},
             "#{inspect(reason)} produced #{diagnostic.phase}/#{diagnostic.code}"

      assert diagnostic.subject.name == "selected"
      assert diagnostic.subject.operation == operation
      assert diagnostic.subject.occurrence == %{destination: :workflow, index: 3}
      assert diagnostic.provider_activity
    end
  end

  test "authorization loss during acquisition gives frontend-specific guidance" do
    diagnostic = AcquisitionReason.diagnostic(:mcp_authorization_required, @occurrence)

    assert diagnostic.message ==
             "provider authorization is required; runtime-included ptc cannot initiate " <>
               "authorization; source-checkout mix ptc run ... --authorize-mcp NAME can " <>
               "initiate it, and embedding hosts may provide authorization"
  end

  test "a rejected fixture line reports its rule and number through acquisition too" do
    diagnostic = AcquisitionReason.diagnostic({:schema_version_invalid, 7}, @occurrence)

    assert {diagnostic.phase, diagnostic.code} == {:local_preflight, :environment_unavailable}
    assert diagnostic.message == "replay fixture line 7 must set schema_version to 1"

    assert AcquisitionReason.diagnostic({:not_a_fixture_reason, 7}, @occurrence).code ==
             :internal_error

    assert AcquisitionReason.diagnostic({:schema_version_invalid, 0}, @occurrence).code ==
             :internal_error
  end

  test "endpoint connection diagnostics have fixed messages and retry policy" do
    for {reason, message, retryable?} <- [
          {:mcp_endpoint_connection_refused, "the installed endpoint refused the connection",
           true},
          {:mcp_endpoint_name_unresolved, "the installed endpoint hostname could not be resolved",
           false},
          {:mcp_endpoint_tls_failed, "the installed endpoint did not complete a TLS handshake",
           false}
        ] do
      diagnostic = AcquisitionReason.diagnostic(reason, @occurrence)

      assert diagnostic.message == message
      assert diagnostic.retryable == retryable?
      assert diagnostic.exit_status == 4
    end
  end

  test "unsupported discovery reasons select the two fixed public messages" do
    method = AcquisitionReason.diagnostic(:mcp_discovery_method_unsupported, @occurrence)
    version = AcquisitionReason.diagnostic(:mcp_protocol_version_unsupported, @occurrence)

    assert method.message ==
             "the endpoint rejected the required server/discover method and does not support MCP protocol 2026-07-28"

    assert version.message ==
             "the endpoint did not advertise support for MCP protocol 2026-07-28"

    for diagnostic <- [method, version] do
      assert diagnostic.code == :provider_protocol_version_unsupported
      assert diagnostic.source == nil
      assert diagnostic.path == nil
      assert diagnostic.notes == []
    end
  end

  test "a missing mapped tool retains only its validated declaration-owned name" do
    diagnostic =
      AcquisitionReason.diagnostic({:mcp_mapped_tool_missing, "structuredMissing"}, @occurrence)

    assert diagnostic.message ==
             ~s(the installed endpoint does not expose declared tool "structuredMissing")

    assert diagnostic.source == nil
    assert diagnostic.path == nil

    assert AcquisitionReason.diagnostic(
             {:mcp_mapped_tool_missing, "invalid tool name"},
             @occurrence
           ).code == :internal_error
  end

  test "a maximum Unicode tool name remains renderable and the schema rejects invalid names" do
    name = String.duplicate("😀", 128)
    diagnostic = AcquisitionReason.diagnostic({:mcp_mapped_tool_missing, name}, @occurrence)
    rendered = CommandDiagnostic.to_map(diagnostic)

    assert diagnostic.code == :provider_tool_missing

    assert diagnostic.message ==
             "the installed endpoint does not expose declared tool " <> Jason.encode!(name)

    assert {:ok, root} =
             JSV.build(
               CommandContract.catalog_diagnostic_schema(),
               atoms: false,
               warnings: :silent
             )

    assert {:ok, _validated} = JSV.validate(rendered, root, cast: false)

    for encoded <- [Jason.encode!("invalid tool name"), ~S("\u0061")] do
      invalid =
        Map.put(
          rendered,
          "message",
          "the installed endpoint does not expose declared tool " <> encoded
        )

      refute DiagnosticCatalog.valid_message?(
               :provider_acquisition,
               :provider_tool_missing,
               invalid["message"]
             )

      assert {:error, _details} = JSV.validate(invalid, root, cast: false)
    end
  end

  test "every pair the table can emit is admissible where it can surface" do
    # Acquisition runs for a run and acquisition-mode `doctor --connect`. A pair the
    # contract refuses would be unrenderable at exactly the moment it matters.
    for {reason, phase, code, _operation} <- @expected do
      assert CommandContract.diagnostic_allowed?(:run, phase, code),
             "#{inspect(reason)} -> #{phase}/#{code} is not admissible for a run"

      assert CommandContract.diagnostic_allowed?({:doctor, :connect}, phase, code),
             "#{inspect(reason)} -> #{phase}/#{code} is not admissible for connect"
    end
  end

  test "every subject the table builds satisfies the catalog's occurrence policy" do
    # The occurrence is what a bare reason lacks and this module exists to
    # attach, so a pair that forbids one would be constructed without it and the
    # translation would report less than it knows.
    for {reason, phase, code, operation} <- @expected do
      refute DiagnosticCatalog.subject_occurrence_policy(phase, code, operation) == :forbidden,
             "#{inspect(reason)} -> #{phase}/#{code} forbids the occurrence it is given"

      assert operation in DiagnosticCatalog.subject_operations(phase, code),
             "#{inspect(reason)} -> #{phase}/#{code} does not admit a #{operation} subject"
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

  test "a malformed occurrence is this module's defect, not an escaping exception" do
    # Classification runs inside an acquisition loop holding provisional roots,
    # so it must not raise past them.
    for bad <- [%{provider: "selected", destination: :workflow}, %{}, %{provider: 12}] do
      diagnostic = AcquisitionReason.diagnostic(:mcp_transport_error, bad)
      assert diagnostic.phase == :internal
      assert diagnostic.code == :internal_error

      pricing = ModelContractPricingCause.new(PtcRunner.TestSupport.HostLLMAdapter, "model")
      diagnostic = AcquisitionReason.diagnostic(pricing, bad)
      assert diagnostic.phase == :internal
      assert diagnostic.code == :internal_error
    end
  end

  test "a pricing cause with added fields fails closed" do
    cause = ModelContractPricingCause.new(PtcRunner.TestSupport.HostLLMAdapter, "model")
    forged = Map.put(cause, :private_payload, "must not cross the callback boundary")

    refute ModelContractPricingCause.valid?(forged)
    assert AcquisitionReason.diagnostic(forged, @occurrence).code == :internal_error
  end
end
