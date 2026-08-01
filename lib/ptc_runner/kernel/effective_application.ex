defmodule PtcRunner.Kernel.EffectiveApplication do
  @moduledoc """
  Exact behavior identity for one fully normalized application declaration.

  The digest is SHA-256 over `"ptc.effective-application.v1\\0"`, the
  big-endian `u64` byte length, and the TJCS projection documented by the
  stable command contract. Selected input values, paths, labels, event IDs,
  raw provider selectors, credentials, and private OAuth authority never enter
  this projection.
  """

  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Kernel.TypedCanonicalJSON

  @domain <<"ptc.effective-application.v1", 0>>

  @type normalized_providers :: %{
          required(:workflow) => [map()],
          required(:mission) => [map()]
        }

  @spec build(
          RunRequest.t(),
          FrozenBundle.t(),
          FrozenBundle.t() | nil,
          normalized_providers(),
          :normal | :private
        ) ::
          {:ok, %{projection: map(), digest: binary()}} | {:error, :invalid_effective_application}
  @doc "Builds the literal effective projection and its domain-separated digest."
  def build(request, workflow_bundle, mission_bundle, providers, effective_event_policy) do
    with true <- RunRequest.valid?(request),
         true <- FrozenBundle.valid?(workflow_bundle),
         true <- is_nil(mission_bundle) or FrozenBundle.valid?(mission_bundle),
         true <- valid_providers?(providers),
         true <- effective_event_policy in [:normal, :private],
         projection <-
           projection(
             request,
             workflow_bundle,
             mission_bundle,
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

  defp projection(request, workflow_bundle, mission_bundle, providers, effective_event_policy) do
    package = request.package

    %{
      "bundle_hashes" => %{
        "workflow" => workflow_bundle.hash,
        "mission" => if(mission_bundle, do: mission_bundle.hash, else: nil)
      },
      "components" => %{
        "workflow" => component_projection(workflow_bundle),
        "mission" => component_projection(mission_bundle)
      },
      "contracts" => %{
        "input" => package.contract_behavior_hashes.input,
        "result" => package.contract_behavior_hashes.result
      },
      "effective_event_policy" => Atom.to_string(effective_event_policy),
      "entry" => package.entry,
      "input_authority_class" => Atom.to_string(request.input.authority),
      "inspection_capture_enabled" => request.policy.inspection_capture,
      "limits" => LimitCatalog.effective_projection(package.limits),
      "mission_data" => package.mission_data,
      "providers" => %{
        "workflow" => providers.workflow,
        "mission" => providers.mission
      },
      "ptc_semantic_revision" => package.ptc_semantic_revision,
      "result_projection" => Atom.to_string(request.policy.result_projection)
    }
  end

  defp component_projection(nil), do: []

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
