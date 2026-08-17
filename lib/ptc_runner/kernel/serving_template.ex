defmodule PtcRunner.Kernel.ServingTemplate do
  @moduledoc """
  Immutable compiled application used for repeated hosted calls.

  Compile caches workflow and mission bundles, the validated entry, required
  input and result contracts, provider-declaration shape, frozen execution
  policy (including the input authority class), and the
  `application_content_digest` / `effective_application_digest` pair. A call
  supplies only the input value. That value is excluded from the effective
  digest, so the digest captured at compile time describes every run made
  from the template. When the frozen policy enables inspection capture, each
  call authorizes inspection on its publication authority so the Kernel
  opens an inspection sink.

  Compile binds provider declarations to the installation catalog when the
  package selects any. `call/2` remains provider-free and refuses a template
  that selected providers; `PtcRunner.Kernel.HostRuntime.call/3` executes
  those templates under aggregate admission. With the default
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
  alias PtcRunner.Kernel.CommandApplicationDiagnostic
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
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderPlan
  alias PtcRunner.Kernel.ProviderRuntimeServices
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
    :post_selection_context,
    :provider_declarations
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
          provider_declarations: [map()],
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
             | :host_runtime_required
             | :invalid_installation_catalog
             | :event_identity_conflict
             | :invalid_execution_policy}
  @doc "Compiles one serving template from a package-only acquisition."
  def compile(package, opts \\ [])

  def compile(%ApplicationPackage{} = package, opts) when is_list(opts) do
    input_authority = Keyword.get(opts, :input_authority, :normal)

    with :ok <- validate_options(opts),
         true <- ApplicationPackage.valid?(package),
         :ok <- require_contracts(package),
         {:ok, catalog} <- catalog(package, opts),
         {:ok, policy} <-
           ExecutionPolicy.from_package(
             package,
             Keyword.put_new(opts, :result_projection, :json)
           ),
         {:ok, workflow_bundle, mission_bundles} <- RunCoordinator.compile_application(package),
         :ok <- require_read_only(package, workflow_bundle, mission_bundles),
         {:ok, declarations, derived} <-
           RunCoordinator.bind_providers(
             package,
             workflow_bundle,
             mission_bundles,
             catalog,
             identity(package, policy, input_authority)
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
        post_selection_context: derived.post_selection_context,
        provider_declarations: declarations
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
          | {:error,
             CommandOutcome.t()
             | :invalid_serving_template
             | :host_runtime_required
             | :entropy_unavailable}
  @doc "Executes one provider-free call against the frozen template. The argument is only the input value."
  def call(%__MODULE__{} = template, input) when is_map(input) and not is_struct(input) do
    cond do
      not valid?(template) ->
        {:error, :invalid_serving_template}

      template.provider_declarations != [] ->
        {:error, :host_runtime_required}

      true ->
        execute_call(template, input, nil)
    end
  end

  def call(_template, _input), do: {:error, :invalid_serving_template}

  @doc false
  @spec dispatch_hosted(t(), map(), ProviderRuntimeServices.t()) ::
          {:ok, CommandOutcome.t()}
          | {:error, CommandOutcome.t() | :invalid_serving_template | :entropy_unavailable}
  def dispatch_hosted(
        %__MODULE__{} = template,
        input,
        %ProviderRuntimeServices{} = services
      )
      when is_map(input) and not is_struct(input) do
    if valid?(template) do
      execute_hosted(template, input, services)
    else
      {:error, :invalid_serving_template}
    end
  end

  def dispatch_hosted(_template, _input, _services), do: {:error, :invalid_serving_template}

  defp execute_hosted(template, input, services) do
    case provider_execution(template, services) do
      {:ok, execution} ->
        execute_call(template, input, execution)

      {:error, _reason} = error ->
        error
    end
  end

  defp provider_execution(%{provider_declarations: []}, _services), do: {:ok, nil}

  defp provider_execution(template, services) do
    ProviderExecution.new(template.catalog, services, [])
  end

  defp execute_call(template, input, execution) do
    with {:ok, run_ref} <- CommandRunRef.generate() do
      case ExecutionInput.new(
             input,
             template.input_authority,
             template.package.contracts.input
           ) do
        {:ok, execution_input} ->
          execute_authorized_call(template, execution_input, run_ref, execution)

        {:error, reason} ->
          {:error, input_rejection(run_ref, reason)}
      end
    end
  end

  defp execute_authorized_call(template, execution_input, run_ref, execution) do
    with {:ok, request} <- RunRequest.new(template.package, execution_input, template.policy),
         {:ok, derived} <-
           ProviderPlan.derive(
             request,
             template.workflow_bundle,
             template.mission_bundles,
             template.provider_declarations
           ),
         true <- derived.effective_application_digest == template.effective_application_digest,
         {:ok, authority, inspect_parent} <- publication_authority(template, run_ref) do
      try do
        case prepare_call(template, request, derived) do
          {:ok, prepared} ->
            dispatch(prepared, authority, run_ref, template.effective_event_policy, execution)

          {:error, reason} ->
            {:error, command_error(run_ref, reason)}
        end
      after
        PublicationAuthority.close(authority)
        if inspect_parent, do: _ = File.rm_rf(inspect_parent)
      end
    else
      false ->
        {:error, :invalid_serving_template}

      {:error, _reason} = error ->
        error
    end
  end

  defp publication_authority(template, run_ref) do
    if template.policy.inspection_capture do
      authorize_inspection(template, run_ref)
    else
      with {:ok, authority} <- PublicationAuthority.new([]) do
        {:ok, authority, nil}
      end
    end
  end

  defp authorize_inspection(template, run_ref) do
    parent = Path.join(System.tmp_dir!(), "ptc-serving-" <> run_ref)
    path = Path.join(parent, "run.inspection.jsonl")

    case File.mkdir_p(parent) do
      :ok ->
        case PublicationAuthority.authorize(
               run_ref,
               [inspect: path],
               template.effective_event_policy,
               template.effective_data_class
             ) do
          {:ok, authority} ->
            {:ok, authority, parent}

          {:error, _reason} = error ->
            _ = File.rm_rf(parent)
            error
        end

      {:error, _reason} ->
        {:error, :invalid_publication_authority}
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
        Map.put(
          derived,
          :provider_declarations,
          RunCoordinator.prepared_declarations(template.provider_declarations)
        )
      )
    end)
  end

  defp dispatch(prepared, authority, run_ref, effective_event_policy, execution) do
    result_class = if effective_event_policy == :private, do: :private, else: :normal

    artifact_state =
      authority
      |> PublicationAuthority.destination_options()
      |> Map.new()
      |> CommandDestination.requested_artifact_state()

    provider_activity = execution != nil

    case execute_prepared(prepared, authority, execution) do
      {:ok, outcome} ->
        CommandRunOutcome.settle(
          outcome,
          authority,
          run_ref,
          result_class,
          artifact_state,
          provider_activity
        )

      {:error, reason} ->
        {:error, command_error(run_ref, reason)}
    end
  end

  defp execute_prepared(prepared, authority, nil),
    do: RunCoordinator.execute(prepared, authority)

  defp execute_prepared(prepared, authority, execution),
    do: RunCoordinator.execute(prepared, authority, execution, nil)

  defp input_rejection(run_ref, reason) do
    CommandOutcome.error(:run, run_ref, CommandApplicationDiagnostic.project(:run, reason))
  end

  defp command_error(run_ref, %CommandDiagnostic{} = diagnostic) do
    CommandOutcome.error(:run, run_ref, diagnostic)
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

  defp require_contracts(%{contracts: %{input: %ValueContract{}, result: %ValueContract{}}}),
    do: :ok

  defp require_contracts(_package), do: {:error, :serving_contracts_required}

  defp require_read_only(package, workflow_bundle, mission_bundles) do
    namespaces = local_namespaces(package, workflow_bundle, mission_bundles)

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

  defp local_namespaces(package, workflow_bundle, mission_bundles) do
    local_ids = MapSet.new(local_component_ids(package))

    [workflow_bundle | Enum.reject(Map.values(mission_bundles), &is_nil/1)]
    |> Enum.flat_map(& &1.components)
    |> Enum.flat_map(fn component ->
      if MapSet.member?(local_ids, component.id) do
        List.wrap(Map.get(component, :namespaces, []))
      else
        []
      end
    end)
    |> MapSet.new()
  end

  defp local_component_ids(package) do
    workflow = for {id, :local} <- package.workflow_component_kinds, do: id

    mission =
      for {_name, mission} <- package.missions,
          {id, :local} <- mission.kinds,
          do: id

    workflow ++ mission
  end

  defp payload(template) do
    template
    |> Map.from_struct()
    |> Map.delete(:attestation)
  end
end
