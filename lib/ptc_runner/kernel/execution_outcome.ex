defmodule PtcRunner.Kernel.ExecutionOutcome do
  @moduledoc """
  Sealed, path-free evidence captured at the one-shot execution boundary.

  The outcome freezes the effective result class, result-contract decision,
  terminal canonical events, and optional private inspection records while the
  execution sinks are still live. Publication can therefore run after those
  sinks stop without consulting a `PtcRunner.Kernel.RunConfig`, reopening an
  execution resource, or re-deriving disclosure authority.

  This is an in-VM construction attestation, not a security boundary against
  trusted code running in the same VM.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.Error
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.Result
  alias PtcRunner.Kernel.ValueContract

  @enforce_keys [
    :result,
    :result_class,
    :result_contract,
    :terminal_batch,
    :inspection,
    :publication_binding,
    :attestation
  ]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @type result :: {:ok, Result.t()} | {:error, Error.t()}
  @type result_class :: :normal | :private
  @type result_contract :: :ok | {:error, {:result_contract_failed, map()}}
  @type terminal_batch :: {:ok, [map()]} | {:error, atom()}
  @type inspection :: :disabled | {:ok, [map()]} | {:error, :inspection_sink_error}
  @type publication_evidence :: %{
          result: result(),
          result_class: result_class(),
          result_contract: result_contract(),
          terminal_batch: terminal_batch(),
          inspection: inspection()
        }

  @opaque t :: %__MODULE__{
            result: result(),
            result_class: result_class(),
            result_contract: result_contract(),
            terminal_batch: terminal_batch(),
            inspection: inspection(),
            publication_binding: binary(),
            attestation: binary()
          }

  @doc false
  @spec capture(
          result(),
          terminal_batch(),
          EventSink.t(),
          InspectionSink.t() | nil,
          ValueContract.t() | nil,
          PublicationAuthority.t()
        ) :: {:ok, t()} | {:error, :invalid_execution_outcome}
  def capture(result, terminal_batch, event_sink, inspection_sink, contract, authority) do
    outcome = %__MODULE__{
      result: result,
      result_class: classify(event_sink),
      result_contract: validate_result(result, contract),
      terminal_batch: terminal_batch,
      inspection: capture_inspection(inspection_sink),
      publication_binding: publication_binding(authority),
      attestation: <<>>
    }

    if fields_valid?(outcome) do
      {:ok, %{outcome | attestation: Attestation.attest(__MODULE__, payload(outcome))}}
    else
      {:error, :invalid_execution_outcome}
    end
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{attestation: attestation} = outcome),
    do:
      fields_valid?(outcome) and
        Attestation.valid?(__MODULE__, payload(outcome), attestation)

  def valid?(_outcome), do: false

  @doc false
  @spec open(term(), term()) ::
          {:ok, publication_evidence()} | {:error, :invalid_execution_outcome}
  def open(%__MODULE__{} = outcome, authority) do
    if valid?(outcome) and
         PublicationAuthority.matches?(authority, outcome.publication_binding) do
      {:ok,
       Map.take(outcome, [
         :result,
         :result_class,
         :result_contract,
         :terminal_batch,
         :inspection
       ])}
    else
      {:error, :invalid_execution_outcome}
    end
  end

  def open(_outcome, _authority), do: {:error, :invalid_execution_outcome}

  defp classify(event_sink) do
    case EventSink.policy(event_sink) do
      :normal -> :normal
      _other -> :private
    end
  end

  defp capture_inspection(nil), do: :disabled
  defp capture_inspection(%InspectionSink{} = sink), do: InspectionSink.records(sink)
  defp capture_inspection(_sink), do: {:error, :inspection_sink_error}

  defp validate_result(_result, nil), do: :ok

  defp validate_result({:ok, %Result{value: value}}, %ValueContract{} = contract) do
    case ValueContract.json_value(value) do
      {:ok, public} ->
        if ValueContract.valid?(contract, public),
          do: :ok,
          else: {:error, {:result_contract_failed, ValueContract.classify(contract, public)}}

      {:error, _reason} ->
        {:error, {:result_contract_failed, %{value_kind: :invalid_json}}}
    end
  end

  defp validate_result(_result, %ValueContract{}), do: :ok
  defp validate_result(_result, _contract), do: :invalid

  defp fields_valid?(outcome) do
    Enum.sort(Map.keys(outcome)) == @field_keys and
      result_valid?(outcome.result) and
      result_terminal_coherent?(outcome.result, outcome.terminal_batch) and
      outcome.result_class in [:normal, :private] and
      result_contract_valid?(outcome.result_contract) and
      terminal_batch_valid?(outcome.terminal_batch) and
      inspection_valid?(outcome.inspection) and
      is_binary(outcome.publication_binding) and byte_size(outcome.publication_binding) == 32
  end

  defp result_valid?({:ok, %Result{usage: usage, evaluation_memory: memory}}),
    do: is_map(usage) and is_map(memory)

  defp result_valid?(
         {:error, %Error{kind: kind, reason: reason, details: details, usage: usage}}
       ),
       do: is_atom(kind) and is_atom(reason) and is_map(details) and is_map(usage)

  defp result_valid?(_result), do: false

  defp result_terminal_coherent?({:ok, _result}, {:error, _reason}), do: false
  defp result_terminal_coherent?(_result, _terminal_batch), do: true

  defp result_contract_valid?(:ok), do: true

  defp result_contract_valid?({:error, {:result_contract_failed, details}}),
    do: is_map(details)

  defp result_contract_valid?(_result_contract), do: false

  defp terminal_batch_valid?({:ok, events}),
    do: is_list(events) and Enum.all?(events, &is_map/1)

  defp terminal_batch_valid?({:error, reason}), do: is_atom(reason)
  defp terminal_batch_valid?(_terminal_batch), do: false

  defp inspection_valid?(:disabled), do: true
  defp inspection_valid?({:ok, records}), do: is_list(records) and Enum.all?(records, &is_map/1)
  defp inspection_valid?({:error, :inspection_sink_error}), do: true
  defp inspection_valid?(_inspection), do: false

  defp publication_binding(authority), do: PublicationAuthority.binding(authority)

  defp payload(outcome) do
    {
      outcome.result,
      outcome.result_class,
      outcome.result_contract,
      outcome.terminal_batch,
      outcome.inspection,
      outcome.publication_binding
    }
  end
end
