defmodule PtcRunner.Kernel.PreparedRun do
  @moduledoc """
  Sealed provider-inert output of phases 4 and 5.

  It contains no filesystem path, credential, endpoint, provider callback
  result, artifact destination, or arbitrary lower-level failure. Its creating
  process owns the linked activity marker until single-use consumption
  atomically transfers lifecycle ownership to the consumer.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.EffectiveApplication
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderPlan
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Kernel.SelectionRules
  alias PtcRunner.Lisp.Prelude

  @enforce_keys [
    :request,
    :workflow_bundle,
    :mission_bundle,
    :entry_source,
    :catalog_attestation,
    :provider_declarations,
    :effective_data_class,
    :effective_flow,
    :effective_event_policy,
    :effective_application_projection,
    :effective_application_digest,
    :post_selection_context,
    :provider_activity
  ]
  defstruct @enforce_keys ++ [attestation: nil]
  @field_keys Enum.sort([:__struct__, :attestation | @enforce_keys])

  @type t :: %__MODULE__{
          request: RunRequest.t(),
          workflow_bundle: FrozenBundle.t(),
          mission_bundle: FrozenBundle.t() | nil,
          entry_source: binary(),
          catalog_attestation: binary(),
          provider_declarations: [map()],
          effective_data_class: :normal | :private_inspection,
          effective_flow: :normal | :private,
          effective_event_policy: :normal | :private,
          effective_application_projection: map(),
          effective_application_digest: binary(),
          post_selection_context: map(),
          provider_activity: ProviderActivity.t(),
          attestation: binary() | nil
        }

  @spec new(
          RunRequest.t(),
          FrozenBundle.t(),
          FrozenBundle.t() | nil,
          binary(),
          ProviderActivity.t(),
          InstallationCatalog.t(),
          map()
        ) :: {:ok, t()} | {:error, :invalid_prepared_run}
  def new(
        request,
        workflow_bundle,
        mission_bundle,
        entry_source,
        provider_activity,
        catalog,
        metadata
      ) do
    if RunRequest.valid?(request) and
         InstallationCatalog.valid?(catalog) and
         bundle_matches?(workflow_bundle, request.package.workflow_components) and
         mission_bundle_matches?(mission_bundle, request.package.mission_components) and
         entry_callable?(workflow_bundle, request.package.entry) and
         entry_source == expected_entry_source(request) and
         metadata_valid?(request, workflow_bundle, mission_bundle, catalog, metadata) and
         ProviderActivity.claim(provider_activity) == :ok do
      prepared = %__MODULE__{
        request: request,
        workflow_bundle: workflow_bundle,
        mission_bundle: mission_bundle,
        entry_source: entry_source,
        catalog_attestation: catalog.attestation,
        provider_declarations: metadata.provider_declarations,
        effective_data_class: metadata.effective_data_class,
        effective_flow: metadata.effective_flow,
        effective_event_policy: metadata.effective_event_policy,
        effective_application_projection: metadata.effective_application_projection,
        effective_application_digest: metadata.effective_application_digest,
        post_selection_context: metadata.post_selection_context,
        provider_activity: provider_activity
      }

      {:ok, %{prepared | attestation: Attestation.attest(__MODULE__, payload(prepared))}}
    else
      {:error, :invalid_prepared_run}
    end
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = prepared),
    do: sealed_valid?(prepared) and ProviderActivity.claimed?(prepared.provider_activity)

  def valid?(_prepared), do: false

  @doc false
  @spec active_valid?(term()) :: boolean()
  def active_valid?(%__MODULE__{} = prepared),
    do: sealed_valid?(prepared) and ProviderActivity.value(prepared.provider_activity) == true

  def active_valid?(_prepared), do: false

  @doc false
  @spec consumed_valid?(term()) :: boolean()
  def consumed_valid?(%__MODULE__{} = prepared),
    do: sealed_valid?(prepared) and ProviderActivity.consumed?(prepared.provider_activity)

  def consumed_valid?(_prepared), do: false

  defp sealed_valid?(%__MODULE__{attestation: attestation} = prepared) do
    Enum.sort(Map.keys(prepared)) == @field_keys and
      RunRequest.valid?(prepared.request) and
      bundle_matches?(
        prepared.workflow_bundle,
        prepared.request.package.workflow_components
      ) and
      mission_bundle_matches?(
        prepared.mission_bundle,
        prepared.request.package.mission_components
      ) and
      entry_callable?(prepared.workflow_bundle, prepared.request.package.entry) and
      prepared.entry_source == expected_entry_source(prepared.request) and
      sealed_metadata_valid?(
        prepared.request,
        prepared.workflow_bundle,
        prepared.mission_bundle,
        Map.take(prepared, [
          :provider_declarations,
          :effective_data_class,
          :effective_flow,
          :effective_event_policy,
          :effective_application_projection,
          :effective_application_digest,
          :post_selection_context
        ])
      ) and
      Attestation.valid?(__MODULE__, payload(prepared), attestation)
  end

  @doc false
  @spec consume(t()) :: :ok | {:error, :invalid_prepared_run}
  def consume(%__MODULE__{} = prepared) do
    if valid?(prepared) and ProviderActivity.consume(prepared.provider_activity) == :ok,
      do: :ok,
      else: {:error, :invalid_prepared_run}
  end

  def consume(_prepared), do: {:error, :invalid_prepared_run}

  @doc false
  @spec authorize_executor(t(), pid()) :: :ok | {:error, :invalid_prepared_run}
  def authorize_executor(%__MODULE__{} = prepared, executor) when is_pid(executor) do
    if consumed_valid?(prepared) and
         ProviderActivity.authorize_executor(prepared.provider_activity, executor) == :ok,
       do: :ok,
       else: {:error, :invalid_prepared_run}
  end

  def authorize_executor(_prepared, _executor), do: {:error, :invalid_prepared_run}

  @doc false
  @spec begin_build(t()) :: :ok | {:error, :invalid_prepared_run}
  def begin_build(%__MODULE__{} = prepared) do
    if sealed_valid?(prepared) and
         ProviderActivity.begin_build(prepared.provider_activity) == :ok,
       do: :ok,
       else: {:error, :invalid_prepared_run}
  end

  def begin_build(_prepared), do: {:error, :invalid_prepared_run}

  @doc """
  Idempotently releases the prepared run's activity owner.

  After `consume/1` transfers ownership, only the consuming process can release
  a live owner; the former owner receives `{:error, :not_owner}`. A bounded-call
  failure returns `{:error, :provider_activity_unavailable}`.
  """
  @spec close(t()) ::
          :ok | {:error, :not_owner | :provider_activity_unavailable}
  def close(%__MODULE__{provider_activity: activity}), do: ProviderActivity.stop(activity)
  def close(_prepared), do: :ok

  defp mission_bundle_matches?(nil, []), do: true

  defp mission_bundle_matches?(%FrozenBundle{} = bundle, [_component | _rest] = components),
    do: bundle_matches?(bundle, components)

  defp mission_bundle_matches?(_bundle, _components), do: false

  defp bundle_matches?(%FrozenBundle{} = bundle, components) when is_list(components) do
    with true <- FrozenBundle.valid?(bundle),
         {:ok, actual} <- compiled_projection(bundle.components),
         expected <- Map.new(components, &component_projection/1),
         true <- actual == expected,
         true <- bundle.component_ids == Enum.map(bundle.components, & &1.id) do
      true
    else
      _invalid -> false
    end
  end

  defp bundle_matches?(_bundle, _components), do: false

  defp compiled_projection(components) when is_list(components) do
    Enum.reduce_while(components, {:ok, %{}}, fn
      %{id: id, source_hash: source_hash, dependencies: dependencies}, {:ok, projection}
      when is_binary(id) and is_binary(source_hash) and is_list(dependencies) ->
        if Map.has_key?(projection, id) do
          {:halt, :error}
        else
          {:cont, {:ok, Map.put(projection, id, {source_hash, dependencies})}}
        end

      _component, _projection ->
        {:halt, :error}
    end)
  end

  defp component_projection(%Component{} = component) do
    source_hash =
      component.source
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    {component.id, {source_hash, component.dependencies}}
  end

  @doc false
  @spec entry_callable?(FrozenBundle.t(), binary()) :: boolean()
  def entry_callable?(%FrozenBundle{} = bundle, entry) when is_binary(entry) do
    case Prelude.fetch_export(bundle.prelude, entry) do
      {:ok, %{kind: :function, arity: 1}} ->
        true

      {:ok, %{kind: :function, arity: :variadic, min_arity: min_arity}}
      when min_arity in 0..1 ->
        true

      _missing_or_incompatible ->
        false
    end
  end

  def entry_callable?(_bundle, _entry), do: false

  defp expected_entry_source(request),
    do: "(#{request.package.entry} data/input)"

  defp metadata_valid?(request, workflow_bundle, mission_bundle, catalog, metadata)
       when is_map(metadata) do
    with true <-
           Enum.sort(Map.keys(metadata)) ==
             [
               :effective_application_digest,
               :effective_application_projection,
               :effective_data_class,
               :effective_event_policy,
               :effective_flow,
               :post_selection_context,
               :provider_declarations
             ],
         {:ok, declarations} <-
           declarations_valid?(
             metadata.provider_declarations,
             request,
             catalog
           ),
         {:ok, expected} <-
           ProviderPlan.derive(request, workflow_bundle, mission_bundle, declarations),
         true <- Map.drop(metadata, [:provider_declarations]) == expected,
         true <-
           selection_contexts_valid?(
             declarations,
             request,
             workflow_bundle,
             mission_bundle,
             expected.post_selection_context
           ) do
      true
    else
      _invalid -> false
    end
  end

  defp metadata_valid?(_request, _workflow_bundle, _mission_bundle, _catalog, _metadata),
    do: false

  defp sealed_metadata_valid?(request, workflow_bundle, mission_bundle, metadata)
       when is_map(metadata) do
    with true <-
           Enum.sort(Map.keys(metadata)) ==
             [
               :effective_application_digest,
               :effective_application_projection,
               :effective_data_class,
               :effective_event_policy,
               :effective_flow,
               :post_selection_context,
               :provider_declarations
             ],
         true <- metadata.effective_data_class in [:normal, :private_inspection],
         true <- metadata.effective_flow in [:normal, :private],
         true <- metadata.effective_event_policy in [:normal, :private],
         true <-
           sealed_declarations_valid?(metadata.provider_declarations, request.package.providers),
         providers <- provider_projection(metadata.provider_declarations),
         {:ok, identity} <-
           EffectiveApplication.build(
             request,
             workflow_bundle,
             mission_bundle,
             providers,
             metadata.effective_event_policy
           ),
         true <- identity.projection == metadata.effective_application_projection,
         true <- identity.digest == metadata.effective_application_digest,
         true <-
           post_selection_context_valid?(request, workflow_bundle, mission_bundle, metadata) do
      true
    else
      _invalid -> false
    end
  end

  defp declarations_valid?(
         declarations,
         request,
         catalog
       )
       when is_list(declarations) do
    requested = request.package.providers

    expected =
      for destination <- [:workflow, :mission],
          {selection, index} <- requested |> Map.fetch!(destination) |> Enum.with_index(),
          do: {destination, index, selection["name"], Map.get(selection, "config", %{})}

    if length(declarations) == length(expected) do
      declarations
      |> Enum.zip(expected)
      |> Enum.reduce_while({:ok, []}, fn
        {declaration, {destination, index, name, original_config}}, {:ok, validated} ->
          case validate_declaration(declaration, original_config, request, catalog) do
            {:ok, %{destination: ^destination, index: ^index, name: ^name} = entry} ->
              {:cont, {:ok, [entry | validated]}}

            _invalid ->
              {:halt, :error}
          end
      end)
      |> case do
        {:ok, validated} -> {:ok, Enum.reverse(validated)}
        :error -> :error
      end
    else
      :error
    end
  end

  defp declarations_valid?(
         _declarations,
         _request,
         _catalog
       ),
       do: :error

  defp validate_declaration(
         %{
           destination: destination,
           index: index,
           name: name,
           provider_projection: provider_projection,
           config: config,
           validation_state: validation_state,
           selection_context: selection_context
         } = declaration,
         original_config,
         request,
         catalog
       )
       when map_size(declaration) == 7 and destination in [:workflow, :mission] and
              is_integer(index) and index >= 0 and is_binary(name) and is_map(config) and
              is_map(provider_projection) and is_map(selection_context) do
    with {:ok, %ProviderDescriptor{} = descriptor} <- InstallationCatalog.fetch(catalog, name),
         expected_state <-
           if(descriptor.selection_validation == :active,
             do: :active_required,
             else: :declarative
           ),
         true <- validation_state == expected_state,
         {:ok, ^config} <-
           SelectionRules.normalize(
             descriptor.selection_rules,
             original_config,
             request.package.limits
           ),
         true <-
           provider_projection == ProviderDescriptor.public_projection(descriptor, name, config),
         true <- is_map(selection_context) do
      {:ok, Map.put(declaration, :descriptor, descriptor)}
    else
      _invalid -> :error
    end
  end

  defp validate_declaration(
         _declaration,
         _original_config,
         _request,
         _catalog
       ),
       do: :error

  defp sealed_declarations_valid?(declarations, requested) when is_list(declarations) do
    expected =
      for destination <- [:workflow, :mission],
          {selection, index} <- requested |> Map.fetch!(destination) |> Enum.with_index(),
          do: {destination, index, selection["name"]}

    actual =
      Enum.map(declarations, fn
        %{
          destination: destination,
          index: index,
          name: name,
          provider_projection: %{"name" => name, "config" => config},
          config: config,
          validation_state: validation_state,
          selection_context: selection_context
        } = declaration
        when map_size(declaration) == 7 and destination in [:workflow, :mission] and
               is_integer(index) and index >= 0 and is_binary(name) and is_map(config) and
               validation_state in [:declarative, :active_required] and
               is_map(selection_context) ->
          {destination, index, name}

        _invalid ->
          :invalid
      end)

    actual == expected
  end

  defp sealed_declarations_valid?(_declarations, _requested), do: false

  defp provider_projection(declarations) do
    Map.new([:workflow, :mission], fn destination ->
      providers =
        declarations
        |> Enum.filter(&(&1.destination == destination))
        |> Enum.map(& &1.provider_projection)

      {destination, providers}
    end)
  end

  defp post_selection_context_valid?(request, workflow_bundle, mission_bundle, metadata) do
    expected_flow =
      if request.input.authority == :private or
           metadata.effective_data_class == :private_inspection,
         do: :private,
         else: :normal

    expected_event_policy =
      if request.policy.event_policy == :private or expected_flow == :private,
        do: :private,
        else: :normal

    metadata.post_selection_context == %{
      application_content_digest: request.package.application_content_digest,
      effective_application_digest: metadata.effective_application_digest,
      bundle_hashes: %{
        workflow: workflow_bundle.hash,
        mission: if(mission_bundle, do: mission_bundle.hash, else: nil)
      },
      input_authority_class: request.input.authority,
      limits: request.package.limits,
      effective_data_class: metadata.effective_data_class,
      effective_flow: expected_flow,
      effective_event_policy: expected_event_policy
    } and metadata.effective_flow == expected_flow and
      metadata.effective_event_policy == expected_event_policy
  end

  defp selection_contexts_valid?(
         declarations,
         request,
         workflow_bundle,
         mission_bundle,
         post_selection_context
       ) do
    Enum.all?(declarations, fn declaration ->
      selection_context_valid?(
        declaration.selection_context,
        request,
        workflow_bundle,
        mission_bundle,
        declaration,
        post_selection_context
      )
    end)
  end

  defp selection_context_valid?(
         context,
         request,
         workflow_bundle,
         mission_bundle,
         declaration,
         post_selection_context
       ) do
    expected =
      Map.merge(
        %{
          display:
            ProviderDescriptor.display_projection(declaration.descriptor, declaration.name),
          application_content_digest: request.package.application_content_digest,
          bundle_hashes: %{
            workflow: workflow_bundle.hash,
            mission: if(mission_bundle, do: mission_bundle.hash, else: nil)
          },
          input_authority_class: request.input.authority,
          destination: declaration.destination,
          index: declaration.index,
          limits: request.package.limits
        },
        post_selection_context
      )

    is_reference(Map.get(context, :execution_scope_id)) and
      Map.delete(context, :execution_scope_id) == expected
  end

  defp payload(prepared) do
    {
      prepared.request,
      prepared.workflow_bundle,
      prepared.mission_bundle,
      prepared.entry_source,
      prepared.catalog_attestation,
      prepared.provider_declarations,
      prepared.effective_data_class,
      prepared.effective_flow,
      prepared.effective_event_policy,
      prepared.effective_application_projection,
      prepared.effective_application_digest,
      prepared.post_selection_context,
      prepared.provider_activity
    }
  end
end
