defmodule PtcRunner.Kernel.ProviderPlan do
  @moduledoc false

  alias PtcRunner.Kernel.EffectiveApplication
  alias PtcRunner.Kernel.ProviderDescriptor

  @spec derive(
          PtcRunner.Kernel.RunRequest.t(),
          PtcRunner.Kernel.FrozenBundle.t(),
          PtcRunner.Kernel.FrozenBundle.t() | nil,
          [map()]
        ) :: {:ok, map()} | {:error, {:dependency_invalid | :data_policy_denied, map() | nil}}
  def derive(request, workflow_bundle, mission_bundle, declarations) do
    with :ok <- validate_dependencies(declarations),
         :ok <- validate_single_workflow_llm(declarations),
         effective_data_class <- effective_data_class(request, declarations),
         :ok <- providers_accept(declarations, effective_data_class),
         effective_flow <- effective_flow(request, effective_data_class),
         effective_event_policy <- effective_event_policy(request, effective_flow),
         providers <- provider_projection(declarations),
         {:ok, effective} <-
           EffectiveApplication.build(
             request,
             workflow_bundle,
             mission_bundle,
             providers,
             effective_event_policy
           ) do
      {:ok,
       %{
         effective_data_class: effective_data_class,
         effective_flow: effective_flow,
         effective_event_policy: effective_event_policy,
         effective_application_projection: effective.projection,
         effective_application_digest: effective.digest,
         post_selection_context:
           post_selection_context(
             request,
             workflow_bundle,
             mission_bundle,
             effective.digest,
             effective_data_class,
             effective_flow,
             effective_event_policy
           )
       }}
    end
  end

  defp validate_dependencies(declarations) do
    provided = Enum.flat_map(declarations, & &1.descriptor.provides)
    counts = Enum.frequencies(provided)

    case Enum.find(declarations, fn declaration ->
           Enum.any?(declaration.descriptor.requires, &(Map.get(counts, &1, 0) != 1))
         end) do
      nil ->
        case cycle_declaration(declarations) do
          nil -> :ok
          declaration -> {:error, {:dependency_invalid, declaration}}
        end

      declaration ->
        {:error, {:dependency_invalid, declaration}}
    end
  end

  defp validate_single_workflow_llm(declarations) do
    workflow_llms =
      Enum.filter(declarations, fn declaration ->
        declaration.destination == :workflow and declaration.descriptor.workflow_llm?
      end)

    if length(workflow_llms) <= 1,
      do: :ok,
      else: {:error, {:dependency_invalid, List.first(workflow_llms)}}
  end

  defp effective_data_class(request, declarations) do
    input_class = if request.input.authority == :private, do: :private_inspection, else: :normal

    Enum.reduce(declarations, input_class, fn declaration, current ->
      strictest_data_class(current, declaration.descriptor.data_class)
    end)
  end

  defp strictest_data_class(:private_inspection, _next), do: :private_inspection
  defp strictest_data_class(_current, :private_inspection), do: :private_inspection
  defp strictest_data_class(:normal, :normal), do: :normal

  defp providers_accept(declarations, effective_data_class) do
    case Enum.find(declarations, &(effective_data_class not in &1.descriptor.accepts_data)) do
      nil -> :ok
      declaration -> {:error, {:data_policy_denied, declaration}}
    end
  end

  defp provider_projection(declarations) do
    Map.new([:workflow, :mission], fn destination ->
      providers =
        declarations
        |> Enum.filter(&(&1.destination == destination))
        |> Enum.map(&ProviderDescriptor.public_projection(&1.descriptor, &1.name, &1.config))

      {destination, providers}
    end)
  end

  defp effective_flow(request, effective_data_class) do
    if request.input.authority == :private or effective_data_class == :private_inspection,
      do: :private,
      else: :normal
  end

  defp effective_event_policy(request, effective_flow) do
    if request.policy.event_policy == :private or effective_flow == :private,
      do: :private,
      else: :normal
  end

  defp post_selection_context(
         request,
         workflow_bundle,
         mission_bundle,
         effective_digest,
         effective_data_class,
         effective_flow,
         effective_event_policy
       ) do
    %{
      application_content_digest: request.package.application_content_digest,
      effective_application_digest: effective_digest,
      bundle_hashes: %{
        workflow: workflow_bundle.hash,
        mission: if(mission_bundle, do: mission_bundle.hash, else: nil)
      },
      input_authority_class: request.input.authority,
      limits: request.package.limits,
      effective_data_class: effective_data_class,
      effective_flow: effective_flow,
      effective_event_policy: effective_event_policy
    }
  end

  defp cycle_declaration(declarations) do
    providers =
      for declaration <- declarations,
          service <- declaration.descriptor.provides,
          into: %{},
          do: {service, occurrence_key(declaration)}

    dependencies =
      Map.new(declarations, fn declaration ->
        required =
          declaration.descriptor.requires
          |> Enum.map(&Map.get(providers, &1))
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        {occurrence_key(declaration), required}
      end)

    result =
      dependencies
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reduce_while(%{}, fn node, marks ->
        case visit_dependency(node, dependencies, marks) do
          {:ok, marks} -> {:cont, marks}
          {:cycle, cycle, _marks} -> {:halt, {:cycle, cycle}}
        end
      end)

    case result do
      {:cycle, occurrence} -> Enum.find(declarations, &(occurrence_key(&1) == occurrence))
      _marks -> nil
    end
  end

  defp visit_dependency(node, dependencies, marks) do
    case Map.get(marks, node) do
      :visiting ->
        {:cycle, node, marks}

      :visited ->
        {:ok, marks}

      nil ->
        marks = Map.put(marks, node, :visiting)

        dependencies
        |> Map.fetch!(node)
        |> Enum.sort()
        |> Enum.reduce_while({:ok, marks}, fn dependency, {:ok, nested_marks} ->
          case visit_dependency(dependency, dependencies, nested_marks) do
            {:ok, nested_marks} -> {:cont, {:ok, nested_marks}}
            {:cycle, cycle, nested_marks} -> {:halt, {:cycle, cycle, nested_marks}}
          end
        end)
        |> case do
          {:ok, marks} -> {:ok, Map.put(marks, node, :visited)}
          {:cycle, _cycle, _marks} = cycle -> cycle
        end
    end
  end

  defp occurrence_key(declaration), do: {declaration.destination, declaration.index}
end
