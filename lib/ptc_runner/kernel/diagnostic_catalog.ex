defmodule PtcRunner.Kernel.DiagnosticCatalog do
  @moduledoc """
  Authoritative closed V1 command diagnostic catalog.

  Each row owns the phase, code, exit status, retryability, and bounded default
  message. Renderers and schemas derive their admitted pairs from this table;
  lower-level reasons never add a public code.
  """

  @rows [
    {:arguments, :invalid_command, 2, false, "use one of the supported commands"},
    {:arguments, :invalid_arguments, 2, false, "use the documented arguments for this command"},
    {:arguments, :conflicting_arguments, 2, false,
     "choose only one option from the conflicting argument group"},
    {:host, :host_unavailable, 3, false, "the host configuration is unavailable"},
    {:host, :host_invalid, 3, false, "the host configuration is invalid"},
    {:host, :host_schema_invalid, 3, false, "the host configuration does not satisfy its schema"},
    {:host, :installed_limit_invalid, 3, false, "an installed limit is invalid"},
    {:host, :installation_revision_missing, 3, false,
     "an installed provider is missing its behavior revision"},
    {:application, :application_unavailable, 3, false, "the application is unavailable"},
    {:application, :invalid_json, 3, false, "an application document is not valid JSON"},
    {:application, :duplicate_property, 3, false,
     "an application document contains a duplicate property"},
    {:application, :schema_violation, 3, false,
     "the application manifest does not satisfy its schema"},
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
    {:bundle, :entry_invalid, 3, false, "the workflow entry is not a public bundle export"},
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
    {:destination, :destination_exists, 7, false, "an artifact destination already exists"},
    {:destination, :private_destination_required, 7, false,
     "the run requires an authorized private destination"},
    {:destination, :recovery_reservation_failed, 7, false,
     "the private result recovery reservation failed"},
    {:local_preflight, :environment_unavailable, 4, false,
     "a required local environment is unavailable"},
    {:local_preflight, :adapter_unavailable, 4, false,
     "a required provider adapter is unavailable"},
    {:local_preflight, :launcher_unavailable, 4, false,
     "a required provider launcher is unavailable"},
    {:local_preflight, :local_check_timeout, 4, false, "an audited-local check timed out"},
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
    {:active_preflight, :authorization_unavailable, 4, true,
     "the authorization service is temporarily unavailable"},
    {:active_preflight, :connectivity_unavailable, 4, true,
     "the provider connectivity operation is temporarily unavailable"},
    {:active_preflight, :connectivity_rate_limited, 4, true,
     "the provider connectivity operation is rate limited"},
    {:provider_acquisition, :provider_unavailable, 4, false,
     "the selected provider could not be acquired"},
    {:provider_acquisition, :provider_protocol_error, 4, false,
     "the selected provider returned an invalid acquisition response"},
    {:provider_acquisition, :provider_policy_changed, 4, false,
     "the selected provider policy changed during acquisition"},
    {:execution, :workflow_failed, 5, false, "the workflow failed"},
    {:execution, :mission_failed, 5, false, "a subordinate mission failed"},
    {:execution, :runtime_limit_exceeded, 6, false, "a runtime limit was exceeded"},
    {:execution, :run_timeout, 6, false, "the run duration limit was exceeded"},
    {:execution, :provider_failed, 5, false, "a provider failed during execution"},
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

  @spec subject_policy(phase(), atom()) :: :required | :optional | :forbidden
  def subject_policy(:host, :installation_revision_missing), do: :required

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

  @spec source_kinds(phase(), atom()) :: [atom()]
  def source_kinds(:host, :installation_revision_missing), do: []
  def source_kinds(:host, _code), do: [:host]

  def source_kinds(:application, code)
      when code in [
             :application_unavailable,
             :schema_violation,
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
             :destination,
             :local_preflight
           ],
      do: false

  def provider_activity_policy(phase, _code)
      when phase in [:active_preflight, :provider_acquisition],
      do: true

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
