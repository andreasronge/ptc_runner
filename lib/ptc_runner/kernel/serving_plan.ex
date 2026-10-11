defmodule PtcRunner.Kernel.ServingPlan do
  @moduledoc """
  Immutable serving compilation and validation below execution orchestration.

  Retains admitted bundles, provider declarations and effective identity. A
  per-call preparation uses this cached plan without recompilation or provider
  callbacks. Runtime handles are references only; the plan owns no resources.
  """
  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.BundleCompiler
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.DeclaredReadEffectValidator
  alias PtcRunner.Kernel.EffectiveApplication
  alias PtcRunner.Kernel.EntryEffect
  alias PtcRunner.Kernel.ExecutionPolicy
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.InstallationConfigDigest
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderPlan
  alias PtcRunner.Kernel.RunAssembly
  alias PtcRunner.Kernel.RunPreparation
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Kernel.ServingOutcome
  alias PtcRunner.Kernel.ServingProviderMode
  alias PtcRunner.Kernel.ServingRequest
  alias PtcRunner.Kernel.ValueContract

  @enforce_keys [:package, :workflow, :missions, :effect, :effective_digest, :policy]
  @derive {Inspect, only: [:effect, :effective_digest, :policy]}
  defstruct @enforce_keys ++
              [
                retained: nil,
                installation_digests: %{},
                provider_runtime: nil,
                warm_runtime: nil,
                cold_services: nil
              ]

  @typedoc "An immutable compiled application with no owned execution resources."
  @type t :: %__MODULE__{
          package: ApplicationPackage.t(),
          workflow:
            PtcRunner.Kernel.WorkflowEnvironment.t()
            | %{bundle: PtcRunner.Kernel.FrozenBundle.t()},
          missions: map(),
          effect: :read | :write,
          effective_digest: binary(),
          policy: map(),
          retained: map() | nil,
          installation_digests: map(),
          provider_runtime: pid() | nil,
          warm_runtime: pid() | nil,
          cold_services: PtcRunner.Kernel.ProviderRuntimeServices.t() | nil
        }

  @typedoc "Closed construction failures containing no private detail."
  @type build_code ::
          :invalid_options
          | :invalid_installed_limits
          | :invalid_application
          | :contracts_required
          | :entry_invalid
          | :manifest_identity_forbidden
          | :private_result_unservable
          | :invalid_installation_catalog
          | :provider_runtime_required
          | :provider_runtime_unsupported
          | :application_content_digest_mismatch
          | :compilation_failed
          | :environment_invalid
          | :effect_declaration_required
          | :declared_read_effect_violation
          | :internal_error

  @doc "Acquires and compiles one immutable directory template without selected input."
  @spec from_directory(binary(), Limits.t(), keyword()) :: {:ok, t()} | {:error, build_code()}
  def from_directory(path, installed_limits, opts \\ []) do
    with :ok <- options(opts),
         true <- Limits.valid?(installed_limits),
         {:ok, package} <- acquire(path, installed_limits),
         :ok <- package_rules(package, opts) do
      construct(package, opts)
    else
      false -> {:error, :invalid_installed_limits}
      {:error, _code} = error -> error
    end
  rescue
    _exception -> {:error, :internal_error}
  catch
    _kind, _reason -> {:error, :internal_error}
  end

  @doc "Returns the compiled normalized object input schema."
  @spec input_schema(t()) :: map()
  def input_schema(%__MODULE__{package: package}), do: package.contracts.input.schema

  @doc "Returns the compiled normalized object result schema."
  @spec output_schema(t()) :: map()
  def output_schema(%__MODULE__{package: package}), do: package.contracts.result.schema

  @doc "Returns the validated declaration, widened by the complete grant for read entries."
  @spec effect(t()) :: :read | :write
  def effect(%__MODULE__{effect: effect}), do: effect

  @doc "Returns an invalid-result outcome preserving the call's dispatch metadata."
  @spec invalid_result(t(), ServingOutcome.t()) :: ServingOutcome.t()
  def invalid_result(%__MODULE__{} = template, outcome) do
    ServingOutcome.new(
      :invalid_result,
      ServingOutcome.metadata(outcome).dispatched,
      template.effect
    )
  end

  @doc "Returns content identity, independent of selected input and effective hosting policy."
  @spec application_content_digest(t()) :: binary()
  def application_content_digest(%__MODULE__{package: package}),
    do: "sha256:" <> package.application_content_digest

  @doc "Returns the existing effective identity with frozen hosting policy."
  @spec effective_application_digest(t()) :: binary()
  def effective_application_digest(%__MODULE__{effective_digest: digest}), do: digest

  @doc "Returns selected installation configuration digests (empty without providers)."
  @spec installation_config_digests(t()) :: %{binary() => binary()}
  def installation_config_digests(%__MODULE__{installation_digests: digests}), do: digests

  @doc "Returns effective limits resolved against installed ceilings."
  @spec limits(t()) :: Limits.t()
  def limits(%__MODULE__{package: package}), do: package.limits

  @doc "Returns frozen event, projection, inspection, publication and absolute-deadline rules."
  @spec policy(t()) :: map()
  def policy(%__MODULE__{policy: policy}), do: policy

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Keyword.keys(opts) --
           [:providers, :expected_application_content_digest, :inspection_capture] == [] and
         length(opts) == MapSet.size(MapSet.new(Keyword.keys(opts))) and
         is_boolean(Keyword.get(opts, :inspection_capture, false)) and
         (not Keyword.has_key?(opts, :expected_application_content_digest) or
            InstallationConfigDigest.valid_digest?(opts[:expected_application_content_digest])),
       do: :ok,
       else: {:error, :invalid_options}
  end

  defp options(_opts), do: {:error, :invalid_options}

  defp acquire(path, limits) do
    case ApplicationPackage.acquire_directory(path, installed_limits: limits, omit_input: true) do
      {:ok, package, _discarded_input} -> {:ok, package}
      {:error, _reason} -> {:error, :invalid_application}
    end
  end

  defp package_rules(package, opts) do
    cond do
      provider_bearing?(package) and not Keyword.has_key?(opts, :providers) ->
        {:error, :provider_runtime_required}

      package.events.policy == :private ->
        {:error, :private_result_unservable}

      package.events.run_id != nil or package.events.trace_id != nil ->
        {:error, :manifest_identity_forbidden}

      not match?(%ValueContract{}, package.contracts.input) or
          not match?(%ValueContract{}, package.contracts.result) ->
        {:error, :contracts_required}

      Keyword.has_key?(opts, :expected_application_content_digest) and
          opts[:expected_application_content_digest] !=
            "sha256:" <> package.application_content_digest ->
        {:error, :application_content_digest_mismatch}

      true ->
        :ok
    end
  end

  defp construct(package, opts) do
    inspection_capture = Keyword.get(opts, :inspection_capture, false)

    if provider_bearing?(package),
      do: construct_retained(package, opts[:providers], inspection_capture),
      else: construct_free(package, inspection_capture)
  end

  defp provider_bearing?(package),
    do: package.providers.workflow != [] or package.providers.mission != []

  defp construct_free(package, inspection_capture) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    with {:ok, bundle} <- compile(package.workflow_components, deadline),
         {:ok, bundles} <- compile_missions(package, bundle, deadline),
         :ok <- entry_valid(bundle, package),
         {:ok, workflow, missions} <- assemble(package, bundle, bundles),
         {:ok, effect} <- validate_effect(workflow, missions, package.entry),
         policy = %{
           input_authority_class: :normal,
           inspection_capture: inspection_capture,
           result_projection: :json,
           effective_event_policy: package.events.policy,
           publication: :artifact_free,
           deadline: :absolute_from_reservation
         },
         {:ok, identity} <-
           EffectiveApplication.build_package(
             package,
             bundle,
             bundles,
             %{workflow: [], mission: []},
             policy
           ) do
      {:ok,
       %__MODULE__{
         package: package,
         workflow: workflow,
         missions: missions,
         effect: effect,
         effective_digest: identity.digest,
         policy: policy
       }}
    else
      {:error, :invalid_effective_application} -> {:error, :internal_error}
      {:error, _code} = error -> error
    end
  end

  @doc "Seals a per-call run from cached bundles and the complete prepared metadata."
  @spec prepare_call(t(), RunRequest.t()) :: {:ok, PreparedRun.t()} | {:error, term()}
  def prepare_call(%__MODULE__{} = template, %RunRequest{} = request) do
    if RunRequest.valid?(request) and request.package == template.package and
         request.input.authority == :normal and request.policy.result_projection == :json and
         request.policy.inspection_capture == template.policy.inspection_capture and
         request.policy.event_policy == :normal do
      with {:ok, retained} <- retained_metadata(template, request) do
        seal_call(template, request, retained)
      end
    else
      {:error, :invalid_run_request}
    end
  end

  def prepare_call(_template, _request), do: {:error, :invalid_run_request}

  defp seal_call(template, request, retained) do
    ProviderActivity.start_owned(fn activity ->
      PreparedRun.new(
        request,
        template.workflow.bundle,
        Map.new(template.missions, fn {name, mission} -> {name, mission.bundle} end),
        "(#{template.package.entry} data/input)",
        activity,
        retained.catalog,
        retained.metadata
      )
    end)
  end

  @doc false
  @spec with_warm_runtime(t(), pid()) :: t()
  def with_warm_runtime(%__MODULE__{} = template, runtime) when is_pid(runtime),
    do: %{template | warm_runtime: runtime}

  @doc false
  @spec cold?(term()) :: boolean()
  def cold?(template) do
    case provider_plan(template) do
      {:ok, plan} ->
        ServingProviderMode.classify(
          plan.metadata.provider_declarations,
          plan.catalog
        ) == :cold

      _ ->
        false
    end
  end

  @doc false
  @spec with_cold_services(t(), PtcRunner.Kernel.ProviderRuntimeServices.t()) :: t()
  def with_cold_services(template, services), do: %{template | cold_services: services}

  @doc false
  @spec runtime_context(term()) :: map() | nil
  def runtime_context(%__MODULE__{} = template) do
    %{
      required?: not is_nil(template.retained),
      cold?: cold?(template),
      cold_services: template.cold_services,
      runtime: template.provider_runtime,
      warm_runtime: template.warm_runtime,
      identity: {template.effective_digest, template.installation_digests}
    }
  end

  def runtime_context(_), do: nil

  @doc false
  @spec provider_plan(term()) :: {:ok, map()} | {:error, :provider_runtime_required}
  def provider_plan(%__MODULE__{retained: nil}), do: {:error, :provider_runtime_required}

  def provider_plan(%__MODULE__{retained: %{reader: reader, attestation: attestation}} = template) do
    if Attestation.valid?(
         __MODULE__,
         {template.package, template.installation_digests, template.effective_digest, reader},
         attestation
       ) do
      {:ok,
       Map.merge(reader.(), %{
         workflow_bundle: template.workflow.bundle,
         mission_bundles:
           Map.new(template.missions, fn {name, mission} -> {name, mission.bundle} end),
         entry_source: "(#{template.package.entry} data/input)"
       })}
    else
      {:error, :provider_runtime_required}
    end
  end

  def provider_plan(_template), do: {:error, :provider_runtime_required}

  @doc false
  @spec credential_names(t()) :: [binary()]
  def credential_names(template) do
    case provider_plan(template) do
      {:ok, plan} ->
        plan.metadata.provider_declarations
        |> Enum.flat_map(&plan.catalog.descriptors[&1.name].credential_names)
        |> Enum.uniq()
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp retain(package, digests, effective_digest, state) do
    reader = fn -> state end

    %{
      reader: reader,
      attestation: Attestation.attest(__MODULE__, {package, digests, effective_digest, reader})
    }
  end

  defp retained_metadata(%__MODULE__{retained: retained} = template, _request)
       when not is_nil(retained),
       do: provider_plan(template)

  defp retained_metadata(template, request) do
    with {:ok, catalog} <-
           InstallationCatalog.new(%{}, installed_limits: template.package.installed_limits),
         {:ok, metadata} <-
           ProviderPlan.derive(
             request,
             template.workflow.bundle,
             Map.new(template.missions, fn {name, mission} -> {name, mission.bundle} end),
             []
           ) do
      {:ok,
       %{
         catalog: catalog,
         metadata:
           Map.merge(metadata, %{provider_declarations: [], installation_config_digests: %{}})
       }}
    end
  end

  defp validate_provider_sources(package, catalog) do
    declarations =
      Enum.flat_map(package.providers, fn {destination, selections} ->
        Enum.map(selections, &%{name: &1["name"], destination: destination})
      end)

    if ServingProviderMode.classify(declarations, catalog) == :unsupported,
      do: {:error, :provider_runtime_unsupported},
      else: :ok
  end

  defp construct_retained(package, catalog, inspection_capture) do
    if InstallationCatalog.valid?(catalog) and
         catalog.installed_limits == package.installed_limits do
      with :ok <- validate_provider_sources(package, catalog),
           {:ok, policy} <-
             ExecutionPolicy.new(
               event_policy: package.events.policy,
               result_projection: :json,
               inspection_capture: inspection_capture
             ),
           {:ok, request} <- ServingRequest.new(package, policy),
           {:ok, prepared} <- RunPreparation.prepare(request, catalog) do
        try do
          metadata =
            Map.take(prepared, [
              :provider_declarations,
              :installation_config_digests,
              :effective_data_class,
              :effective_flow,
              :effective_event_policy,
              :effective_application_projection,
              :effective_application_digest,
              :post_selection_context
            ])

          %{workflow: workflow, missions: missions} =
            DeclaredReadEffectValidator.declaration_environments(
              prepared.workflow_bundle,
              prepared.mission_bundles,
              package.missions,
              Enum.map(prepared.provider_declarations, fn declaration ->
                {:ok, descriptor} = InstallationCatalog.fetch(catalog, declaration.name)
                Map.put(declaration, :descriptor, descriptor)
              end)
            )

          effect = validate_effect(workflow, missions, package.entry)

          cond do
            ServingProviderMode.classify(metadata.provider_declarations, catalog) ==
                :unsupported ->
              {:error, :provider_runtime_unsupported}

            match?({:ok, _effect}, effect) ->
              {:ok,
               %__MODULE__{
                 package: package,
                 workflow: %{bundle: prepared.workflow_bundle},
                 missions:
                   Map.new(prepared.mission_bundles, fn {name, bundle} ->
                     {name, %{bundle: bundle}}
                   end),
                 effect: elem(effect, 1),
                 effective_digest: prepared.effective_application_digest,
                 policy: %{
                   input_authority_class: :normal,
                   inspection_capture: inspection_capture,
                   result_projection: :json,
                   effective_event_policy: :normal,
                   publication: :artifact_free,
                   deadline: :absolute_from_reservation
                 },
                 installation_digests: prepared.installation_config_digests,
                 retained:
                   retain(
                     package,
                     prepared.installation_config_digests,
                     prepared.effective_application_digest,
                     %{catalog: catalog, metadata: metadata, request: request}
                   )
               }}

            true ->
              effect
          end
        after
          PreparedRun.close(prepared)
        end
      else
        {:error, %CommandDiagnostic{} = diagnostic} ->
          {:error, preparation_build_code(diagnostic)}

        {:error, code} = error
        when code in [:private_result_unservable, :provider_runtime_unsupported] ->
          error

        _invalid ->
          {:error, :internal_error}
      end
    else
      {:error, :invalid_installation_catalog}
    end
  end

  defp preparation_build_code(%CommandDiagnostic{code: :declared_read_effect_invalid}),
    do: :declared_read_effect_violation

  defp preparation_build_code(%CommandDiagnostic{code: code})
       when code in [:entry_invalid, :mission_undeclared], do: :entry_invalid

  defp preparation_build_code(%CommandDiagnostic{code: :mission_capability_ungranted}),
    do: :environment_invalid

  defp preparation_build_code(%CommandDiagnostic{phase: :bundle}), do: :compilation_failed

  defp preparation_build_code(%CommandDiagnostic{phase: :provider_declaration}),
    do: :invalid_application

  defp preparation_build_code(_diagnostic), do: :internal_error

  defp compile(components, deadline) do
    case BundleCompiler.compile(components, deadline) do
      {:ok, bundle} -> {:ok, bundle}
      {:error, _reason} -> {:error, :compilation_failed}
    end
  end

  defp compile_missions(package, bundle, deadline) do
    case BundleCompiler.compile_named(
           package.missions,
           deadline,
           :erlang.external_size(bundle),
           4_000_000,
           [{package.workflow_components, bundle}]
         ) do
      {:ok, bundles} -> {:ok, bundles}
      {:error, _reason} -> {:error, :compilation_failed}
    end
  end

  defp entry_valid(bundle, package) do
    with :ok <- RunPreparation.validate_entry(bundle, package.entry),
         :ok <- RunPreparation.validate_entry_missions(bundle, package.entry, package.missions) do
      :ok
    else
      {:error, _reason} -> {:error, :entry_invalid}
    end
  end

  defp assemble(package, bundle, bundles) do
    case RunAssembly.assemble_environments(package, bundle, bundles, %{
           workflow: %{capabilities: []},
           mission: %{by_occurrence: %{}}
         }) do
      {:ok, workflow, missions} -> {:ok, workflow, missions}
      {:error, _reason} -> {:error, :environment_invalid}
    end
  end

  defp validate_effect(workflow, missions, entry_ref) do
    entry = Enum.find(workflow.bundle.prelude.exports, &(&1.ref == entry_ref))
    resolved = EntryEffect.resolve(%{workflow: workflow, missions: missions}, entry)

    validation =
      DeclaredReadEffectValidator.validate_assembled(
        workflow,
        missions,
        resolved.capability_effects
      )

    cond do
      entry.declared_effect not in [:read, :write] ->
        {:error, :effect_declaration_required}

      validation != :ok or
          (entry.declared_effect == :read and resolved.effect != :read) ->
        {:error, :declared_read_effect_violation}

      true ->
        {:ok, entry.declared_effect}
    end
  end
end
