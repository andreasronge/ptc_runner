defmodule PtcRunner.Kernel.EntryEffect do
  @moduledoc """
  Resolves the conservative complete grant of an assembled workflow entry.

  `resolve/2` takes `%{workflow: workflow_environment, missions: mission_environments}`
  and the compiled entry export. It returns `%{effect: effect, contributors: contributors}`,
  plus `capability_effects` for assembly validation. Contributors are sorted
  `{route_or_grant, effect}` pairs for internal diagnostics.
  These names must not cross the closed serving construction-error boundary.

  Every implicit workflow route participates, even when the entry does not
  statically reference it. `kernel-eval` joins every export and capability of
  every selectable mission; there is no reachability narrowing. The other
  reserved runtime and private diagnostic routes are read effects: their
  inspection and annotation affect only the run. An empty mission grant is
  read. Unknown dominates write, which dominates read. Export resolution
  reuses the shared export resolver and `PtcRunner.Kernel.MissionInventory`.
  """

  alias PtcRunner.Kernel.Environment
  alias PtcRunner.Kernel.ExportEffect
  alias PtcRunner.Kernel.MissionInventory

  @type effect :: :read | :write | :unknown
  @spec resolve(map(), PtcRunner.Lisp.Prelude.Export.t()) ::
          %{effect: effect(), contributors: [{binary(), effect()}], capability_effects: map()}
  @doc "Resolves an entry after the complete workflow and mission grant is assembled."
  def resolve(%{workflow: workflow, missions: missions}, entry) do
    grants = mission_grants(missions)

    routes = capability_effects(workflow, grants)
    own = ExportEffect.resolve(entry, routes)

    implicit_routes =
      Map.take(
        routes,
        Environment.implicit_capabilities(:workflow, workflow.private_capabilities)
      )

    contributors =
      Enum.sort([{"entry/" <> entry.ref, own} | Map.to_list(implicit_routes) ++ grants])

    %{
      effect: join(Enum.map(contributors, &elem(&1, 1))),
      contributors: contributors,
      capability_effects: routes
    }
  end

  defp capability_effects(workflow, grants) do
    routes =
      Map.new(Environment.implicit_capabilities(:workflow, workflow.private_capabilities), fn
        "kernel-eval" -> {"kernel-eval", join(Enum.map(grants, &elem(&1, 1)))}
        name -> {name, :read}
      end)

    capabilities =
      Map.new(workflow.capabilities, fn {name, cap} ->
        {name, Map.get(cap, :effect, :unknown)}
      end)

    Map.merge(capabilities, routes)
  end

  defp mission_grants(missions) do
    Enum.flat_map(missions, fn {name, mission} ->
      exports =
        case mission.bundle do
          nil ->
            []

          bundle ->
            Enum.map(bundle.prelude.exports, fn export ->
              {"mission/" <> name <> "/export/" <> export.ref,
               MissionInventory.resolved_export_effect(export, mission)}
            end)
        end

      capabilities =
        Enum.map(mission.capabilities, fn {cap_name, cap} ->
          {"mission/" <> name <> "/capability/" <> cap_name, Map.get(cap, :effect, :unknown)}
        end)

      exports ++ capabilities
    end)
  end

  defp join(effects) do
    cond do
      :unknown in effects -> :unknown
      :write in effects -> :write
      true -> :read
    end
  end
end
