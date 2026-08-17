defmodule PtcRunner.Kernel.ServingTemplate do
  @moduledoc """
  Immutable compiled application used for repeated hosted calls.

  Compile caches workflow and mission bundles, the validated entry, required
  input and result contracts, provider-declaration shape, frozen execution
  policy (including the input authority class), and the
  `application_content_digest` / `effective_application_digest` pair. A call
  supplies only the input value. That value is excluded from the effective
  digest, so the digest captured at compile time describes every run made
  from the template.

  This slice is provider-free. Applications that declare workflow or mission
  providers are refused until host runtime admission exists. With the default
  `effects: :read_only`, compile fails closed: any local public export whose
  effect is not provably `:read` — including `:unknown` — refuses the
  template.

  Acquire the package with `PtcRunner.Kernel.ApplicationPackage.package_memory/3`
  or `package_directory/2` so missing manifest input cannot fail compilation.

  The public call outcome is `PtcRunner.Kernel.CommandOutcome`, produced at
  the `PtcRunner.Kernel.CommandRunOutcome` seam. Do not add a second
  projection.

  ## Options

  Compile accepts exactly `:catalog`, `:input_authority`,
  `:inspection_capture`, `:result_projection`, `:event_identity`, and
  `:effects`. Unknown and duplicate options fail before compilation.
  `:effects` admits only `:read_only`. `:result_projection` defaults to
  `:json`. `:input_authority` defaults to `:normal` and is frozen onto every
  call's `PtcRunner.Kernel.ExecutionInput`.
  """

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.CommandDestination
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandRunOutcome
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.ExecutionInput
  alias PtcRunner.Kernel.ExecutionPolicy
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderPlan
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Lisp.Prelude

  @compile_options [
    :catalog,
    :input_authority,
    :inspection_capture,
    :result_projection,
    :event_identity,
    :effects
  ]

  @enforce_keys [
    :package,
    :workflow_bundle,
    :mission_bundles,
    :catalog,
    :policy,
    :input_authority,
    :effective_application_projection,
    :effective_application_digest,
    :effective_data_class,
    :effective_flow,
    :effective_event_policy,
    :post_selection_context
  ]
  defstruct @enforce_keys ++ [attestation: nil]
  @field_keys Enum.sort([:__struct__, :attestation | @enforce_keys])

  @type t :: %__MODULE__{
          package: ApplicationPackage.t(),
          workflow_bundle: FrozenBundle.t(),
          mission_bundles: %{binary() => FrozenBundle.t() | nil},
          catalog: InstallationCatalog.t(),
          policy: ExecutionPolicy.t(),
          input_authority: ExecutionInput.authority(),
          effective_application_projection: map(),
          effective_application_digest: binary(),
          effective_data_class: :normal | :private_inspection,
          effective_flow: :normal | :private,
          effective_event_policy: :normal | :private,
          post_selection_context: map(),
          attestation: binary() | nil
        }

  @spec compile(ApplicationPackage.t(), keyword()) ::
          {:ok, t()}
          | {:error,
             CommandDiagnostic.t()
             | :invalid_serving_options
             | :invalid_serving_template
             | :serving_contracts_required
             | :effect_not_read
             | :providers_not_supported
             | :invalid_installation_catalog
             | :event_identity_conflict
             | :invalid_execution_policy}
  @doc "Compiles one provider-free serving template from a package-only acquisition."
  def compile(package, opts \\ [])

  def compile(%ApplicationPackage{} = package, opts) when is_list(opts) do
    input_authority = Keyword.get(opts, :input_authority, :normal)

    with :ok <- validate_options(opts),
         true <- ApplicationPackage.valid?(package),
         :ok <- require_provider_free(package),
         :ok <- require_contracts(package),
         {:ok, catalog} <- catalog(package, opts),
         {:ok, policy} <-
           ExecutionPolicy.from_package(
             package,
             Keyword.put_new(opts, :result_projection, :json)
           ),
         {:ok, workflow_bundle, mission_bundles} <- RunCoordinator.compile_application(package),
         :ok <- require_read_only(package, workflow_bundle, mission_bundles),
         {:ok, derived} <-
           ProviderPlan.derive_identity(
             identity(package, policy, input_authority),
             workflow_bundle,
             mission_bundles,
             []
           ) do
      template = %__MODULE__{
        package: package,
        workflow_bundle: workflow_bundle,
        mission_bundles: mission_bundles,
        catalog: catalog,
        policy: policy,
        input_authority: input_authority,
        effective_application_projection: derived.effective_application_projection,
        effective_application_digest: derived.effective_application_digest,
        effective_data_class: derived.effective_data_class,
        effective_flow: derived.effective_flow,
        effective_event_policy: derived.effective_event_policy,
        post_selection_context: derived.post_selection_context
      }

      {:ok, %{template | attestation: Attestation.attest(__MODULE__, payload(template))}}
    else
      false -> {:error, :invalid_serving_template}
      {:error, _reason} = error -> error
    end
  end

  def compile(_package, _opts), do: {:error, :invalid_serving_template}

  @spec valid?(term()) :: boolean()
  @doc "Checks the template's in-VM construction attestation."
  def valid?(%__MODULE__{attestation: attestation} = template),
    do:
      Enum.sort(Map.keys(template)) == @field_keys and
        ApplicationPackage.valid?(template.package) and
        FrozenBundle.valid?(template.workflow_bundle) and
        ExecutionPolicy.valid?(template.policy) and
        InstallationCatalog.valid?(template.catalog) and
        Attestation.valid?(__MODULE__, payload(template), attestation)

  def valid?(_template), do: false

  @spec call(t(), map()) ::
          {:ok, CommandOutcome.t()}
          | {:error, CommandOutcome.t() | :invalid_serving_template | :entropy_unavailable}
  @doc "Executes one call against the frozen template. The argument is only the input value."
  def call(%__MODULE__{} = template, input) when is_map(input) and not is_struct(input) do
    if valid?(template) do
      execute_call(template, input)
    else
      {:error, :invalid_serving_template}
    end
  end

  def call(_template, _input), do: {:error, :invalid_serving_template}

  defp execute_call(template, input) do
    with {:ok, run_ref} <- CommandRunRef.generate(),
         {:ok, execution_input} <-
           ExecutionInput.new(input, template.input_authority, template.package.contracts.input),
         {:ok, request} <- RunRequest.new(template.package, execution_input, template.policy),
         {:ok, derived} <-
           ProviderPlan.derive(
             request,
             template.workflow_bundle,
             template.mission_bundles,
             []
           ),
         true <- derived.effective_application_digest == template.effective_application_digest,
         {:ok, authority} <- PublicationAuthority.new([]) do
      try do
        case prepare_call(template, request, derived) do
          {:ok, prepared} ->
            dispatch(prepared, authority, run_ref, template.effective_event_policy)

          {:error, reason} ->
            {:error, command_error(run_ref, reason)}
        end
      after
        PublicationAuthority.close(authority)
      end
    else
      false ->
        {:error, :invalid_serving_template}

      {:error, {:input_contract_failed, _classification}} ->
        call_contract_error()

      {:error, :invalid_input} ->
        call_contract_error()

      {:error, %CommandOutcome{} = outcome} ->
        {:error, outcome}

      {:error, _reason} = error ->
        error
    end
  end

  defp prepare_call(template, request, derived) do
    ProviderActivity.start_owned(fn activity ->
      PreparedRun.new(
        request,
        template.workflow_bundle,
        template.mission_bundles,
        "(#{template.package.entry} data/input)",
        activity,
        template.catalog,
        Map.put(derived, :provider_declarations, [])
      )
    end)
  end

  defp dispatch(prepared, authority, run_ref, effective_event_policy) do
    result_class = if effective_event_policy == :private, do: :private, else: :normal
    artifact_state = CommandDestination.requested_artifact_state(%{})

    case RunCoordinator.execute(prepared, authority) do
      {:ok, outcome} ->
        CommandRunOutcome.settle(
          outcome,
          authority,
          run_ref,
          result_class,
          artifact_state,
          false
        )

      {:error, reason} ->
        {:error, command_error(run_ref, reason)}
    end
  end

  defp call_contract_error do
    with {:ok, run_ref} <- CommandRunRef.generate() do
      {:error, command_error(run_ref, :input_contract_failed)}
    end
  end

  defp command_error(run_ref, :input_contract_failed) do
    CommandOutcome.error(
      :run,
      run_ref,
      CommandDiagnostic.new!(:application, :input_contract_failed)
    )
  end

  defp command_error(run_ref, _reason) do
    CommandOutcome.error(:run, run_ref, CommandDiagnostic.new!(:internal, :internal_error))
  end

  defp validate_options(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      cond do
        keys -- @compile_options != [] or length(keys) != MapSet.size(MapSet.new(keys)) ->
          {:error, :invalid_serving_options}

        Keyword.get(opts, :effects, :read_only) != :read_only ->
          {:error, :invalid_serving_options}

        Keyword.get(opts, :input_authority, :normal) not in [:normal, :private] ->
          {:error, :invalid_serving_options}

        Keyword.get(opts, :result_projection, :json) not in [:native, :json] ->
          {:error, :invalid_serving_options}

        not is_boolean(Keyword.get(opts, :inspection_capture, false)) ->
          {:error, :invalid_serving_options}

        true ->
          :ok
      end
    else
      {:error, :invalid_serving_options}
    end
  end

  defp catalog(package, opts) do
    case Keyword.fetch(opts, :catalog) do
      :error ->
        InstallationCatalog.new(%{}, installed_limits: package.installed_limits)

      {:ok, %InstallationCatalog{} = catalog} ->
        if InstallationCatalog.valid?(catalog) and
             catalog.installed_limits == package.installed_limits do
          {:ok, catalog}
        else
          {:error, :invalid_installation_catalog}
        end

      {:ok, _catalog} ->
        {:error, :invalid_installation_catalog}
    end
  end

  defp identity(package, policy, input_authority) do
    %{
      package: package,
      input_authority: input_authority,
      inspection_capture: policy.inspection_capture,
      result_projection: policy.result_projection,
      event_policy: policy.event_policy
    }
  end

  defp require_provider_free(package) do
    case package.providers do
      %{workflow: [], mission: []} -> :ok
      _providers -> {:error, :providers_not_supported}
    end
  end

  defp require_contracts(%{contracts: %{input: %ValueContract{}, result: %ValueContract{}}}),
    do: :ok

  defp require_contracts(_package), do: {:error, :serving_contracts_required}

  defp require_read_only(package, workflow_bundle, mission_bundles) do
    namespaces = local_namespaces(package)

    with {:ok, entry} <- Prelude.fetch_export(workflow_bundle.prelude, package.entry),
         true <- entry.effect == :read,
         true <- local_exports_read_only?(namespaces, workflow_bundle, mission_bundles) do
      :ok
    else
      _not_read -> {:error, :effect_not_read}
    end
  end

  defp local_exports_read_only?(namespaces, workflow_bundle, mission_bundles) do
    [workflow_bundle | Enum.reject(Map.values(mission_bundles), &is_nil/1)]
    |> Enum.flat_map(& &1.prelude.exports)
    |> Enum.all?(fn export ->
      not MapSet.member?(namespaces, export.namespace) or export.effect == :read
    end)
  end

  defp local_namespaces(package) do
    workflow = for {id, :local} <- package.workflow_component_kinds, do: id

    mission =
      for {_name, mission} <- package.missions,
          {id, :local} <- mission.kinds,
          do: id

    MapSet.new(workflow ++ mission)
  end

  defp payload(template) do
    template
    |> Map.from_struct()
    |> Map.delete(:attestation)
  end
end
