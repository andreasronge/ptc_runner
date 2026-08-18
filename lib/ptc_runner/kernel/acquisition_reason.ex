defmodule PtcRunner.Kernel.AcquisitionReason do
  @moduledoc false

  # Translates a provider callback's bare reason into a closed diagnostic while
  # the occurrence that produced it is still in scope.
  #
  # A prepare, preflight, or acquire callback answers `{:error, reason}` with an
  # atom and nothing else. Every acquisition diagnostic produced here requires
  # a subject bearing an occurrence, so a bare reason cannot be classified once
  # it has left the loop that knows which occurrence produced it: it reaches the command
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
  # Every caller here has entered provider acquisition and attempted its
  # provider-facing preparation, preflight, or acquisition work, so activity is
  # always true and is not a parameter. Merely crossing the earlier lifecycle
  # marker would not establish that evidence; `PtcRunner.Kernel.LocalPreflight`
  # therefore carries the accumulated value explicitly.
  #
  # ## How a reason is placed
  #
  # The catalog offers occurrence-attributed acquisition codes, so the
  # grouping follows one rule rather than a judgement per atom:
  #
  #   * `:provider_unavailable` — the provider could not be reached or started.
  #     A transport that would not open, a stdio child that would not spawn, a
  #     callback that raised or exited.
  #   * `:provider_acquisition_timeout` — a budget expired before acquisition
  #     finished. Deliberately not `:provider_unavailable`, which asserts a
  #     failure to reach or start the provider; this asserts only that the clock
  #     ran out, which is the weaker and — because `:mcp_timeout` also carries
  #     launcher staging and spawn expiry, not just an unanswered discovery — the
  #     only claim that holds for every producer. What the operator can act on is
  #     the same either way: raise the budget. A cold first launch is the common
  #     cause, which is why the row is retryable.
  #   * `:provider_protocol_error` — the provider answered and the answer was
  #     unusable: an invalid catalog or tool schema, a response past its ceiling,
  #     or a preparation/preflight/build that failed normalization.
  #   * `:provider_protocol_version_unsupported` — discovery definitively showed
  #     that the installed endpoint does not implement the pinned MCP profile.
  #   * `:provider_tool_missing` — the provider returned a valid tool catalog,
  #     but it did not contain one tool named by the sealed host declaration.
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
  alias PtcRunner.Kernel.LLMReplayFixtureDiagnostic
  alias PtcRunner.Kernel.MCPAcquisitionDiagnostic

  # `:mcp_remote_error` is an answered case — a JSON-RPC error at discovery — and
  # sits here rather than with the protocol reasons because a refused discovery
  # leaves nothing to acquire at all. That is an availability fact about the
  # provider, not a malformed answer about it.
  #
  # Deliberately absent, because the stdio and discovery paths collapse them
  # before a builder can return them: `:mcp_stdio_spawn_failed`,
  # `:mcp_stdio_spawn_timeout`, `:mcp_stdio_owner_down`,
  # `:invalid_mcp_stdio_launch`, and `:mcp_transport_closed` all normalize into
  # `:mcp_transport_error` or `:mcp_timeout` first, and `:mcp_timeout` has its own
  # code below.
  @unavailable_reasons [
    :mcp_transport_error,
    :mcp_transport_busy,
    :mcp_remote_error,
    :invalid_mcp_transport,
    :resource_registrar_unavailable,
    :provider_prepare_failed,
    :provider_preflight_failed,
    :provider_acquisition_failed
  ]

  @endpoint_reasons %{
    mcp_endpoint_connection_refused: :provider_endpoint_connection_refused,
    mcp_endpoint_name_unresolved: :provider_endpoint_name_unresolved,
    mcp_endpoint_tls_failed: :provider_endpoint_tls_failed
  }

  @protocol_reasons [
    :mcp_protocol_error,
    :mcp_capability_negotiation_error,
    :mcp_invalid_catalog,
    :mcp_invalid_tool_schema,
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
    :mcp_command_not_found,
    :invalid_mcp_executable,
    :invalid_trace_snapshot_directory,
    :invalid_inspection_snapshot_directory,
    :replay_owner_unavailable,
    :source_unavailable,
    :invalid_snapshot
  ]

  @fixture_file_reasons [
    :replay_fixtures_unreadable,
    :replay_fixtures_empty,
    :replay_fixtures_too_large
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
  def diagnostic(reason, occurrence) when is_map_key(@endpoint_reasons, reason),
    do: acquisition_diagnostic(Map.fetch!(@endpoint_reasons, reason), occurrence)

  def diagnostic(reason, occurrence) when reason in @unavailable_reasons,
    do: acquisition_diagnostic(:provider_unavailable, occurrence)

  def diagnostic(:mcp_timeout, occurrence),
    do: acquisition_diagnostic(:provider_acquisition_timeout, occurrence)

  def diagnostic(:mcp_protocol_version_unsupported, occurrence),
    do: acquisition_diagnostic(:provider_protocol_version_unsupported, occurrence)

  def diagnostic({:mcp_mapped_tool_missing, name}, occurrence) do
    case MCPAcquisitionDiagnostic.missing_tool_message(name) do
      {:ok, message} -> acquisition_diagnostic(:provider_tool_missing, occurrence, message)
      :error -> internal_diagnostic()
    end
  end

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

  def diagnostic({:unsupported_inspection_schema_version, _details}, occurrence),
    do: subject_diagnostic(:local_preflight, :environment_unavailable, :local, occurrence)

  def diagnostic(reason, occurrence) when reason in @environment_reasons,
    do: subject_diagnostic(:local_preflight, :environment_unavailable, :local, occurrence)

  # A refused fixture file names the rule it broke, and a line-level rejection
  # names the line. Acquisition sees the same reasons phase 7 does, so it must
  # not report them one way and the local step another. The tuple heads above
  # match first, so nothing else with this shape reaches here; anything this
  # module cannot render still falls through to the internal error.
  def diagnostic(reason, occurrence) when reason in @fixture_file_reasons,
    do: fixture_diagnostic(reason, occurrence)

  def diagnostic({entry_reason, line}, occurrence)
      when is_atom(entry_reason) and is_integer(line) and line > 0,
      do: fixture_diagnostic({entry_reason, line}, occurrence)

  def diagnostic(reason, occurrence) when reason in @launcher_reasons,
    do: subject_diagnostic(:local_preflight, :launcher_unavailable, :local, occurrence)

  def diagnostic(reason, occurrence) when reason in @adapter_reasons,
    do: subject_diagnostic(:local_preflight, :adapter_unavailable, :local, occurrence)

  def diagnostic(reason, occurrence) when reason in @selection_reasons,
    do: subject_diagnostic(:active_preflight, :selection_rejected, :selection, occurrence)

  def diagnostic(_reason, _occurrence), do: internal_diagnostic()

  defp fixture_diagnostic(reason, occurrence) do
    case LLMReplayFixtureDiagnostic.message(reason) do
      {:ok, message} ->
        subject_diagnostic(
          :local_preflight,
          :environment_unavailable,
          :local,
          occurrence,
          message
        )

      :error ->
        internal_diagnostic()
    end
  end

  defp acquisition_diagnostic(code, occurrence, message \\ nil),
    do: subject_diagnostic(:provider_acquisition, code, :acquisition, occurrence, message)

  defp subject_diagnostic(phase, code, operation, occurrence, message \\ nil) do
    site = %{destination: occurrence.destination, index: occurrence.index}

    case CommandSubject.provider(occurrence.provider, operation, site) do
      {:ok, subject} ->
        opts = [subject: subject, provider_activity: true]
        opts = if is_binary(message), do: Keyword.put(opts, :message, message), else: opts
        CommandDiagnostic.new!(phase, code, opts)

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
