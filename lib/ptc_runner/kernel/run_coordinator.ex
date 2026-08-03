defmodule PtcRunner.Kernel.RunCoordinator do
  @moduledoc """
  Path-free, provider-inert phases 4 and 5 of command preparation.

  Bundle compilation and public-entry validation run before provider
  declarations. Provider declaration checks inspect only installed aliases;
  they never invoke a builder, credential resolver, preflight callback, OAuth
  context, store, process, or network operation.
  """

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.ApplicationSource
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderPlan
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Kernel.SelectionRules

  @spec prepare(RunRequest.t(), InstallationCatalog.t()) ::
          {:ok, PreparedRun.t()} | {:error, CommandDiagnostic.t()}
  def prepare(%RunRequest{} = request, %InstallationCatalog{} = catalog) do
    with true <- RunRequest.valid?(request),
         true <- InstallationCatalog.valid?(catalog),
         true <- catalog.installed_limits == request.package.installed_limits,
         {:ok, workflow_bundle} <- compile_required(request.package.workflow_components),
         {:ok, mission_bundle} <- compile_optional(request.package.mission_components),
         :ok <- validate_entry(workflow_bundle, request.package.entry),
         {:ok, declarations} <-
           prepare_providers(request, workflow_bundle, mission_bundle, catalog),
         {:ok, derived} <-
           derive_provider_plan(request, workflow_bundle, mission_bundle, declarations),
         declarations <- add_post_selection_context(declarations, derived.post_selection_context),
         prepared_declarations <- prepared_declarations(declarations),
         {:ok, prepared} <-
           ProviderActivity.start_owned(fn activity ->
             PreparedRun.new(
               request,
               workflow_bundle,
               mission_bundle,
               "(#{request.package.entry} data/input)",
               activity,
               catalog,
               Map.put(derived, :provider_declarations, prepared_declarations)
             )
           end) do
      {:ok, prepared}
    else
      false -> {:error, diagnostic(:internal, :internal_error)}
      {:error, %CommandDiagnostic{} = diagnostic} -> {:error, diagnostic}
      {:error, _reason} -> {:error, diagnostic(:internal, :internal_error)}
    end
  rescue
    _exception -> {:error, diagnostic(:internal, :internal_error)}
  catch
    _kind, _reason -> {:error, diagnostic(:internal, :internal_error)}
  end

  def prepare(_request, _registry),
    do: {:error, diagnostic(:internal, :internal_error)}

  defp compile_required(components) do
    case Kernel.compile_bundle(components) do
      {:ok, bundle} -> {:ok, bundle}
      {:error, reason} -> {:error, bundle_diagnostic(reason, components)}
    end
  end

  defp compile_optional([]), do: {:ok, nil}

  defp compile_optional(components) do
    case Kernel.compile_bundle(components) do
      {:ok, bundle} -> {:ok, bundle}
      {:error, reason} -> {:error, bundle_diagnostic(reason, components)}
    end
  end

  defp bundle_diagnostic(%{reason: reason} = failure, components)
       when reason in [
              :bundle_limit_exceeded,
              :bundle_artifact_exceeded,
              :bundle_diagnostic_exceeded,
              :bundle_compile_heap_exceeded,
              :bundle_compile_timeout
            ],
       do: diagnostic(:bundle, :bundle_limit_exceeded, source_opts(failure, components))

  defp bundle_diagnostic(%{reason: reason} = failure, components)
       when reason in [:component_compile_error, :bundle_compile_error, :bundle_compile_failed],
       do: diagnostic(:bundle, :compile_failed, source_opts(failure, components))

  defp bundle_diagnostic(failure, components),
    do: diagnostic(:bundle, :bundle_invalid, source_opts(failure, components))

  defp source_opts(%{id: id}, components) when is_binary(id) do
    case Enum.find(components, &match?(%Component{id: ^id}, &1)) do
      %Component{} = component -> component_source_opts(component)
      nil -> []
    end
  end

  defp source_opts(_failure, _components), do: []

  defp component_source_opts(%Component{id: id, origin: origin}) do
    name =
      cond do
        ApplicationSource.valid_name?(origin) -> origin
        ApplicationSource.valid_name?(id) -> id
        true -> nil
      end

    case name do
      nil ->
        []

      safe_name ->
        {:ok, source} = CommandSource.new(:component, safe_name)
        [source: source]
    end
  end

  @doc false
  @spec validate_entry(PtcRunner.Kernel.FrozenBundle.t(), binary()) ::
          :ok | {:error, CommandDiagnostic.t()}
  def validate_entry(workflow_bundle, entry) do
    if PreparedRun.entry_callable?(workflow_bundle, entry),
      do: :ok,
      else: {:error, diagnostic(:bundle, :entry_invalid)}
  end

  defp prepare_providers(request, workflow_bundle, mission_bundle, catalog) do
    request.package.providers
    |> provider_specs()
    |> Enum.reduce_while({:ok, []}, fn {destination, selection, index}, {:ok, prepared} ->
      name = selection["name"]
      occurrence = %{destination: destination, index: index}

      case InstallationCatalog.fetch(catalog, name) do
        {:ok, descriptor} ->
          prepare_provider(
            request,
            workflow_bundle,
            mission_bundle,
            descriptor,
            name,
            Map.get(selection, "config", %{}),
            occurrence,
            prepared
          )

        :error ->
          {:ok, subject} = CommandSubject.provider(name, :declaration, occurrence)

          {:halt,
           {:error, diagnostic(:provider_declaration, :provider_unknown, subject: subject)}}
      end
    end)
    |> reverse_success()
  end

  defp prepare_provider(
         request,
         workflow_bundle,
         mission_bundle,
         descriptor,
         name,
         config,
         occurrence,
         prepared
       ) do
    with :ok <- validate_placement(descriptor, name, occurrence),
         selection_context <-
           selection_context(
             request,
             workflow_bundle,
             mission_bundle,
             descriptor,
             name,
             occurrence
           ),
         {:ok, normalized} <-
           SelectionRules.normalize(descriptor.selection_rules, config, request.package.limits) do
      declaration = %{
        name: name,
        destination: occurrence.destination,
        index: occurrence.index,
        descriptor: descriptor,
        config: normalized,
        validation_state:
          if(descriptor.selection_validation == :active,
            do: :active_required,
            else: :declarative
          ),
        selection_context: selection_context
      }

      {:cont, {:ok, [declaration | prepared]}}
    else
      {:error, %CommandDiagnostic{} = diagnostic} ->
        {:halt, {:error, diagnostic}}

      {:error, :invalid_selection} ->
        {:ok, subject} = CommandSubject.provider(name, :selection, occurrence)
        {:halt, {:error, diagnostic(:provider_declaration, :selection_invalid, subject: subject)}}
    end
  end

  defp validate_placement(descriptor, name, occurrence) do
    if occurrence.destination in descriptor.destinations do
      :ok
    else
      {:ok, subject} = CommandSubject.provider(name, :selection, occurrence)
      {:error, diagnostic(:provider_declaration, :placement_denied, subject: subject)}
    end
  end

  defp selection_context(
         request,
         workflow_bundle,
         mission_bundle,
         descriptor,
         name,
         occurrence
       ) do
    %{
      display: ProviderDescriptor.display_projection(descriptor, name),
      application_content_digest: request.package.application_content_digest,
      bundle_hashes: %{
        workflow: workflow_bundle.hash,
        mission: if(mission_bundle, do: mission_bundle.hash, else: nil)
      },
      input_authority_class: request.input.authority,
      execution_scope_id: make_ref(),
      destination: occurrence.destination,
      index: occurrence.index,
      limits: request.package.limits
    }
  end

  defp derive_provider_plan(request, workflow_bundle, mission_bundle, declarations) do
    case ProviderPlan.derive(request, workflow_bundle, mission_bundle, declarations) do
      {:ok, derived} ->
        {:ok, derived}

      {:error, {:dependency_invalid, nil}} ->
        {:error, diagnostic(:provider_declaration, :dependency_invalid)}

      {:error, {:dependency_invalid, declaration}} ->
        {:ok, subject} = CommandSubject.provider(declaration.name, :declaration)
        {:error, diagnostic(:provider_declaration, :dependency_invalid, subject: subject)}

      {:error, {:data_policy_denied, declaration}} ->
        occurrence = %{destination: declaration.destination, index: declaration.index}
        {:ok, subject} = CommandSubject.provider(declaration.name, :selection, occurrence)
        {:error, diagnostic(:provider_declaration, :data_policy_denied, subject: subject)}
    end
  end

  defp add_post_selection_context(declarations, context) do
    Enum.map(declarations, fn declaration ->
      Map.update!(declaration, :selection_context, &Map.merge(&1, context))
    end)
  end

  defp prepared_declarations(declarations) do
    Enum.map(declarations, fn declaration ->
      %{
        name: declaration.name,
        destination: declaration.destination,
        index: declaration.index,
        config: declaration.config,
        validation_state: declaration.validation_state,
        selection_context: declaration.selection_context,
        provider_projection:
          ProviderDescriptor.public_projection(
            declaration.descriptor,
            declaration.name,
            declaration.config
          )
      }
    end)
  end

  defp provider_specs(providers) do
    for destination <- [:workflow, :mission],
        {selection, index} <- providers |> Map.fetch!(destination) |> Enum.with_index(),
        do: {destination, selection, index}
  end

  defp reverse_success({:ok, declarations}), do: {:ok, Enum.reverse(declarations)}
  defp reverse_success({:error, _diagnostic} = error), do: error

  @spec validation_result(PreparedRun.t()) ::
          {:ok, map()}
          | {:error, :invalid_prepared_run}
          | {:error, {:selection_unverifiable, binary(), CommandSubject.occurrence()}}
  @doc "Projects the closed validation-success result from one sealed preparation."
  def validation_result(%PreparedRun{} = prepared) do
    cond do
      not PreparedRun.valid?(prepared) or
          ProviderActivity.value(prepared.provider_activity) != false ->
        {:error, :invalid_prepared_run}

      declaration = first_active_declaration(prepared.provider_declarations) ->
        {:error,
         {:selection_unverifiable, declaration.name,
          %{destination: declaration.destination, index: declaration.index}}}

      true ->
        {:ok,
         %{
           "application_content_digest" =>
             "sha256:" <> prepared.request.package.application_content_digest,
           "effective_application_digest" => prepared.effective_application_digest,
           "workflow_bundle_hash" => prepared.workflow_bundle.hash,
           "mission_bundle_hash" =>
             if(prepared.mission_bundle, do: prepared.mission_bundle.hash, else: nil),
           "provider_activity" => false
         }}
    end
  end

  defp first_active_declaration(declarations) do
    declarations
    |> Enum.filter(&(&1.validation_state == :active_required))
    |> Enum.sort_by(fn declaration ->
      {declaration.name, destination_rank(declaration.destination), declaration.index}
    end)
    |> List.first()
  end

  defp destination_rank(:workflow), do: 0
  defp destination_rank(:mission), do: 1

  defp diagnostic(phase, code, opts \\ []),
    do: CommandDiagnostic.new!(phase, code, opts)
end
