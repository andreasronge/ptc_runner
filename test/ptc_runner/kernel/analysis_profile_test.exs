defmodule PtcRunner.Kernel.AnalysisProfileTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.AnalysisProfile
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.InspectionAnalysisProfile
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LogAnalysisProfile
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.TestSupport.ReorderedAnalysisProfileRecipe

  test "fixed profile declarations match their resolved contracts" do
    for recipe <- [LogAnalysisProfile, InspectionAnalysisProfile] do
      {:ok, components} = Library.resolve_components(recipe.component_selections())
      {:ok, bundle} = PtcRunner.Kernel.compile_bundle(components)
      capabilities = Enum.map(recipe.explicit_capabilities(), &%{name: &1})

      assert :ok = AnalysisProfile.validate_contract(recipe, bundle, capabilities)
    end
  end

  test "recipe declaration order does not affect the compiled profile identity" do
    {:ok, base} = Component.new(id: "base", source: "(ns base) (defn value [] 1)")

    {:ok, consumer} =
      Component.new(
        id: "consumer",
        source: "(ns consumer) (defn value [] (base/value))",
        dependencies: ["base"]
      )

    {:ok, bundle} = PtcRunner.Kernel.compile_bundle([consumer, base])
    {:ok, mission} = MissionEnvironment.new(bundle: bundle)
    {:ok, limits} = Limits.new()

    assert {:ok, profile} =
             AnalysisProfile.descriptor(
               ReorderedAnalysisProfileRecipe,
               bundle,
               mission,
               limits
             )

    assert profile.identity["components"] == bundle.component_ids
    assert profile.namespaces == ["base", "consumer"]

    assert :ok =
             AnalysisProfile.validate_contract(ReorderedAnalysisProfileRecipe, bundle, [])

    assert {:error, :profile_component_set_mismatch} =
             AnalysisProfile.validate_contract(
               ReorderedAnalysisProfileRecipe,
               %{bundle | component_ids: ["base"]},
               []
             )

    assert {:error, :profile_namespace_set_mismatch} =
             AnalysisProfile.validate_contract(
               ReorderedAnalysisProfileRecipe,
               %{bundle | components: []},
               []
             )

    assert {:error, :profile_capability_set_mismatch} =
             AnalysisProfile.validate_contract(
               ReorderedAnalysisProfileRecipe,
               bundle,
               [%{name: "unexpected"}]
             )
  end
end
