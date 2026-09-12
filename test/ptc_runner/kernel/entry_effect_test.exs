defmodule PtcRunner.Kernel.EntryEffectTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.EntryEffect
  alias PtcRunner.Kernel.Environment
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.WorkflowEnvironment

  test "every selectable capability contributes, including hidden and unused grants" do
    {:ok, component} =
      Component.new(id: "app", source: "(ns app) (defn run {:effect :read} [x] x)")

    {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    [entry] = bundle.prelude.exports

    for effect <- [:read, :write, :unknown] do
      {:ok, capability} =
        Capability.new(
          name: "unused",
          effect: effect,
          model_visible: false,
          input_schema: %{"type" => "object"},
          callback: fn _ ->
            flunk("resolution must not dispatch")
          end
        )

      {:ok, mission} = MissionEnvironment.new(capabilities: [capability])

      result =
        EntryEffect.resolve(%{workflow: workflow, missions: %{"selectable" => mission}}, entry)

      assert result.effect == effect
      assert {"kernel-eval", effect} in result.contributors
      assert {"mission/selectable/capability/unused", effect} in result.contributors
    end
  end

  test "unknown dominates write across missions and missing export grants stay unknown" do
    {:ok, component} =
      Component.new(id: "app", source: "(ns app) (defn run {:effect :read} [x] x)")

    {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    [entry] = bundle.prelude.exports

    {:ok, write_component} =
      Component.new(id: "writer", source: "(ns writer) (defn write {:effect :write} [x] x)")

    {:ok, write_bundle} = Kernel.compile_bundle([write_component])
    {:ok, writer} = MissionEnvironment.new(bundle: write_bundle)

    {:ok, unknown_component} =
      Component.new(
        id: "unproven",
        source: "(ns unproven) (defn run {:effect :write} [x] (tool/missing {}))"
      )

    {:ok, unknown_bundle} = Kernel.compile_bundle([unknown_component])
    # The resolver also supports diagnostic maps with missing effects/grants.
    missing = %{bundle: unknown_bundle, capabilities: %{}}

    result =
      EntryEffect.resolve(
        %{workflow: workflow, missions: %{"writer" => writer, "unproven" => missing}},
        entry
      )

    # ExportEffect conservatively reports write for a declared-write export;
    # an undeclared capability independently makes the complete grant unknown.
    assert result.effect == :write
    missing = %{missing | capabilities: %{"undeclared" => %{}}}

    result =
      EntryEffect.resolve(
        %{workflow: workflow, missions: %{"writer" => writer, "unproven" => missing}},
        entry
      )

    assert result.effect == :unknown
    assert {"mission/unproven/capability/undeclared", :unknown} in result.contributors
  end

  test "every reserved workflow and private diagnostic route has its maintained classification" do
    {:ok, kernel} = Library.component("kernel")
    {:ok, bundle} = Kernel.compile_bundle([kernel])

    private =
      ~w(kernel-agent-config-failure kernel-agent-outcome-failure kernel-agent-protocol-error kernel-llm-provider-failure kernel-phase-return-contract-failure kernel-result-contract-failure kernel-runtime-limit-failure)

    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    # Grant fixed private routes in a diagnostic map to test their composition.
    workflow = %{workflow | private_capabilities: private}

    entry =
      Enum.find(bundle.prelude.exports, &(&1.ref == "kernel/usage")) || hd(bundle.prelude.exports)

    result = EntryEffect.resolve(%{workflow: workflow, missions: %{}}, entry)

    for route <- Environment.implicit_capabilities(:workflow, private) do
      assert result.capability_effects[route] == :read
      assert {route, :read} in result.contributors
    end
  end
end
