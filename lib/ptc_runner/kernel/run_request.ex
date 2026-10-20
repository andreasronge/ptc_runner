defmodule PtcRunner.Kernel.RunRequest do
  @moduledoc """
  Sealed, path-free application package, input, and execution-policy tuple.

  `from_directory/2` and `from_memory/3` acquire a package and selected input,
  construct execution policy, and seal the complete request. Package acquisition
  remains below request orchestration and does not depend on this module.

  This is the sole request shape accepted by the path-free coordinator added
  above the Kernel. Acquisition adapters may construct it; callers cannot
  replace one member after sealing without invalidating the request.
  """

  alias PtcRunner.Kernel.ApplicationOptions
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

  @spec from_directory(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  @doc """
  Acquires and seals one complete directory-backed run request.

  In addition to `:installed_limits`, `:input_authority`, `:input`, and
  `:component_override_descriptor`, accepts exactly `:inspection_capture`,
  `:result_projection`, `:forbid_model_dispatch`, and `:event_identity`. The latter
  fixes both event IDs and is rejected when the manifest already owns either
  identity.
  `:omit_input` and `:repl_interactive_loop` are package-acquisition flags
  and are rejected here.
  """
  def from_directory(path, opts \\ [])

  def from_directory(path, opts) when is_binary(path) and is_list(opts) do
    with :ok <- ApplicationOptions.validate(opts, :directory_request),
         do: from_directory_with_profile(path, opts, false)
  end

  def from_directory(_path, _opts), do: {:error, :invalid_application_source}

  @doc false
  @spec from_repl_directory(binary(), keyword(), boolean()) ::
          {:ok, t()} | {:error, term()}
  def from_repl_directory(path, opts, interactive_loop?)
      when is_binary(path) and is_list(opts) and is_boolean(interactive_loop?) do
    with :ok <- ApplicationOptions.validate(opts, :directory_request),
         do: from_directory_with_profile(path, opts, interactive_loop?)
  end

  def from_repl_directory(_path, _opts, _interactive_loop?),
    do: {:error, :invalid_application_source}

  defp from_directory_with_profile(path, opts, interactive_loop?) do
    acquisition_opts =
      opts |> acquisition_options() |> Keyword.put(:repl_interactive_loop, interactive_loop?)

    with {:ok, package, input} <- ApplicationPackage.acquire_directory(path, acquisition_opts),
         {:ok, policy} <- execution_policy(package, opts),
         do: new(package, input, policy)
  end

  @spec from_memory(binary(), %{binary() => binary()}, keyword()) ::
          {:ok, t()} | {:error, term()}
  @doc """
  Acquires and seals one complete memory-backed run request.

  In addition to the `PtcRunner.Kernel.ApplicationPackage.acquire_memory/3`
  options, accepts exactly
  `:inspection_capture`, `:result_projection`, `:forbid_model_dispatch`, and
  `:event_identity`. The latter fixes both event IDs and is rejected when the
  manifest already owns either identity.
  """
  def from_memory(manifest_name, documents, opts \\ [])

  def from_memory(manifest_name, documents, opts)
      when is_binary(manifest_name) and is_map(documents) and is_list(opts) do
    with :ok <- ApplicationOptions.validate(opts, :memory_request),
         {:ok, package, input} <-
           ApplicationPackage.acquire_memory(manifest_name, documents, acquisition_options(opts)),
         {:ok, policy} <- execution_policy(package, opts),
         do: new(package, input, policy)
  end

  def from_memory(_manifest_name, _documents, _opts),
    do: {:error, :invalid_application_source}

  defp acquisition_options(opts),
    do:
      Keyword.drop(opts, [
        :inspection_capture,
        :result_projection,
        :event_identity,
        :forbid_model_dispatch
      ])

  defp execution_policy(package, opts) do
    with {:ok, run_id, trace_id} <- event_identity(package.events, opts) do
      ExecutionPolicy.new(
        event_policy: package.events.policy,
        run_id: run_id,
        trace_id: trace_id,
        inspection_capture: Keyword.get(opts, :inspection_capture, false),
        result_projection: Keyword.get(opts, :result_projection, :native),
        forbid_model_dispatch: Keyword.get(opts, :forbid_model_dispatch, false)
      )
    end
  end

  defp event_identity(events, opts) do
    case Keyword.fetch(opts, :event_identity) do
      :error ->
        {:ok, events.run_id, events.trace_id}

      {:ok, identity} when is_nil(events.run_id) and is_nil(events.trace_id) ->
        {:ok, identity, identity}

      {:ok, _identity} ->
        {:error, :event_identity_conflict}
    end
  end

  @spec valid?(term()) :: boolean()
  @doc "Checks the request and all nested construction attestations."
  def valid?(%__MODULE__{attestation: attestation} = request) do
    Attestation.valid_value?(__MODULE__, request, attestation, fn ->
      Enum.sort(Map.keys(request)) == @field_keys and
        ApplicationPackage.valid?(request.package) and
        ExecutionInput.valid?(request.input) and
        ExecutionPolicy.valid?(request.policy) and
        input_matches_package?(request.input, request.package) and
        policy_matches_package?(request.policy, request.package) and
        Attestation.valid?(__MODULE__, payload(request), attestation)
    end)
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
