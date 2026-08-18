defmodule PtcRunner.Kernel.DiagnosticCatalog do
  @moduledoc """
  Authoritative closed V1 command diagnostic catalog.

  Each row owns the phase, code, exit status, retryability, and bounded default
  message. Renderers and schemas derive their admitted pairs from this table;
  lower-level reasons never add a public code.
  """

  alias PtcRunner.Kernel.CompileDiagnostic
  alias PtcRunner.Kernel.ContractSchemaDiagnostic
  alias PtcRunner.Kernel.LLMReplayDiagnostic
  alias PtcRunner.Kernel.MCPAcquisitionDiagnostic
  alias PtcRunner.Kernel.ResultContractDiagnostic
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic

  @endpoint_codes [
    :installation_endpoint_invalid,
    :installation_endpoint_insecure_loopback_required,
    :installation_endpoint_literal_loopback_required,
    :installation_endpoint_insecure_loopback_forbidden,
    :installation_endpoint_credentials_require_https
  ]

  @rows [
    {:arguments, :invalid_command, 2, false, "use one of the supported commands"},
    {:arguments, :invalid_arguments, 2, false, "use the documented arguments for this command"},
    {:arguments, :conflicting_arguments, 2, false,
     "choose only one option from the conflicting argument group"},
    {:arguments, :project_host_undeclared, 2, false,
     "the project document declares no host block; add one to use this command"},
    {:arguments, :envelope_destination_exists, 2, false,
     "the envelope destination already exists"},
    {:arguments, :docs_page_unknown, 2, false, "no documentation page is served under that name"},
    {:host, :host_unavailable, 3, false, "the host configuration is unavailable"},
    {:host, :host_invalid, 3, false, "the host configuration is invalid"},
    {:host, :host_schema_invalid, 3, false, "the host configuration does not satisfy its schema"},
    {:host, :installed_limit_invalid, 3, false, "an installed limit is invalid"},
    {:host, :installation_revision_missing, 3, false,
     "an installed provider is missing its behavior revision"},
    {:host, :installation_endpoint_invalid, 3, false,
     "an installed MCP endpoint is not admissible; streamable_http requires an https URL, or allow_insecure_loopback with a credential-free plain-http loopback address"},
    {:host, :installation_endpoint_insecure_loopback_required, 3, false,
     "a plain-http MCP endpoint requires allow_insecure_loopback"},
    {:host, :installation_endpoint_literal_loopback_required, 3, false,
     "allow_insecure_loopback requires a literal 127.0.0.1 or [::1] address"},
    {:host, :installation_endpoint_insecure_loopback_forbidden, 3, false,
     "allow_insecure_loopback is not permitted on an https endpoint; remove it"},
    {:host, :installation_endpoint_credentials_require_https, 3, false,
     "configured MCP credentials require an https endpoint"},
    {:application, :application_unavailable, 3, false, "the application is unavailable"},
    {:application, :application_not_found, 3, false, "the application manifest does not exist"},
    {:application, :invalid_json, 3, false, "an application document is not valid JSON"},
    {:application, :duplicate_property, 3, false,
     "an application document contains a duplicate property"},
    {:application, :schema_violation, 3, false,
     "the application manifest does not satisfy its schema"},
    {:application, :installed_limit_exceeded, 3, false,
     "an application limit exceeds the installed ceiling; lower it or raise the host-configured ceiling"},
    {:application, :required_property_missing, 3, false,
     "the application manifest is missing a required property"},
    {:application, :reference_missing, 3, false,
     "a referenced application document is unavailable"},
    {:application, :document_limit_exceeded, 3, false,
     "the application document closure exceeds its limit"},
    {:application, :contract_invalid, 3, false, "an application value contract is invalid"},
    {:application, :input_invalid, 3, false,
     "the selected input is not an admissible JSON object"},
    {:application, :input_contract_failed, 3, false,
     "the selected input does not satisfy the input contract"},
    {:application, :override_invalid, 3, false, "the component override is invalid"},
    {:application, :event_identity_conflict, 3, false,
     "the command event identity conflicts with the application"},
    {:bundle, :bundle_invalid, 3, false, "the component bundle is invalid"},
    {:bundle, :bundle_limit_exceeded, 3, false, "the component bundle exceeds a compile limit"},
    {:bundle, :compile_failed, 3, false, "the component bundle could not be compiled"},
    {:bundle, :syntax_invalid, 3, false, "the component source is not valid PTC-Lisp"},
    {:bundle, :undefined_variable, 3, false,
     "the component source contains an undefined variable reference"},
    {:bundle, :duplicate_definition, 3, false,
     "the component bundle defines the same name more than once"},
    {:bundle, :unknown_namespace, 3, false,
     "the component source references an unavailable namespace"},
    {:bundle, :entry_invalid, 3, false, "the workflow entry is not a public bundle export"},
    {:bundle, :mission_undeclared, 3, false,
     "the workflow entry evaluates into a mission and the manifest declares none"},
    {:provider_declaration, :provider_unknown, 3, false,
     "the selected provider is not installed"},
    {:provider_declaration, :selection_invalid, 3, false, "the provider selection is invalid"},
    {:provider_declaration, :selection_unverifiable, 3, false,
     "the provider selection cannot be verified declaratively"},
    {:provider_declaration, :placement_denied, 3, false,
     "the provider is not allowed in this destination"},
    {:provider_declaration, :dependency_invalid, 3, false,
     "the selected provider dependency graph is invalid"},
    {:provider_declaration, :data_policy_denied, 3, false,
     "the selected providers do not admit the effective data class"},
    {:destination, :invalid_destination, 7, false, "an artifact destination is invalid"},
    {:destination, :invalid_trace_destination, 7, false, "the trace destination is invalid"},
    {:destination, :trace_directory_missing, 7, false,
     "--trace-dir must be an existing normal directory"},
    {:destination, :trace_destination_unavailable, 7, false,
     "the trace destination is unavailable"},
    {:destination, :trace_destination_unsafe, 7, false, "the trace destination is unsafe"},
    {:destination, :invalid_inspection_destination, 7, false,
     "--inspect must name a valid destination ending in .inspection.jsonl"},
    {:destination, :inspection_destination_unavailable, 7, false,
     "the inspection destination is unavailable"},
    {:destination, :inspection_directory_missing, 7, false,
     "--inspect must name a file in an existing directory"},
    {:destination, :inspection_destination_unsafe, 7, false,
     "the inspection destination is unsafe"},
    {:destination, :invalid_result_destination, 7, false, "the result destination is invalid"},
    {:destination, :result_destination_unavailable, 7, false,
     "the result destination is unavailable"},
    {:destination, :result_directory_missing, 7, false,
     "--output and --private-output must name a file in an existing directory"},
    {:destination, :result_destination_unsafe, 7, false, "the result destination is unsafe"},
    {:destination, :destination_exists, 7, false, "an artifact destination already exists"},
    {:destination, :private_destination_required, 7, false,
     "the run requires an authorized private destination"},
    {:destination, :recovery_reservation_failed, 7, false,
     "the private result recovery reservation failed"},
    {:local_preflight, :environment_unavailable, 4, false,
     "a required local environment is unavailable"},
    {:local_preflight, :environment_file_not_found, 4, false,
     "the named environment file does not exist"},
    {:local_preflight, :environment_file_not_regular, 4, false,
     "the named environment file is not a regular file"},
    {:local_preflight, :environment_file_unreadable, 4, false,
     "the named environment file cannot be read safely"},
    {:local_preflight, :environment_file_too_large, 4, false,
     "the named environment file exceeds the 1 MB limit"},
    {:local_preflight, :environment_file_invalid_utf8, 4, false,
     "the named environment file is not valid UTF-8"},
    {:local_preflight, :authorization_target_unknown, 4, false,
     "--authorize-mcp must name an installed provider the application selects"},
    {:local_preflight, :authorization_not_applicable, 4, false,
     "--authorize-mcp applies only to an installation that declares OAuth"},
    {:local_preflight, :command_not_found, 4, false,
     "a required provider command could not be found"},
    {:local_preflight, :executable_unavailable, 4, false,
     "a required provider executable is unusable"},
    {:local_preflight, :fixtures_unreadable, 4, false, "provider fixtures could not be read"},
    {:local_preflight, :adapter_unavailable, 4, false,
     "a required provider adapter is unavailable"},
    {:local_preflight, :launcher_unavailable, 4, false,
     "a required provider launcher is unavailable"},
    {:local_preflight, :local_check_timeout, 4, false, "a local provider check timed out"},
    {:active_preflight, :provider_application_unavailable, 4, false,
     "a required provider application is unavailable"},
    {:active_preflight, :selection_rejected, 4, false,
     "the provider rejected the normalized selection"},
    {:active_preflight, :selection_validation_failed, 4, false,
     "active provider selection validation failed"},
    {:active_preflight, :selection_validation_timeout, 4, false,
     "active provider selection validation timed out"},
    {:active_preflight, :credential_unavailable, 4, false,
     "a required provider credential is unavailable"},
    {:active_preflight, :authorization_required, 4, false,
     "explicit provider authorization is required"},
    {:active_preflight, :authorization_rejected, 4, false,
     "explicit provider authorization was rejected"},
    {:active_preflight, :authentication_rejected, 4, false,
     "provider authentication was rejected"},
    {:active_preflight, :connectivity_rejected, 4, false,
     "the provider rejected the connectivity operation"},
    {:active_preflight, :connectivity_protocol_error, 4, false,
     "the provider returned an invalid connectivity response"},
    {:active_preflight, :connectivity_unsupported, 4, false,
     "the provider does not implement the declared connectivity check"},
    {:active_preflight, :connectivity_outcome_unknown, 4, false,
     "the connectivity outcome could not be committed safely"},
    {:active_preflight, :connectivity_timeout, 4, false,
     "the connectivity operation exceeded its budget"},
    {:active_preflight, :authorization_unavailable, 4, true,
     "the authorization service is temporarily unavailable"},
    {:active_preflight, :connectivity_unavailable, 4, true,
     "the provider connectivity operation is temporarily unavailable"},
    {:active_preflight, :connectivity_rate_limited, 4, true,
     "the provider connectivity operation is rate limited"},
    {:provider_acquisition, :provider_unavailable, 4, false,
     "the selected provider could not be acquired"},
    {:provider_acquisition, :provider_endpoint_connection_refused, 4, true,
     "the installed endpoint refused the connection"},
    {:provider_acquisition, :provider_endpoint_name_unresolved, 4, false,
     "the installed endpoint hostname could not be resolved"},
    {:provider_acquisition, :provider_endpoint_tls_failed, 4, false,
     "the installed endpoint did not complete a TLS handshake"},
    {:provider_acquisition, :provider_protocol_error, 4, false,
     "the selected provider returned an invalid acquisition response"},
    {:provider_acquisition, :provider_protocol_version_unsupported, 4, false,
     "the installed endpoint does not support MCP protocol 2026-07-28"},
    {:provider_acquisition, :provider_tool_missing, 4, false,
     "the installed endpoint does not expose a declared tool"},
    {:provider_acquisition, :provider_policy_changed, 4, false,
     "the selected provider policy changed during acquisition"},
    {:provider_acquisition, :capability_requirement_missing, 4, false,
     "a component requires a capability that the selected providers did not supply"},
    {:execution, :workflow_failed, 5, false, "the workflow failed"},
    {:execution, :llm_authentication_failed, 5, false,
     "the LLM provider rejected authentication; check the installed credential"},
    {:execution, :llm_payment_required, 5, false,
     "the LLM provider rejected the request for billing or credit reasons"},
    {:execution, :llm_rate_limited, 5, true, "the LLM provider rate limited the request"},
    {:execution, :llm_model_not_found, 5, false,
     "the LLM provider could not find the configured model"},
    {:execution, :llm_tool_calling_unsupported, 5, false,
     "the configured model does not support tool calling"},
    {:execution, :llm_request_invalid, 5, false,
     "the LLM provider rejected the configured request"},
    {:execution, :llm_access_denied, 5, false,
     "the LLM provider denied access to the configured model"},
    {:execution, :llm_timeout, 5, true, "the LLM provider request timed out"},
    {:execution, :llm_provider_unavailable, 5, true, "the LLM provider is unavailable"},
    {:execution, :llm_provider_failed, 5, false, "the LLM provider request failed"},
    {:execution, :mission_failed, 5, false, "a subordinate mission failed"},
    {:execution, :runtime_limit_exceeded, 6, false, "a runtime limit was exceeded"},
    {:execution, :run_timeout, 6, false, "the run duration limit was exceeded"},
    {:execution, :provider_failed, 5, false, "a provider failed during execution"},
    {:execution, :replay_fixture_missing, 5, false,
     "no replay fixture matches the workflow request"},
    {:execution, :event_capture_limit_exceeded, 7, false,
     "the canonical event capture limit was exceeded"},
    {:execution, :event_sink_unavailable, 7, false, "the canonical event sink is unavailable"},
    {:execution, :inspection_capture_limit_exceeded, 7, false,
     "the private inspection capture limit was exceeded"},
    {:execution, :inspection_sink_unavailable, 7, false,
     "the private inspection sink is unavailable"},
    {:result_cleanup, :result_invalid, 7, false, "the workflow result is invalid"},
    {:result_cleanup, :result_contract_failed, 7, false,
     "the workflow result does not satisfy its contract"},
    {:result_cleanup, :result_limit_exceeded, 7, false, "the workflow result exceeds its limit"},
    {:result_cleanup, :provider_cleanup_failed, 7, false, "provider cleanup failed"},
    {:result_cleanup, :provider_cleanup_timeout, 7, false, "provider cleanup timed out"},
    {:publication, :trace_publication_failed, 7, false, "trace publication failed"},
    {:publication, :inspection_publication_failed, 7, false, "inspection publication failed"},
    {:publication, :result_publication_failed, 7, false, "result publication failed"},
    {:publication, :recovery_cleanup_failed, 7, false, "private result recovery cleanup failed"},
    {:publication, :destination_collision, 7, false,
     "an artifact destination appeared before publication"},
    {:publication, :initialization_target_exists, 7, false,
     "the initialization target already exists"},
    {:publication, :initialization_parent_missing, 7, false,
     "the initialization target's parent directory does not exist"},
    {:publication, :initialization_parent_unusable, 7, false,
     "the initialization target's parent directory is unusable"},
    {:publication, :initialization_failed, 7, false, "project initialization failed"},
    {:internal, :internal_error, 70, false, "the command failed internally"}
  ]

  @type phase ::
          :arguments
          | :host
          | :application
          | :bundle
          | :provider_declaration
          | :destination
          | :local_preflight
          | :active_preflight
          | :provider_acquisition
          | :execution
          | :result_cleanup
          | :publication
          | :internal

  @type row :: %{
          phase: phase(),
          code: atom(),
          exit_status: 2 | 3 | 4 | 5 | 6 | 7 | 70,
          retryable: boolean(),
          message: binary()
        }

  @catalog Map.new(@rows, fn {phase, code, exit_status, retryable, message} ->
             {{phase, code},
              %{
                phase: phase,
                code: code,
                exit_status: exit_status,
                retryable: retryable,
                message: message
              }}
           end)
  @row_order @rows
             |> Enum.with_index()
             |> Map.new(fn {{phase, code, _exit_status, _retryable, _message}, index} ->
               {{phase, code}, index}
             end)

  if map_size(@catalog) != length(@rows) do
    raise "duplicate V1 command diagnostic pair"
  end

  @spec fetch(phase(), atom()) :: {:ok, row()} | :error
  def fetch(phase, code), do: Map.fetch(@catalog, {phase, code})

  @spec fetch!(phase(), atom()) :: row()
  def fetch!(phase, code), do: Map.fetch!(@catalog, {phase, code})

  @doc false
  @spec valid_message?(phase(), atom(), term()) :: boolean()
  def valid_message?(phase, code, message) do
    case fetch(phase, code) do
      {:ok, %{message: ^message}} ->
        true

      {:ok, _row} ->
        valid_dynamic_message?(phase, code, message)

      :error ->
        false
    end
  end

  @doc false
  @spec message_schema(row()) :: map()
  def message_schema(%{phase: :execution, code: :runtime_limit_exceeded, message: fallback}),
    do: RuntimeLimitDiagnostic.message_schema(fallback)

  def message_schema(%{phase: :execution, code: :run_timeout, message: fallback}),
    do: RuntimeLimitDiagnostic.run_duration_message_schema(fallback)

  def message_schema(%{phase: :execution, code: :replay_fixture_missing, message: fallback}),
    do: LLMReplayDiagnostic.message_schema(fallback)

  def message_schema(%{
        phase: :result_cleanup,
        code: :result_contract_failed,
        message: fallback
      }),
      do: ResultContractDiagnostic.message_schema(fallback)

  def message_schema(%{phase: :application, code: :contract_invalid, message: fallback}),
    do: ContractSchemaDiagnostic.message_schema(fallback)

  def message_schema(%{
        phase: :provider_acquisition,
        code: :provider_tool_missing,
        message: fallback
      }),
      do: MCPAcquisitionDiagnostic.missing_tool_message_schema(fallback)

  def message_schema(%{code: code, message: fallback}),
    do: CompileDiagnostic.message_schema(code, fallback)

  defp valid_dynamic_message?(:execution, :runtime_limit_exceeded, message),
    do: RuntimeLimitDiagnostic.valid_message?(message)

  defp valid_dynamic_message?(:execution, :run_timeout, message),
    do: RuntimeLimitDiagnostic.run_duration_message?(message)

  defp valid_dynamic_message?(:execution, :replay_fixture_missing, message),
    do: LLMReplayDiagnostic.valid_message?(message)

  defp valid_dynamic_message?(:result_cleanup, :result_contract_failed, message),
    do: ResultContractDiagnostic.valid_message?(message)

  defp valid_dynamic_message?(:application, :contract_invalid, message),
    do: ContractSchemaDiagnostic.valid_message?(message)

  defp valid_dynamic_message?(:provider_acquisition, :provider_tool_missing, message),
    do: MCPAcquisitionDiagnostic.valid_missing_tool_message?(message)

  defp valid_dynamic_message?(_phase, code, message),
    do: CompileDiagnostic.valid_message?(code, message)

  @spec rows() :: [row()]
  def rows do
    Enum.map(@rows, fn {phase, code, exit_status, retryable, message} ->
      %{
        phase: phase,
        code: code,
        exit_status: exit_status,
        retryable: retryable,
        message: message
      }
    end)
  end

  @doc """
  Returns the closed compound-failure precedence key for a catalog pair.

  Lower keys have higher precedence. `:error` identifies preparation-only
  diagnostics that cannot participate in a compound outcome.
  """
  @spec compound_precedence(phase(), atom()) :: {:ok, {1..8, non_neg_integer()}} | :error
  def compound_precedence(phase, code) do
    rank =
      case {phase, code} do
        {:result_cleanup, :provider_cleanup_timeout} ->
          1

        {:result_cleanup, :provider_cleanup_failed} ->
          2

        {:internal, :internal_error} ->
          3

        {:result_cleanup, result_code}
        when result_code in [:result_invalid, :result_contract_failed, :result_limit_exceeded] ->
          4

        {:execution, sink_code}
        when sink_code in [
               :event_capture_limit_exceeded,
               :event_sink_unavailable,
               :inspection_capture_limit_exceeded,
               :inspection_sink_unavailable
             ] ->
          7

        {:execution, _execution_code} ->
          5

        {preflight_phase, _preflight_code}
        when preflight_phase in [:local_preflight, :active_preflight, :provider_acquisition] ->
          6

        {:publication, _publication_code} ->
          8

        _other ->
          nil
      end

    case {rank, Map.fetch(@row_order, {phase, code})} do
      {rank, {:ok, row_order}} when is_integer(rank) -> {:ok, {rank, row_order}}
      _not_compound -> :error
    end
  end

  @doc false
  @spec compound_category(phase(), atom()) ::
          :cleanup
          | :internal
          | :result_guard
          | :event_sink
          | :inspection_sink
          | :kernel_or_session
          | :publication
          | nil
  def compound_category(:result_cleanup, code)
      when code in [:provider_cleanup_timeout, :provider_cleanup_failed],
      do: :cleanup

  def compound_category(:internal, _code), do: :internal

  def compound_category(:result_cleanup, code)
      when code in [:result_invalid, :result_contract_failed, :result_limit_exceeded],
      do: :result_guard

  def compound_category(:execution, code)
      when code in [:event_capture_limit_exceeded, :event_sink_unavailable],
      do: :event_sink

  def compound_category(:execution, code)
      when code in [:inspection_capture_limit_exceeded, :inspection_sink_unavailable],
      do: :inspection_sink

  def compound_category(phase, _code)
      when phase in [:local_preflight, :active_preflight, :provider_acquisition, :execution],
      do: :kernel_or_session

  def compound_category(:publication, _code), do: :publication
  def compound_category(_phase, _code), do: nil

  @spec subject_policy(phase(), atom()) :: :required | :optional | :forbidden
  def subject_policy(:host, :installation_revision_missing), do: :required
  def subject_policy(:host, code) when code in @endpoint_codes, do: :required

  # A missing bundle requirement describes the capability surface assembled
  # from all providers granted to an environment. No single occurrence is the
  # authoritative cause, so attributing one would be arbitrary.
  def subject_policy(:provider_acquisition, :capability_requirement_missing), do: :forbidden

  # The one active-preflight outcome that belongs to the operation rather than
  # to an occurrence. A budget spent before or between occurrences cannot be
  # attributed to any of them, and naming an arbitrary one would report a
  # provider as unreachable when nothing had reached it yet.
  def subject_policy(:active_preflight, :connectivity_timeout), do: :forbidden

  # The environment file is named by `--env-file` or by the project host block,
  # so it belongs to the invocation rather than to any one installed provider.
  def subject_policy(:local_preflight, code)
      when code in [
             :environment_file_not_found,
             :environment_file_not_regular,
             :environment_file_unreadable,
             :environment_file_too_large,
             :environment_file_invalid_utf8
           ],
      do: :forbidden

  def subject_policy(phase, code) do
    cond do
      phase in [:provider_declaration, :local_preflight, :active_preflight, :provider_acquisition] ->
        :required

      phase == :execution and code == :provider_failed ->
        :required

      phase == :result_cleanup and
          code in [:provider_cleanup_failed, :provider_cleanup_timeout] ->
        :optional

      true ->
        :forbidden
    end
  end

  @spec subject_operations(phase(), atom()) :: [atom()]
  def subject_operations(:host, :installation_revision_missing), do: [:declaration]
  def subject_operations(:host, code) when code in @endpoint_codes, do: [:declaration]
  def subject_operations(:provider_declaration, :provider_unknown), do: [:declaration]

  def subject_operations(:provider_declaration, code)
      when code in [
             :selection_invalid,
             :selection_unverifiable,
             :placement_denied,
             :data_policy_denied
           ],
      do: [:selection]

  def subject_operations(:provider_declaration, :dependency_invalid), do: [:declaration]
  def subject_operations(:local_preflight, _code), do: [:local]
  def subject_operations(:active_preflight, :provider_application_unavailable), do: [:application]

  def subject_operations(:active_preflight, code)
      when code in [
             :selection_rejected,
             :selection_validation_failed,
             :selection_validation_timeout
           ],
      do: [:selection]

  def subject_operations(:active_preflight, :credential_unavailable),
    do: [:credentials, :authorization]

  def subject_operations(:active_preflight, code)
      when code in [
             :authorization_required,
             :authorization_rejected,
             :authorization_unavailable
           ],
      do: [:authorization]

  def subject_operations(:active_preflight, :authentication_rejected),
    do: [:authorization, :connectivity, :acquisition]

  def subject_operations(:active_preflight, code)
      when code in [
             :connectivity_rejected,
             :connectivity_protocol_error,
             :connectivity_unavailable
           ],
      do: [:authorization, :connectivity]

  def subject_operations(:active_preflight, _code), do: [:connectivity]
  def subject_operations(:provider_acquisition, _code), do: [:acquisition]
  def subject_operations(:execution, :provider_failed), do: [:execution]

  def subject_operations(:result_cleanup, code)
      when code in [:provider_cleanup_failed, :provider_cleanup_timeout],
      do: [:cleanup]

  def subject_operations(_phase, _code), do: []

  @doc false
  @spec doctor_application_rows() :: [row()]
  def doctor_application_rows do
    Enum.filter(rows(), fn row ->
      row.phase == :application and row.code not in [:override_invalid, :event_identity_conflict]
    end)
  end

  @doc false
  @spec doctor_finding_rows() :: [row()]
  def doctor_finding_rows, do: doctor_application_rows() ++ doctor_attributable_rows()

  # Both answer for `--authorize-mcp`, which only `run` accepts, so doctor can
  # never produce them. They are subject-bearing local-preflight rows and would
  # otherwise be attributed to a doctor check that cannot report them.
  @run_only_local_codes [:authorization_target_unknown, :authorization_not_applicable]

  @doc false
  @spec doctor_attributable_rows() :: [row()]
  def doctor_attributable_rows do
    operations = [:local, :selection, :credentials, :authorization, :connectivity]

    Enum.filter(rows(), fn row ->
      row.phase in [:local_preflight, :active_preflight, :provider_acquisition] and
        row.code not in @run_only_local_codes and
        subject_policy(row.phase, row.code) != :forbidden and
        Enum.any?(subject_operations(row.phase, row.code), fn subject_operation ->
          doctor_report_operation(subject_operation) in operations
        end)
    end)
  end

  @doc false
  @spec doctor_failure_codes_by_operation() :: %{atom() => [atom()]}
  def doctor_failure_codes_by_operation do
    operations = [:local, :selection, :credentials, :authorization, :connectivity]

    for row <- doctor_attributable_rows(),
        subject_operation <- subject_operations(row.phase, row.code),
        report_operation = doctor_report_operation(subject_operation),
        report_operation in operations,
        reduce: %{} do
      codes -> Map.update(codes, report_operation, [row.code], &[row.code | &1])
    end
    |> Map.new(fn {operation, codes} -> {operation, codes |> Enum.uniq() |> Enum.sort()} end)
  end

  defp doctor_report_operation(:acquisition), do: :connectivity
  defp doctor_report_operation(operation), do: operation

  @spec source_kinds(phase(), atom()) :: [atom()]
  def source_kinds(:host, :installation_revision_missing), do: []
  def source_kinds(:host, code) when code in @endpoint_codes, do: []
  def source_kinds(:host, _code), do: [:host]

  def source_kinds(:application, code)
      when code in [
             :application_unavailable,
             :application_not_found,
             :schema_violation,
             :installed_limit_exceeded,
             :required_property_missing,
             :event_identity_conflict
           ],
      do: [:application]

  def source_kinds(:application, code) when code in [:invalid_json, :duplicate_property],
    do: [:application, :external_input, :input_contract, :result_contract]

  def source_kinds(:application, :reference_missing),
    do: [:application, :external_input, :component, :input_contract, :result_contract]

  def source_kinds(:application, :document_limit_exceeded),
    do: [
      :application,
      :external_input,
      :component,
      :input_contract,
      :result_contract,
      :component_override
    ]

  def source_kinds(:application, :contract_invalid),
    do: [:application, :input_contract, :result_contract]

  def source_kinds(:application, :input_invalid),
    do: [:application, :external_input]

  def source_kinds(:application, :input_contract_failed),
    do: [:application, :external_input, :input_contract]

  def source_kinds(:application, :override_invalid), do: [:component_override]

  def source_kinds(:bundle, _code), do: [:component]
  def source_kinds(:execution, code) when code != :provider_failed, do: [:runtime]

  def source_kinds(:result_cleanup, code)
      when code in [:result_invalid, :result_contract_failed, :result_limit_exceeded],
      do: [:result_contract]

  def source_kinds(:internal, _code), do: [:runtime]
  def source_kinds(_phase, _code), do: []

  @spec provider_activity_policy(phase(), atom()) :: false | true | :boolean
  def provider_activity_policy(phase, _code)
      when phase in [
             :arguments,
             :host,
             :application,
             :bundle,
             :provider_declaration,
             :destination
           ],
      do: false

  # These two phases span the marker, so neither can assert one value. Their
  # producers carry the evidence: audited local checks and pre-callback active
  # failures report false, while unrestricted checks, authorization, and
  # provider-facing active work report true.
  # The audited-local step runs before activity and reports false; the
  # `:unverified` step runs after it and reports true. They describe the same
  # conditions through the same codes and differ only here, which is what the
  # flag is for — pinning the phase would force one of the two steps to borrow
  # another phase's codes and, with them, an operation name that did not fail.
  # These three answer for the invocation rather than for a provider occurrence
  # and are all decided before any provider runs, so unlike the rest of their
  # phase they can assert no activity rather than admitting either value.
  def provider_activity_policy(:local_preflight, code)
      when code in [
             :environment_file_not_found,
             :environment_file_not_regular,
             :environment_file_unreadable,
             :environment_file_too_large,
             :environment_file_invalid_utf8,
             :authorization_target_unknown,
             :authorization_not_applicable
           ],
      do: false

  def provider_activity_policy(phase, _code)
      when phase in [:local_preflight, :active_preflight],
      do: :boolean

  def provider_activity_policy(:provider_acquisition, :capability_requirement_missing),
    do: :boolean

  def provider_activity_policy(:provider_acquisition, _code), do: true

  def provider_activity_policy(:execution, :provider_failed), do: true

  def provider_activity_policy(:result_cleanup, code)
      when code in [:provider_cleanup_failed, :provider_cleanup_timeout],
      do: true

  def provider_activity_policy(_phase, _code), do: :boolean

  @spec path_policy(phase(), atom(), atom() | nil) :: :optional | :forbidden
  def path_policy(_phase, _code, nil), do: :forbidden

  def path_policy(:host, code, :host)
      when code in [:host_schema_invalid, :installed_limit_invalid],
      do: :optional

  def path_policy(:application, code, :application)
      when code in [
             :invalid_json,
             :duplicate_property,
             :schema_violation,
             :installed_limit_exceeded,
             :required_property_missing,
             :contract_invalid,
             :input_contract_failed,
             :event_identity_conflict
           ],
      do: :optional

  def path_policy(:application, code, :external_input)
      when code in [:invalid_json, :duplicate_property, :input_contract_failed],
      do: :optional

  def path_policy(:application, :override_invalid, :component_override), do: :optional

  def path_policy(:application, code, kind)
      when kind in [:input_contract, :result_contract] and
             code in [
               :invalid_json,
               :duplicate_property,
               :contract_invalid,
               :input_contract_failed
             ],
      do: :optional

  def path_policy(:result_cleanup, :result_contract_failed, :result_contract), do: :optional
  def path_policy(_phase, _code, _source_kind), do: :forbidden

  @spec subject_occurrence_policy(phase(), atom(), atom()) ::
          :required | :optional | :forbidden
  def subject_occurrence_policy(:provider_declaration, :dependency_invalid, :declaration),
    do: :forbidden

  def subject_occurrence_policy(:provider_declaration, _code, _operation), do: :required

  # An authorization target comes from `--authorize-mcp`, which names an alias
  # and not a selection slot. The unknown-target case has no occurrence to name
  # by definition: the alias the operator typed appears in no selection at all.
  def subject_occurrence_policy(:local_preflight, code, _operation)
      when code in [:authorization_target_unknown, :authorization_not_applicable],
      do: :forbidden

  def subject_occurrence_policy(:local_preflight, _code, _operation), do: :required

  def subject_occurrence_policy(:active_preflight, code, _operation)
      when code in [:provider_application_unavailable, :credential_unavailable],
      do: :forbidden

  def subject_occurrence_policy(:active_preflight, code, _operation)
      when code in [
             :selection_rejected,
             :selection_validation_failed,
             :selection_validation_timeout
           ],
      do: :required

  def subject_occurrence_policy(:active_preflight, _code, operation)
      when operation in [:connectivity, :acquisition],
      do: :required

  def subject_occurrence_policy(:active_preflight, _code, :authorization), do: :optional
  def subject_occurrence_policy(:provider_acquisition, _code, _operation), do: :required
  def subject_occurrence_policy(:execution, :provider_failed, _operation), do: :required

  def subject_occurrence_policy(:result_cleanup, code, _operation)
      when code in [:provider_cleanup_failed, :provider_cleanup_timeout],
      do: :forbidden

  def subject_occurrence_policy(_phase, _code, _operation), do: :forbidden
end
