defmodule PtcRunner.Kernel.AcquisitionReason do
  @moduledoc false

  # Translates a provider callback's bare reason into a closed diagnostic while
  # the occurrence that produced it is still in scope.
  #
  # A prepare, preflight, or acquire callback answers `{:error, reason}` with an
  # atom and nothing else. Every `provider_acquisition` code requires a subject
  # bearing an occurrence, so a bare reason cannot be classified once it has left
  # the loop that knows which occurrence produced it: it reaches the command
  # boundary carrying no subject and fails closed as `internal_error`, reporting
  # an unreachable MCP server as an implementation defect. This module is called
  # from the three sites in `PtcRunner.Kernel.ProviderAcquisition` that still
  # hold the occurrence.
  #
  # Only an active command is classified. Direct embedding keeps the bare reason,
  # which is a far richer vocabulary than the closed catalog can express — the
  # MCP source alone distinguishes a timeout from an authentication failure from
  # an oversized catalog — and an embedding has no envelope to render a
  # diagnostic into. That is the same boundary phase-8 credential resolution
  # draws, decided by the same question: whether the session carries an
  # operation deadline.
  #
  # Every caller here is past the phase-8 marker, so activity is always true and
  # is not a parameter, unlike `PtcRunner.Kernel.LocalPreflight`, whose table
  # spans the marker.
  #
  # ## How a reason is placed
  #
  # The catalog offers three acquisition codes, so the grouping follows one rule
  # rather than a judgement per atom:
  #
  #   * `:provider_unavailable` — the provider could not be reached or started.
  #     A transport that would not open, a stdio child that would not spawn, a
  #     callback that raised or exited.
  #   * `:provider_protocol_error` — the provider answered and the answer was
  #     unusable: an invalid catalog or tool schema, a response past its ceiling,
  #     or a preparation/preflight/build that failed normalization.
  #   * `:provider_policy_changed` — the preparation contradicted the sealed
  #     declaration that authorised it.
  #
  # Three groups keep a phase of their own instead, because what they describe is
  # not acquisition failing:
  #
  #   * a rejected credential is `:active_preflight` / `:authentication_rejected`
  #     with an `:acquisition` subject, a pair the catalog already admits;
  #   * a declaration or selection reason is `:active_preflight` /
  #     `:selection_rejected` with a `:selection` subject. `provider_declaration`
  #     is unreachable here — it is pre-classification, pinned to
  #     `provider_activity: false` — and this is the answer `LocalPreflight`
  #     already gives these same reasons past the marker; and
  #   * a local-environment reason keeps its `:local_preflight` code with a
  #     `:local` subject, reusing phase 7's groupings unchanged. A stdio launcher
  #     missing at acquisition is the same fact it would have been at phase 7,
  #     and `provider_unavailable` would blame the provider for a local
  #     dependency.
  #
  # Anything else fails closed as an internal error. Translations are added with
  # their producers, so a reason nothing can currently return has no branch here,
  # and the lists below name the ones removed for exactly that reason.
  #
  # `:credential_unavailable` is the one reachable-looking reason deliberately
  # absent: it cannot arrive on a command path now that phase-8 step 5 resolves
  # the sealed union up front and acquisition refuses a preparation the map does
  # not cover.

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSubject

  # `:mcp_remote_error` is an answered case — a JSON-RPC error at discovery — and
  # sits here rather than with the protocol reasons because a refused discovery
  # leaves nothing to acquire at all. That is an availability fact about the
  # provider, not a malformed answer about it.
  #
  # Deliberately absent, because the stdio and discovery paths collapse them
  # before a builder can return them: `:mcp_stdio_spawn_failed`,
  # `:mcp_stdio_spawn_timeout`, `:mcp_stdio_owner_down`,
  # `:invalid_mcp_stdio_launch`, and `:mcp_transport_closed` all normalize into
  # `:mcp_transport_error` or `:mcp_timeout` first.
  @unavailable_reasons [
    :mcp_transport_error,
    :mcp_transport_busy,
    :mcp_timeout,
    :mcp_remote_error,
    :invalid_mcp_transport,
    :resource_registrar_unavailable,
    :provider_prepare_failed,
    :provider_preflight_failed,
    :provider_acquisition_failed
  ]

  @protocol_reasons [
    :mcp_protocol_error,
    :mcp_capability_negotiation_error,
    :mcp_invalid_catalog,
    :mcp_invalid_tool_schema,
    :mcp_mapped_tool_missing,
    :mcp_unsupported_result,
    :mcp_response_exceeded,
    :mcp_catalog_exceeded,
    :mcp_invalid_snapshot_identity,
    :invalid_provider_preparation,
    :invalid_provider_preflight,
    :invalid_provider_build,
    :invalid_provider_snapshot
  ]

  # Phase 7's groupings, extended only with reasons that cannot reach phase 7
  # because no audited-local check covers their source. One condition must not be
  # named two ways depending on which step observed it.
  @environment_reasons [
    :invalid_compatibility_environment,
    :invalid_mcp_working_directory,
    :invalid_mcp_executable,
    :invalid_trace_snapshot_directory,
    :invalid_inspection_snapshot_directory,
    :invalid_replay_fixtures,
    :replay_fixtures_too_large,
    :replay_entry_limit_exceeded,
    :duplicate_replay_entry,
    :source_unavailable,
    :invalid_snapshot
  ]

  @launcher_reasons [:mcp_stdio_launcher_unavailable, :unsupported_mcp_stdio_platform]
  @adapter_reasons [:invalid_llm_model]

  @selection_reasons [
    :provider_destination_denied,
    :invalid_mcp_selection,
    :invalid_llm_selection,
    :invalid_llm_replay_selection,
    :invalid_trace_snapshot_selection,
    :invalid_inspection_snapshot_selection
  ]

  @typedoc "The occurrence shape `ProviderAcquisition` carries through its loops."
  @type occurrence :: %{
          required(:provider) => binary(),
          required(:destination) => :workflow | :mission,
          required(:index) => non_neg_integer(),
          optional(any()) => any()
        }

  @doc """
  Classifies one callback reason against the occurrence that produced it.
  """
  @spec diagnostic(term(), occurrence()) :: CommandDiagnostic.t()
  def diagnostic(reason, occurrence) when reason in @unavailable_reasons,
    do: acquisition_diagnostic(:provider_unavailable, occurrence)

  def diagnostic(reason, occurrence) when reason in @protocol_reasons,
    do: acquisition_diagnostic(:provider_protocol_error, occurrence)

  def diagnostic(reason, occurrence)
      when reason in [:provider_declaration_mismatch, :provider_data_policy_changed],
      do: acquisition_diagnostic(:provider_policy_changed, occurrence)

  def diagnostic(:mcp_authentication_failed, occurrence),
    do: subject_diagnostic(:active_preflight, :authentication_rejected, :acquisition, occurrence)

  # A grant revoked, a refresh that failed, or a scope the grant does not carry,
  # discovered while acquiring. Slice #3 owns refusing a selected OAuth
  # occurrence *before* any provider work; this is the same code answering the
  # different question of authorization failing underneath one mid-acquisition.
  def diagnostic(:mcp_authorization_required, occurrence),
    do: subject_diagnostic(:active_preflight, :authorization_required, :authorization, occurrence)

  # A retained-source ceiling arrives as a tuple rather than an atom, so it needs
  # its own head: the guarded clauses below only ever see atoms.
  def diagnostic({:source_retained_limit_exceeded, _limit}, occurrence),
    do: subject_diagnostic(:local_preflight, :environment_unavailable, :local, occurrence)

  def diagnostic(reason, occurrence) when reason in @environment_reasons,
    do: subject_diagnostic(:local_preflight, :environment_unavailable, :local, occurrence)

  def diagnostic(reason, occurrence) when reason in @launcher_reasons,
    do: subject_diagnostic(:local_preflight, :launcher_unavailable, :local, occurrence)

  def diagnostic(reason, occurrence) when reason in @adapter_reasons,
    do: subject_diagnostic(:local_preflight, :adapter_unavailable, :local, occurrence)

  def diagnostic(reason, occurrence) when reason in @selection_reasons,
    do: subject_diagnostic(:active_preflight, :selection_rejected, :selection, occurrence)

  def diagnostic(_reason, _occurrence), do: internal_diagnostic()

  defp acquisition_diagnostic(code, occurrence),
    do: subject_diagnostic(:provider_acquisition, code, :acquisition, occurrence)

  defp subject_diagnostic(phase, code, operation, occurrence) do
    site = %{destination: occurrence.destination, index: occurrence.index}

    case CommandSubject.provider(occurrence.provider, operation, site) do
      {:ok, subject} ->
        CommandDiagnostic.new!(phase, code, subject: subject, provider_activity: true)

      {:error, _reason} ->
        internal_diagnostic()
    end
  rescue
    # A malformed occurrence is this module's own defect rather than the
    # provider's, and must not escape as an exception into an acquisition loop
    # that is holding provisional roots.
    _exception -> internal_diagnostic()
  end

  defp internal_diagnostic,
    do: CommandDiagnostic.new!(:internal, :internal_error, provider_activity: true)
end
