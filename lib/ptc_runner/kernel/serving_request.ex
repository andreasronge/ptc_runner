defmodule PtcRunner.Kernel.ServingRequest do
  @moduledoc """
  Sealed package and policy for input-free provider acquisition.

  Input authority is always normal. This request can prepare a provider plan,
  but cannot build or execute a run; only `ProviderExecution.open_serving/5`
  consumes it. Selected private inspection data refuses serving preparation
  with `:private_result_unservable`.
  """
  alias PtcRunner.Kernel.{ApplicationPackage, Attestation, ExecutionPolicy, RunRequest}
  @enforce_keys [:package, :policy]
  defstruct @enforce_keys ++ [attestation: nil]

  @type t :: %__MODULE__{
          package: ApplicationPackage.t(),
          policy: ExecutionPolicy.t(),
          attestation: binary() | nil
        }

  @spec new(ApplicationPackage.t(), ExecutionPolicy.t()) ::
          {:ok, t()} | {:error, :invalid_serving_request}
  def new(package, policy) do
    request = %__MODULE__{package: package, policy: policy}

    if valid_fields?(request) do
      {:ok, %{request | attestation: Attestation.attest(__MODULE__, {package, policy})}}
    else
      {:error, :invalid_serving_request}
    end
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = request) do
    Enum.sort(Map.keys(request)) == [:__struct__, :attestation, :package, :policy] and
      valid_fields?(request) and
      Attestation.valid?(__MODULE__, {request.package, request.policy}, request.attestation)
  end

  def valid?(_request), do: false

  @doc false
  @spec request_valid?(term()) :: boolean()
  def request_valid?(%__MODULE__{} = request), do: valid?(request)
  def request_valid?(request), do: RunRequest.valid?(request)

  @doc false
  @spec input_authority(t() | RunRequest.t()) :: :normal | :private
  def input_authority(%__MODULE__{}), do: :normal
  def input_authority(%RunRequest{input: input}), do: input.authority

  defp valid_fields?(request) do
    ApplicationPackage.valid?(request.package) and ExecutionPolicy.valid?(request.policy) and
      request.policy.event_policy == request.package.events.policy
  end
end
