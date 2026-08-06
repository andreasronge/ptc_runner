defmodule PtcRunner.Kernel.DoctorEnvironmentTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.DoctorEnvironment
  alias PtcRunner.Kernel.DoctorPlan
  alias PtcRunner.Kernel.InstallationCatalog

  test "the reported runtime requirement is the one the project declares" do
    # Runtime code keeps the requirement as a constant so it needs no Mix at
    # run time. This is the check that keeps that constant honest.
    assert DoctorEnvironment.elixir_requirement() == Mix.Project.config()[:elixir]
  end

  test "both facts are values the plan accepts" do
    facts = DoctorEnvironment.facts()

    assert facts.runtime in [:supported, :unsupported]
    assert facts.viewer in [:available, :unavailable]

    {:ok, catalog} = InstallationCatalog.new()
    assert {:ok, rows} = DoctorPlan.new(catalog, nil, facts)
    assert {:ok, _checks} = DoctorPlan.checks(rows)
  end

  test "a runtime meeting its requirement reports supported" do
    # The suite runs on a supported toolchain, so an unsupported reading here
    # means the constant drifted rather than that the runtime is genuinely old.
    assert Version.match?(System.version(), DoctorEnvironment.elixir_requirement())
    assert DoctorEnvironment.facts().runtime == :supported
  end
end
