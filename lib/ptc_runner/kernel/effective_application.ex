defmodule PtcRunner.Kernel.EffectiveApplication do
  @moduledoc """
  Exact behavior identity for one fully normalized application declaration.

  The digest is SHA-256 over `"ptc.effective-application.v2\\0"`, the
  big-endian `u64` byte length, and the TJCS projection documented by the
  stable command contract. Selected input values, paths, labels, event IDs,
  raw provider selectors, credentials, and private OAuth authority never enter
  this projection.
  """

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Kernel.TypedCanonicalJSON

  @domain <<"ptc.effective-application.v2", 0>>

  @type normalized_providers :: %{
          required(:workflow) => [map()],
          required(:mission) => [map()]
        }

  @spec build(
          RunRequest.t(),
          FrozenBundle.t(),
          %{binary() => FrozenBundle.t() | nil},
          normalized_providers(),
          :normal | :private
        ) ::
          {:ok, %{projection: map(), digest: binary()}} | {:error, :invalid_effective_application}
  @doc "Builds the literal effective projection and its domain-separated digest."
  def build(
        %RunRequest{} = request,
        workflow_bundle,
        mission_bundles,
        providers,
        effective_event_policy
      ) do
    if RunRequest.valid?(request) do
      build_identity(
        identity(request),
        workflow_bundle,
        mission_bundles,
        providers,
        effective_event_policy
      )
    else
      {:error, :invalid_effective_application}
    end
  end

  def build(_request, _workflow_bundle, _mission_bundles, _providers, _effective_event_policy),
    do: {:error, :invalid_effective_application}

  @doc false
  @spec build_identity(
          map(),
          FrozenBundle.t(),
          %{binary() => FrozenBundle.t() | nil},
          normalized_providers(),
          :normal | :private
        ) ::
          {:ok, %{projection: map(), digest: binary()}} | {:error, :invalid_effective_application}
  def build_identity(
        identity,
        workflow_bundle,
        mission_bundles,
        providers,
        effective_event_policy
      ) do
    with true <- identity_valid?(identity),
         true <- FrozenBundle.valid?(workflow_bundle),
         true <- valid_mission_bundles?(mission_bundles, identity.package.missions),
         true <- valid_providers?(providers),
         true <- effective_event_policy in [:normal, :private],
         projection <-
           projection(
             identity,
             workflow_bundle,
             mission_bundles,
             providers,
             effective_event_policy
           ),
         {:ok, encoded} <- TypedCanonicalJSON.encode(projection) do
      {:ok,
       %{
         projection: projection,
         digest: "sha256:" <> TypedCanonicalJSON.sha256(@domain, encoded)
       }}
    else
      _invalid -> {:error, :invalid_effective_application}
    end
  end

  defp identity(%RunRequest{} = request) do
    %{
      package: request.package,
      input_authority: request.input.authority,
      inspection_capture: request.policy.inspection_capture,
      result_projection: request.policy.result_projection
    }
  end

  defp identity_valid?(identity) when is_map(identity) do
    Enum.sort(Map.keys(identity)) ==
      [:input_authority, :inspection_capture, :package, :result_projection] and
      ApplicationPackage.valid?(identity.package) and
      identity.input_authority in [:normal, :private] and
      is_boolean(identity.inspection_capture) and
      identity.result_projection in [:native, :json]
  end

  defp identity_valid?(_identity), do: false

  defp projection(identity, workflow_bundle, mission_bundles, providers, effective_event_policy) do
    package = identity.package

    %{
      "bundle_hashes" => %{
        "workflow" => workflow_bundle.hash,
        "missions" =>
          Map.new(mission_bundles, fn {name, bundle} -> {name, bundle && bundle.hash} end)
      },
      "components" => %{
        "workflow" => component_projection(workflow_bundle),
        "missions" => mission_projection(package.missions, mission_bundles)
      },
      "contracts" => %{
        "input" => package.contract_behavior_hashes.input,
        "result" => package.contract_behavior_hashes.result
      },
      "effective_event_policy" => Atom.to_string(effective_event_policy),
      "entry" => package.entry,
      "input_authority_class" => Atom.to_string(identity.input_authority),
      "inspection_capture_enabled" => identity.inspection_capture,
      "limits" => LimitCatalog.effective_projection(package.limits),
      "providers" => %{
        "workflow" => providers.workflow,
        "mission" => providers.mission
      },
      "ptc_semantic_revision" => package.ptc_semantic_revision,
      "result_projection" => Atom.to_string(identity.result_projection)
    }
  end

  defp mission_projection(missions, bundles) do
    missions
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new(fn {name, mission} ->
      {name,
       %{
         "components" => bundles |> Map.fetch!(name) |> component_projection(),
         "data" => mission.data,
         "provider_occurrences" => mission.provider_occurrences
       }}
    end)
  end

  defp component_projection(%FrozenBundle{} = bundle) do
    bundle.components
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn component ->
      %{
        "id" => component.id,
        "source_hash" => component.source_hash,
        "dependencies" => component.dependencies
      }
    end)
  end

  defp component_projection(nil), do: []

  defp valid_mission_bundles?(bundles, missions)
       when is_map(bundles) and is_map(missions) and map_size(bundles) == map_size(missions) do
    Enum.sort(Map.keys(bundles)) == Enum.sort(Map.keys(missions)) and
      Enum.all?(bundles, fn {name, bundle} ->
        case bundle do
          nil -> Map.fetch!(missions, name).components == []
          bundle -> FrozenBundle.valid?(bundle)
        end
      end)
  end

  defp valid_mission_bundles?(_bundles, _missions), do: false

  defp valid_providers?(%{workflow: workflow, mission: mission} = providers)
       when map_size(providers) == 2 and is_list(workflow) and is_list(mission),
       do: Enum.all?(workflow ++ mission, &valid_provider_projection?/1)

  defp valid_providers?(_providers), do: false

  defp valid_provider_projection?(provider) when is_map(provider) and not is_struct(provider) do
    Map.keys(provider) |> Enum.sort() ==
      ~w(accepts_data authorization_mode config data_class installation_revision name source)
  end

  defp valid_provider_projection?(_provider), do: false
end
