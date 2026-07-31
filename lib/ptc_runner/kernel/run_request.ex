defmodule PtcRunner.Kernel.RunRequest do
  @moduledoc """
  Sealed, path-free application package, input, and execution-policy tuple.

  This is the sole request shape accepted by the path-free coordinator added
  above the Kernel. Acquisition adapters may construct it; callers cannot
  replace one member after sealing without invalidating the request.
  """

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.ExecutionInput
  alias PtcRunner.Kernel.ExecutionPolicy
  alias PtcRunner.Kernel.ValueContract

  @enforce_keys [:package, :input, :policy]
  defstruct [:package, :input, :policy, :attestation]
  @field_keys Enum.sort([:__struct__, :package, :input, :policy, :attestation])

  @type t :: %__MODULE__{
          package: ApplicationPackage.t(),
          input: ExecutionInput.t(),
          policy: ExecutionPolicy.t(),
          attestation: binary() | nil
        }

  @spec new(ApplicationPackage.t(), ExecutionInput.t(), ExecutionPolicy.t()) ::
          {:ok, t()} | {:error, :invalid_run_request}
  @doc "Validates and seals one path-free run request."
  def new(%ApplicationPackage{} = package, %ExecutionInput{} = input, %ExecutionPolicy{} = policy) do
    if ApplicationPackage.valid?(package) and ExecutionInput.valid?(input) and
         ExecutionPolicy.valid?(policy) and input_matches_package?(input, package) and
         policy_matches_package?(policy, package) do
      request = %__MODULE__{package: package, input: input, policy: policy}
      {:ok, %{request | attestation: Attestation.attest(__MODULE__, payload(request))}}
    else
      {:error, :invalid_run_request}
    end
  end

  def new(_package, _input, _policy), do: {:error, :invalid_run_request}

  @spec valid?(term()) :: boolean()
  @doc "Checks the request and all nested construction attestations."
  def valid?(%__MODULE__{attestation: attestation} = request) do
    Enum.sort(Map.keys(request)) == @field_keys and
      ApplicationPackage.valid?(request.package) and
      ExecutionInput.valid?(request.input) and
      ExecutionPolicy.valid?(request.policy) and
      input_matches_package?(request.input, request.package) and
      policy_matches_package?(request.policy, request.package) and
      Attestation.valid?(__MODULE__, payload(request), attestation)
  end

  def valid?(_request), do: false

  # Event privacy remains application semantics. Identity ownership belongs to
  # the adapter: a traced command fixes both IDs to its run reference, while a
  # trusted embedding may retain or replace manifest identities before sealing.
  defp policy_matches_package?(policy, package),
    do: policy.event_policy == package.events.policy

  defp input_matches_package?(_input, %{contracts: %{input: nil}}), do: true

  defp input_matches_package?(%ExecutionInput{value: value}, %{
         contracts: %{input: %ValueContract{} = contract}
       }),
       do: ValueContract.valid?(contract, value)

  defp input_matches_package?(_input, _package), do: false

  defp payload(request), do: {request.package, request.input, request.policy}
end
