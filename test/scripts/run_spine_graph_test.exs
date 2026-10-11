defmodule PtcRunner.Scripts.RunSpineGraphTest do
  use ExUnit.Case, async: false
  @moduletag :operator
  @moduletag :nightly

  @root Path.expand("../..", __DIR__)
  @run_spine ~w(execution_session_owner provider_active_session provider_application_gate provider_execution provider_runtime provider_runtime_opening run_admission run_admission_owner run_assembly run_builder run_coordinator run_preparation serving_call serving_plan serving_template warm_provider_runtime)

  test "full compile, export and runtime graph has no run-spine cyclic component" do
    {output, status} =
      System.cmd(System.find_executable("mix"), ["xref", "graph", "--format", "cycles"],
        cd: @root,
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "cycles found", output

    for module <- @run_spine do
      refute output =~ "lib/ptc_runner/kernel/#{module}.ex", output
    end
  end
end
