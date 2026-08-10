defmodule PtcRunner.Kernel.CommandDiagnostic do
  @moduledoc """
  Closed privacy-safe command diagnostic.

  Construction accepts only a catalog pair and typed safe provenance.
  Contract-authorized paths must also match the sealed contract authority bound
  to their source classification. Rendering never inspects a lower-level
  reason or rejected value.

  `notes` is reserved and always empty: the published V1 envelope schema pins
  it to `{"const": []}`, so a populated array would invalidate the envelope for
  every strict V1 consumer. Reporting a rejected value against the bound it
  broke is a later-version change, not a producer-side one.
  """

  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.DiagnosticCatalog

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
    allowed = [:source, :path, :span, :subject, :provider_activity]

    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- keys -- allowed == [] and length(keys) == MapSet.size(MapSet.new(keys)),
         {:ok, row} <- DiagnosticCatalog.fetch(phase, code),
         source <- Keyword.get(opts, :source),
         path <- Keyword.get(opts, :path),
         span <- Keyword.get(opts, :span),
         subject <- Keyword.get(opts, :subject),
         activity <- Keyword.get(opts, :provider_activity, false),
         true <- valid_source?(source),
         true <- valid_source_for_row?(source, row),
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
         message: row.message,
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
         %CommandSource{kind: kind, contract_authority: contract_authority},
         row
       ) do
    DiagnosticCatalog.path_policy(row.phase, row.code, kind) == :optional and
      valid_path_authority?(authority, contract_authority, kind, row)
  end

  defp valid_path_for_row?(_path, _source, _row), do: false

  defp valid_path_authority?(:manifest, nil, :application, %{phase: :application}), do: true
  defp valid_path_authority?(:host, nil, :host, %{phase: :host}), do: true

  defp valid_path_authority?(
         :component_override,
         nil,
         :component_override,
         %{phase: :application, code: :override_invalid}
       ),
       do: true

  defp valid_path_authority?(
         {:contract, authority},
         authority,
         kind,
         %{phase: :application, code: :input_contract_failed}
       )
       when kind in [:application, :external_input, :input_contract],
       do: true

  defp valid_path_authority?(
         {:contract, authority},
         authority,
         kind,
         %{phase: :application, code: code}
       )
       when kind in [:input_contract, :result_contract] and
              code in [:invalid_json, :duplicate_property, :contract_invalid],
       do: true

  defp valid_path_authority?(
         {:contract, authority},
         authority,
         :result_contract,
         %{phase: :result_cleanup, code: :result_contract_failed}
       ),
       do: true

  defp valid_path_authority?(_authority, _contract_authority, _kind, _row), do: false

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
end
