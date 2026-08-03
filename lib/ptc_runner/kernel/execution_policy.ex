defmodule PtcRunner.Kernel.ExecutionPolicy do
  @moduledoc """
  Destination-free event, inspection, and result policy for one execution.

  Artifact paths, object keys, file readers, and publication callbacks are not
  representable. The policy fixes all owner-affecting choices before the first
  event is emitted.
  """

  alias PtcRunner.Kernel.Attestation

  @enforce_keys [
    :event_policy,
    :run_id,
    :trace_id,
    :inspection_capture,
    :result_projection
  ]
  defstruct @enforce_keys ++ [attestation: nil]
  @field_keys Enum.sort([:__struct__, :attestation | @enforce_keys])

  @type t :: %__MODULE__{
          event_policy: :normal | :private,
          run_id: binary() | nil,
          trace_id: binary() | nil,
          inspection_capture: boolean(),
          result_projection: :native | :json,
          attestation: binary() | nil
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_execution_policy}
  @doc "Validates and seals one destination-free execution policy."
  def new(opts) when is_list(opts) do
    allowed = [:event_policy, :run_id, :trace_id, :inspection_capture, :result_projection]

    if Keyword.keyword?(opts) do
      policy = %__MODULE__{
        event_policy: Keyword.get(opts, :event_policy, :normal),
        run_id: Keyword.get(opts, :run_id),
        trace_id: Keyword.get(opts, :trace_id),
        inspection_capture: Keyword.get(opts, :inspection_capture, false),
        result_projection: Keyword.get(opts, :result_projection, :native)
      }

      if Keyword.keys(opts) -- allowed == [] and
           length(Keyword.keys(opts)) == MapSet.size(MapSet.new(Keyword.keys(opts))) and
           valid_shape?(policy) do
        {:ok, %{policy | attestation: Attestation.attest(__MODULE__, payload(policy))}}
      else
        {:error, :invalid_execution_policy}
      end
    else
      {:error, :invalid_execution_policy}
    end
  end

  def new(_opts), do: {:error, :invalid_execution_policy}

  @spec valid?(term()) :: boolean()
  @doc "Checks the policy's in-VM construction attestation."
  def valid?(%__MODULE__{attestation: attestation} = policy),
    do:
      Enum.sort(Map.keys(policy)) == @field_keys and valid_shape?(policy) and
        Attestation.valid?(__MODULE__, payload(policy), attestation)

  def valid?(_policy), do: false

  defp valid_shape?(policy) do
    policy.event_policy in [:normal, :private] and
      optional_id?(policy.run_id) and
      optional_id?(policy.trace_id) and
      is_boolean(policy.inspection_capture) and
      policy.result_projection in [:native, :json]
  end

  defp optional_id?(nil), do: true

  defp optional_id?(value) when is_binary(value) and byte_size(value) in 1..256,
    do: String.valid?(value)

  defp optional_id?(_value), do: false

  defp payload(policy) do
    {
      policy.event_policy,
      policy.run_id,
      policy.trace_id,
      policy.inspection_capture,
      policy.result_projection
    }
  end
end
