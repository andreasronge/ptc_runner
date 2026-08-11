defmodule PtcRunner.Kernel.OwnerFailure do
  @moduledoc false

  alias PtcRunner.Kernel.Attestation

  @stages [:not_started, :incomplete]

  @enforce_keys [:reason, :provider_activity, :stage, :attestation]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @opaque t :: %__MODULE__{
            reason: term(),
            provider_activity: boolean(),
            stage: :not_started | :incomplete,
            attestation: binary()
          }

  @doc false
  @spec new!(term(), boolean(), :not_started | :incomplete) :: t()
  def new!(reason, provider_activity, stage)
      when is_boolean(provider_activity) and stage in @stages do
    failure = %__MODULE__{
      reason: reason,
      provider_activity: provider_activity,
      stage: stage,
      attestation: <<>>
    }

    %{failure | attestation: Attestation.attest(__MODULE__, payload(failure))}
  end

  @doc false
  @spec evidence(term()) ::
          {:ok, term(), boolean(), :not_started | :incomplete}
          | {:error, :invalid_owner_failure}
  def evidence(%__MODULE__{attestation: attestation} = failure) do
    if Enum.sort(Map.keys(failure)) == @field_keys and
         is_boolean(failure.provider_activity) and failure.stage in @stages and
         Attestation.valid?(__MODULE__, payload(failure), attestation) do
      {:ok, failure.reason, failure.provider_activity, failure.stage}
    else
      {:error, :invalid_owner_failure}
    end
  end

  def evidence(_failure), do: {:error, :invalid_owner_failure}

  @doc false
  @spec evidence_or_unknown(term(), term(), :not_started | :incomplete) ::
          {term(), boolean(), :not_started | :incomplete}
  def evidence_or_unknown(failure, fallback_reason, fallback_stage)
      when fallback_stage in @stages do
    case evidence(failure) do
      {:ok, reason, provider_activity, stage} ->
        {reason, provider_activity, stage}

      {:error, :invalid_owner_failure} ->
        {fallback_reason, true, fallback_stage}
    end
  end

  defp payload(failure),
    do: {failure.reason, failure.provider_activity, failure.stage}
end
