defmodule PtcRunner.Kernel.CommandDiagnostic do
  @moduledoc """
  Closed privacy-safe command diagnostic.

  Construction accepts only a catalog pair, a catalog-authorized message, and
  typed safe provenance. Contract-authorized paths must also match the sealed
  contract authority bound to their source classification. Rendering never
  inspects a lower-level reason or rejected value. Catalog-authorized dynamic
  message shapes contain only fixed literals plus bounded PTC-Lisp symbol
  names, sealed provider-selection field names, a catalog-validated runtime
  ceiling or optional-limit request, a closed host budget prerequisite, a
  bounded agent turn ceiling, an opaque replay request hash, or a closed
  component-override field rule. Compile messages require
  component-source provenance; a missing capability message is rebuilt from
  the frozen bundle's sorted tool requirements. A missing MCP tool message may
  retain only the validated, declaration-owned upstream name and carries no
  provider catalog payload. Kernel runtime and replay messages require fixed
  runtime provenance. An agent turn-limit message and an out-of-range agent
  option have no source because `max_turns` and the other bounded options
  belong to one `agent.core` call rather than a host or manifest document. A
  provider-selection message names sealed rule fields and a closed rule; it
  has no source because the provider subject already locates the slot. Every
  other message is the catalog literal.

  `notes` is reserved and always empty: the published V4 envelope schema pins
  it to `{"const": []}`, so a populated array would invalidate the envelope for
  every strict V4 consumer. Reporting a rejected value against the bound it
  broke is a later-version change, not a producer-side one.
  """

  alias PtcRunner.Kernel.AgentConfigDiagnostic
  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.ComponentOverrideDiagnostic
  alias PtcRunner.Kernel.ContractSchemaDiagnostic
  alias PtcRunner.Kernel.DiagnosticCatalog
  alias PtcRunner.Kernel.ExplicitFailureDiagnostic
  alias PtcRunner.Kernel.LimitConfigurationDiagnostic
  alias PtcRunner.Kernel.LLMReplayFixtureDiagnostic
  alias PtcRunner.Kernel.ModelOutputDiagnostic
  alias PtcRunner.Kernel.OptionalBudgetDiagnostic
  alias PtcRunner.Kernel.ResultContractDiagnostic
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.Kernel.SchemaViolationDiagnostic
  alias PtcRunner.Kernel.SelectionRulesDiagnostic

  @enforce_keys [
    :phase,
    :code,
    :message,
    :source,
    :path,
    :span,
    :subject,
    :notes,
    :retryable,
    :provider_activity,
    :exit_status
  ]
  defstruct @enforce_keys

  @type span :: %{start_byte: non_neg_integer(), end_byte: non_neg_integer()} | nil

  @type t :: %__MODULE__{
          phase: DiagnosticCatalog.phase(),
          code: atom(),
          message: binary(),
          source: CommandSource.t() | nil,
          path: CommandPath.t() | nil,
          span: span(),
          subject: CommandSubject.t() | nil,
          notes: [],
          retryable: boolean(),
          provider_activity: boolean(),
          exit_status: 2 | 3 | 4 | 5 | 6 | 7 | 70
        }

  @spec new(DiagnosticCatalog.phase(), atom(), keyword()) ::
          {:ok, t()} | {:error, :invalid_command_diagnostic}
  def new(phase, code, opts \\ [])

  def new(phase, code, opts) when is_list(opts) do
    allowed = [:message, :source, :path, :span, :subject, :provider_activity]

    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- keys -- allowed == [] and length(keys) == MapSet.size(MapSet.new(keys)),
         {:ok, row} <- DiagnosticCatalog.fetch(phase, code),
         message <- Keyword.get(opts, :message, row.message),
         source <- Keyword.get(opts, :source),
         path <- Keyword.get(opts, :path),
         span <- Keyword.get(opts, :span),
         subject <- Keyword.get(opts, :subject),
         activity <- Keyword.get(opts, :provider_activity, false),
         true <- DiagnosticCatalog.valid_message?(phase, code, message),
         true <- valid_source?(source),
         true <- valid_source_for_row?(source, row),
         true <- valid_message_source?(message, row, source),
         true <- valid_path?(path),
         true <- valid_path_for_row?(path, source, row),
         true <- valid_span?(span, source),
         true <- valid_subject?(subject),
         true <- valid_subject_for_row?(subject, row),
         true <- valid_activity_for_row?(activity, row) do
      {:ok,
       %__MODULE__{
         phase: row.phase,
         code: row.code,
         message: message,
         source: source,
         path: path,
         span: span,
         subject: subject,
         notes: [],
         retryable: row.retryable,
         provider_activity: activity,
         exit_status: row.exit_status
       }}
    else
      _invalid -> {:error, :invalid_command_diagnostic}
    end
  end

  def new(_phase, _code, _opts), do: {:error, :invalid_command_diagnostic}

  @spec new!(DiagnosticCatalog.phase(), atom(), keyword()) :: t()
  def new!(phase, code, opts \\ []) do
    {:ok, diagnostic} = new(phase, code, opts)
    diagnostic
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = diagnostic) do
    opts = [
      message: diagnostic.message,
      source: diagnostic.source,
      path: diagnostic.path,
      span: diagnostic.span,
      subject: diagnostic.subject,
      provider_activity: diagnostic.provider_activity
    ]

    new(diagnostic.phase, diagnostic.code, opts) == {:ok, diagnostic}
  end

  def valid?(_diagnostic), do: false

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = diagnostic) do
    if not valid?(diagnostic), do: raise(ArgumentError, "invalid command diagnostic")

    %{
      "phase" => Atom.to_string(diagnostic.phase),
      "code" => Atom.to_string(diagnostic.code),
      "message" => diagnostic.message,
      "source" => source_map(diagnostic.source),
      "path" => path_map(diagnostic.path),
      "span" => span_map(diagnostic.span),
      "subject" => subject_map(diagnostic.subject),
      "notes" => [],
      "retryable" => diagnostic.retryable,
      "provider_activity" => diagnostic.provider_activity
    }
  end

  defp path_map(nil), do: nil
  defp path_map(path), do: CommandPath.to_pointer(path)

  defp source_map(nil), do: nil
  defp source_map(source), do: CommandSource.to_map(source)

  defp subject_map(nil), do: nil
  defp subject_map(subject), do: CommandSubject.to_map(subject)

  defp span_map(nil), do: nil

  defp span_map(%{start_byte: start_byte, end_byte: end_byte}),
    do: %{"start_byte" => start_byte, "end_byte" => end_byte}

  defp valid_source?(nil), do: true

  defp valid_source?(%CommandSource{} = source), do: CommandSource.valid?(source)

  defp valid_source?(_source), do: false

  defp valid_subject?(nil), do: true

  defp valid_subject?(
         %CommandSubject{
           name: name,
           operation: operation,
           occurrence: occurrence
         } = subject
       ),
       do: CommandSubject.provider(name, operation, occurrence) == {:ok, subject}

  defp valid_subject?(_subject), do: false

  defp valid_source_for_row?(nil, _row), do: true

  defp valid_source_for_row?(%CommandSource{kind: kind}, row),
    do: kind in DiagnosticCatalog.source_kinds(row.phase, row.code)

  defp valid_subject_for_row?(subject, row) do
    case DiagnosticCatalog.subject_policy(row.phase, row.code) do
      :required -> subject_operation_allowed?(subject, row)
      :optional -> is_nil(subject) or subject_operation_allowed?(subject, row)
      :forbidden -> is_nil(subject)
    end
  end

  defp subject_operation_allowed?(
         %CommandSubject{operation: operation, occurrence: occurrence},
         row
       ) do
    operation in DiagnosticCatalog.subject_operations(row.phase, row.code) and
      valid_occurrence_for_row?(occurrence, operation, row)
  end

  defp subject_operation_allowed?(_subject, _row), do: false

  defp valid_occurrence_for_row?(occurrence, operation, row) do
    case DiagnosticCatalog.subject_occurrence_policy(row.phase, row.code, operation) do
      :required -> not is_nil(occurrence)
      :optional -> true
      :forbidden -> is_nil(occurrence)
    end
  end

  defp valid_activity_for_row?(activity, row) when is_boolean(activity) do
    case DiagnosticCatalog.provider_activity_policy(row.phase, row.code) do
      false -> activity == false
      true -> activity == true
      :boolean -> true
    end
  end

  defp valid_activity_for_row?(_activity, _row), do: false

  defp valid_path?(nil), do: true

  defp valid_path?(%CommandPath{} = path), do: CommandPath.valid?(path)

  defp valid_path?(_segments), do: false

  defp valid_path_for_row?(nil, _source, _row), do: true

  defp valid_path_for_row?(
         %CommandPath{authority: authority},
         %CommandSource{kind: kind} = source,
         row
       ) do
    DiagnosticCatalog.path_policy(row.phase, row.code, kind) == :optional and
      valid_path_authority?(authority, source, row)
  end

  defp valid_path_for_row?(_path, _source, _row), do: false

  defp valid_path_authority?(
         :project,
         %CommandSource{kind: :project, contract_authority: nil},
         %{phase: :project}
       ),
       do: true

  defp valid_path_authority?(
         :manifest,
         %CommandSource{kind: :application, contract_authority: nil},
         %{phase: :application}
       ),
       do: true

  defp valid_path_authority?(
         :host,
         %CommandSource{kind: :host, contract_authority: nil},
         %{phase: :host}
       ),
       do: true

  # A contract that failed to compile has no compiled contract authority to
  # bind, so its fault is located inside the submitted schema document instead.
  # The authority carries the document's logical name and must equal the source
  # the diagnostic names, so a pointer minted for one contract file can never be
  # attached to a diagnostic about another.
  defp valid_path_authority?(
         {:value_contract_schema, name},
         %CommandSource{kind: kind, name: name, contract_authority: nil},
         %{phase: :application, code: :contract_invalid}
       )
       when kind in [:input_contract, :result_contract],
       do: true

  defp valid_path_authority?(
         :component_override,
         %CommandSource{kind: :component_override, contract_authority: nil},
         %{phase: :application, code: :override_invalid}
       ),
       do: true

  defp valid_path_authority?(
         {:contract, authority},
         %CommandSource{kind: kind, contract_authority: authority},
         %{phase: :application, code: :input_contract_failed}
       )
       when kind in [:application, :external_input, :input_contract],
       do: true

  defp valid_path_authority?(
         {:contract, authority},
         %CommandSource{kind: kind, contract_authority: authority},
         %{phase: :application, code: code}
       )
       when kind in [:input_contract, :result_contract] and
              code in [:invalid_json, :duplicate_property, :contract_invalid],
       do: true

  defp valid_path_authority?(
         {:contract, authority},
         %CommandSource{kind: :result_contract, contract_authority: authority},
         %{phase: :result_cleanup, code: :result_contract_failed}
       ),
       do: true

  defp valid_path_authority?(_authority, _source, _row), do: false

  defp valid_span?(nil, _source), do: true

  defp valid_span?(
         %{start_byte: start_byte, end_byte: end_byte} = span,
         %CommandSource{byte_size: byte_size}
       ),
       do:
         map_size(span) == 2 and is_integer(start_byte) and is_integer(end_byte) and
           start_byte >= 0 and
           end_byte >= start_byte and is_integer(byte_size) and end_byte <= byte_size

  defp valid_span?(_span, _source), do: false

  defp valid_message_source?(message, %{message: message}, _source), do: true

  defp valid_message_source?(
         message,
         %{phase: :project, code: :project_schema_invalid},
         %CommandSource{kind: :project}
       ),
       do:
         SchemaViolationDiagnostic.valid_message?(
           :project,
           SchemaViolationDiagnostic.rules(:project, :project_schema_invalid),
           message
         )

  defp valid_message_source?(
         message,
         %{phase: :host, code: :host_schema_invalid},
         %CommandSource{kind: :host}
       ),
       do:
         SchemaViolationDiagnostic.valid_message?(
           :host,
           SchemaViolationDiagnostic.rules(:host, :host_schema_invalid),
           message
         )

  defp valid_message_source?(
         message,
         %{phase: :host, code: :installed_limit_invalid},
         %CommandSource{kind: :host}
       ),
       do: OptionalBudgetDiagnostic.valid_prerequisite_message?(message)

  defp valid_message_source?(
         message,
         %{phase: :application, code: code},
         %CommandSource{kind: :application}
       )
       when code in [:schema_violation, :required_property_missing],
       do:
         SchemaViolationDiagnostic.valid_message?(
           :application,
           SchemaViolationDiagnostic.rules(:application, code),
           message
         )

  defp valid_message_source?(
         message,
         %{phase: :result_cleanup, code: :result_contract_failed},
         %CommandSource{kind: :result_contract}
       ),
       do: ResultContractDiagnostic.valid_message?(message)

  defp valid_message_source?(
         message,
         %{phase: :application, code: :contract_invalid},
         %CommandSource{kind: kind}
       )
       when kind in [:input_contract, :result_contract],
       do: ContractSchemaDiagnostic.valid_message?(message)

  defp valid_message_source?(
         message,
         %{phase: :application, code: :override_invalid},
         %CommandSource{kind: :component_override}
       ),
       do: ComponentOverrideDiagnostic.valid_message?(message)

  defp valid_message_source?(
         _message,
         %{phase: :bundle, code: code},
         %CommandSource{kind: :component}
       )
       when code in [:undefined_variable, :duplicate_definition, :unknown_namespace],
       do: true

  defp valid_message_source?(
         _message,
         %{phase: :provider_acquisition, code: :capability_requirement_missing},
         nil
       ),
       do: true

  defp valid_message_source?(
         _message,
         %{phase: :bundle, code: :mission_capability_ungranted},
         nil
       ),
       do: true

  defp valid_message_source?(
         _message,
         %{phase: :provider_acquisition, code: :provider_tool_missing},
         nil
       ),
       do: true

  defp valid_message_source?(
         _message,
         %{phase: :provider_acquisition, code: :provider_protocol_version_unsupported},
         nil
       ),
       do: true

  defp valid_message_source?(
         message,
         %{phase: :execution, code: :runtime_limit_exceeded},
         %CommandSource{kind: :runtime}
       ),
       do:
         RuntimeLimitDiagnostic.subordinate_evaluations_message?(message) or
           RuntimeLimitDiagnostic.timeout_message?(message) or
           RuntimeLimitDiagnostic.heap_words_message?(message) or
           RuntimeLimitDiagnostic.protocol_errors_message?(message) or
           RuntimeLimitDiagnostic.budget_message?(message)

  defp valid_message_source?(
         message,
         %{phase: :execution, code: :runtime_limit_exceeded},
         nil
       ),
       do: RuntimeLimitDiagnostic.transcript_chars_message?(message)

  defp valid_message_source?(
         message,
         %{phase: :execution, code: :capability_quota_exceeded},
         %CommandSource{kind: :runtime}
       ),
       do: RuntimeLimitDiagnostic.capability_quota_limit_message?(message)

  defp valid_message_source?(
         message,
         %{phase: :execution, code: :turn_limit_exceeded},
         nil
       ),
       do: RuntimeLimitDiagnostic.agent_turns_message?(message)

  defp valid_message_source?(
         message,
         %{phase: :execution, code: :model_output_truncated},
         nil
       ),
       do: ModelOutputDiagnostic.valid_message?(message)

  # An explicit failure names no document: the retention outcome describes the
  # run's own artifacts, not a manifest the command can point a source at.
  defp valid_message_source?(
         message,
         %{phase: :execution, code: :explicit_failure},
         nil
       ),
       do: ExplicitFailureDiagnostic.valid_message?(message)

  defp valid_message_source?(
         message,
         %{phase: :execution, code: :run_timeout},
         %CommandSource{kind: :runtime}
       ),
       do: RuntimeLimitDiagnostic.run_duration_message?(message)

  defp valid_message_source?(
         message,
         %{phase: :execution, code: :invalid_agent_config},
         nil
       ),
       do: AgentConfigDiagnostic.valid_message?(message)

  defp valid_message_source?(
         message,
         %{phase: :result_cleanup, code: :result_limit_exceeded},
         nil
       ),
       do: RuntimeLimitDiagnostic.result_limit_message?(message)

  # The refused value lives in the manifest, so this one does name its document.
  defp valid_message_source?(
         message,
         %{phase: :application, code: :installed_limit_exceeded},
         %CommandSource{kind: :application}
       ),
       do: RuntimeLimitDiagnostic.installed_ceiling_message?(message)

  defp valid_message_source?(
         message,
         %{phase: :application, code: :limit_unavailable},
         %CommandSource{kind: :application}
       ),
       do: OptionalBudgetDiagnostic.valid_unavailable_message?(message)

  defp valid_message_source?(
         message,
         %{phase: :application, code: :limit_configuration_invalid},
         %CommandSource{kind: :application}
       ),
       do: LimitConfigurationDiagnostic.valid_message?(message)

  defp valid_message_source?(
         _message,
         %{phase: :execution, code: :replay_fixture_missing},
         %CommandSource{kind: :runtime}
       ),
       do: true

  # A refused replay fixture belongs to the host installation that named it, not
  # to a document the command can point a source at, so its bounded message
  # carries the provider subject alone.
  defp valid_message_source?(message, %{phase: :local_preflight, code: code}, nil)
       when code in [:environment_unavailable, :fixtures_unreadable],
       do: LLMReplayFixtureDiagnostic.valid_message?(message)

  defp valid_message_source?(
         message,
         %{phase: :provider_declaration, code: :selection_invalid},
         nil
       ),
       do: SelectionRulesDiagnostic.valid_message?(message)

  defp valid_message_source?(_message, _row, _source), do: false
end
