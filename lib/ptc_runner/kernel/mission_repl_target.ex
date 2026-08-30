defmodule PtcRunner.Kernel.MissionReplTarget do
  @moduledoc false

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderPlan

  @enforce_keys [
    :mission_name,
    :component_ids,
    :prepared_binding,
    :catalog_attestation,
    :direct_occurrences,
    :closure_occurrences,
    :declarations,
    :aliases,
    :direct_aliases,
    :effective_data_class,
    :effective_flow,
    :effective_event_policy,
    :attestation
  ]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @type occurrence :: %{destination: :mission, index: non_neg_integer()}
  @type t :: %__MODULE__{
          mission_name: binary(),
          component_ids: [binary()],
          prepared_binding: binary(),
          catalog_attestation: binary(),
          direct_occurrences: [occurrence()],
          closure_occurrences: [map()],
          declarations: [map()],
          aliases: [binary()],
          direct_aliases: [binary()],
          effective_data_class: :normal | :private_inspection,
          effective_flow: :normal | :private,
          effective_event_policy: :normal | :private,
          attestation: binary()
        }

  @spec new(PreparedRun.t(), InstallationCatalog.t(), binary()) ::
          {:ok, t()} | {:error, {:unknown_mission, [binary()]} | :invalid_mission_repl_target}
  def new(%PreparedRun{} = prepared, %InstallationCatalog{} = catalog, mission_name)
      when is_binary(mission_name) do
    with true <- PreparedRun.inactive_valid?(prepared),
         true <- InstallationCatalog.valid?(catalog),
         true <- prepared.catalog_attestation == catalog.attestation,
         {:ok, fields} <- derive(prepared, catalog, mission_name) do
      target = struct!(__MODULE__, Map.put(fields, :attestation, <<>>))
      {:ok, %{target | attestation: Attestation.attest(__MODULE__, payload(target))}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_mission_repl_target}
    end
  rescue
    _exception -> {:error, :invalid_mission_repl_target}
  end

  def new(_prepared, _catalog, _mission_name), do: {:error, :invalid_mission_repl_target}

  @spec valid_for?(term(), term(), term()) :: boolean()
  def valid_for?(
        %__MODULE__{attestation: attestation} = target,
        %PreparedRun{} = prepared,
        %InstallationCatalog{} = catalog
      ) do
    Enum.sort(Map.keys(target)) == @field_keys and PreparedRun.sealed?(prepared) and
      InstallationCatalog.valid?(catalog) and
      prepared.catalog_attestation == catalog.attestation and
      target.prepared_binding == prepared.attestation and
      target.catalog_attestation == catalog.attestation and
      match?({:ok, ^target}, rederive(target, prepared, catalog)) and
      Attestation.valid?(__MODULE__, payload(target), attestation)
  rescue
    _exception -> false
  end

  def valid_for?(_target, _prepared, _catalog), do: false

  @spec bound_to_prepared?(term(), term()) :: boolean()
  def bound_to_prepared?(
        %__MODULE__{attestation: attestation} = target,
        %PreparedRun{} = prepared
      ) do
    Enum.sort(Map.keys(target)) == @field_keys and PreparedRun.sealed?(prepared) and
      target.prepared_binding == prepared.attestation and
      target.catalog_attestation == prepared.catalog_attestation and
      Attestation.valid?(__MODULE__, payload(target), attestation)
  end

  def bound_to_prepared?(_target, _prepared), do: false

  @spec provider_free?(t()) :: boolean()
  def provider_free?(%__MODULE__{declarations: declarations}), do: declarations == []

  @doc false
  @spec declarations_for(PreparedRun.t(), InstallationCatalog.t(), :all | t()) ::
          {:ok, [map()]} | :error
  def declarations_for(%PreparedRun{} = prepared, _catalog, :all),
    do: {:ok, prepared.provider_declarations}

  def declarations_for(
        %PreparedRun{} = prepared,
        %InstallationCatalog{} = catalog,
        %__MODULE__{} = target
      ) do
    if valid_for?(target, prepared, catalog), do: {:ok, target.declarations}, else: :error
  end

  def declarations_for(_prepared, _catalog, _target), do: :error

  defp rederive(target, prepared, catalog) do
    case derive(prepared, catalog, target.mission_name) do
      {:ok, fields} ->
        rebuilt = struct!(__MODULE__, Map.put(fields, :attestation, target.attestation))
        {:ok, rebuilt}

      {:error, _reason} = error ->
        error
    end
  end

  defp derive(prepared, catalog, mission_name) do
    missions = prepared.request.package.missions

    case Map.fetch(missions, mission_name) do
      {:ok, mission} -> derive_selected(prepared, catalog, mission_name, mission)
      :error -> {:error, {:unknown_mission, missions |> Map.keys() |> Enum.sort()}}
    end
  end

  defp derive_selected(prepared, catalog, mission_name, mission) do
    occurrences = occurrences(prepared, catalog)
    by_site = Map.new(occurrences, &{site(&1), &1})
    direct_sites = Enum.map(mission.provider_occurrences, &{:mission, &1})

    with true <- direct_sites == Enum.uniq(direct_sites),
         true <- Enum.all?(direct_sites, &Map.has_key?(by_site, &1)),
         closure_sites <- close_over(MapSet.new(direct_sites), by_site),
         closure_occurrences <- Enum.filter(occurrences, &MapSet.member?(closure_sites, site(&1))),
         declarations <-
           Enum.filter(prepared.provider_declarations, &MapSet.member?(closure_sites, site(&1))),
         policy_declarations <-
           Enum.map(declarations, fn declaration ->
             Map.put(declaration, :descriptor, Map.fetch!(catalog.descriptors, declaration.name))
           end),
         {:ok, policy} <- ProviderPlan.derive_policy(prepared.request, policy_declarations) do
      direct_occurrences = Enum.map(direct_sites, &occurrence/1)

      {:ok,
       %{
         mission_name: mission_name,
         component_ids: Enum.map(mission.components, & &1.id),
         prepared_binding: prepared.attestation,
         catalog_attestation: catalog.attestation,
         direct_occurrences: direct_occurrences,
         closure_occurrences: closure_occurrences,
         declarations: declarations,
         aliases: declarations |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.sort(),
         direct_aliases:
           direct_occurrences
           |> Enum.map(&Map.fetch!(by_site, site(&1)).name)
           |> Enum.uniq(),
         effective_data_class: policy.effective_data_class,
         effective_flow: policy.effective_flow,
         effective_event_policy: policy.effective_event_policy
       }}
    else
      _invalid -> {:error, :invalid_mission_repl_target}
    end
  end

  defp occurrences(prepared, catalog) do
    Enum.map(prepared.provider_declarations, fn declaration ->
      descriptor = Map.fetch!(catalog.descriptors, declaration.name)

      %{
        name: declaration.name,
        destination: declaration.destination,
        index: declaration.index,
        requires: descriptor.requires,
        provides: descriptor.provides
      }
    end)
  end

  defp close_over(selected, by_site) do
    providers =
      by_site
      |> Map.values()
      |> Enum.reduce(%{}, fn provider, acc ->
        Enum.reduce(provider.provides, acc, &Map.put(&2, &1, site(provider)))
      end)

    added =
      selected
      |> Enum.flat_map(&Map.fetch!(by_site, &1).requires)
      |> Enum.map(&Map.get(providers, &1))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    next = MapSet.union(selected, added)
    if MapSet.equal?(next, selected), do: selected, else: close_over(next, by_site)
  end

  defp occurrence({:mission, index}), do: %{destination: :mission, index: index}
  defp site(%{destination: destination, index: index}), do: {destination, index}

  defp payload(target), do: Map.delete(target, :attestation)
end
