defmodule PtcRunner.Kernel.CommandSubject do
  @moduledoc "Closed provider locator used by command diagnostics."

  @operations [
    :declaration,
    :selection,
    :local,
    :application,
    :credentials,
    :authorization,
    :connectivity,
    :acquisition,
    :execution,
    :cleanup
  ]

  @enforce_keys [:kind, :name, :operation, :occurrence]
  defstruct @enforce_keys

  @type operation ::
          :declaration
          | :selection
          | :local
          | :application
          | :credentials
          | :authorization
          | :connectivity
          | :acquisition
          | :execution
          | :cleanup

  @type occurrence :: %{destination: :workflow | :mission, index: 0..31} | nil

  @type t :: %__MODULE__{
          kind: :provider,
          name: binary(),
          operation: operation(),
          occurrence: occurrence()
        }

  @spec provider(binary(), operation(), occurrence()) ::
          {:ok, t()} | {:error, :invalid_command_subject}
  def provider(name, operation, occurrence \\ nil)

  def provider(name, operation, occurrence)
      when is_binary(name) and operation in @operations do
    if valid_name?(name) and valid_occurrence?(occurrence) do
      {:ok,
       %__MODULE__{
         kind: :provider,
         name: name,
         operation: operation,
         occurrence: occurrence
       }}
    else
      {:error, :invalid_command_subject}
    end
  end

  def provider(_name, _operation, _occurrence), do: {:error, :invalid_command_subject}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = subject) do
    %{
      "kind" => "provider",
      "name" => subject.name,
      "operation" => Atom.to_string(subject.operation),
      "occurrence" => occurrence_map(subject.occurrence)
    }
  end

  defp occurrence_map(nil), do: nil

  defp occurrence_map(%{destination: destination, index: index}),
    do: %{"destination" => Atom.to_string(destination), "index" => index}

  defp valid_name?(name),
    do: name =~ ~r/\A[a-z][a-z0-9._-]{0,127}\z/

  defp valid_occurrence?(nil), do: true

  defp valid_occurrence?(%{destination: destination, index: index} = occurrence),
    do:
      map_size(occurrence) == 2 and destination in [:workflow, :mission] and is_integer(index) and
        index in 0..31

  defp valid_occurrence?(_occurrence), do: false
end
