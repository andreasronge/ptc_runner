defmodule PtcRunner.Kernel.DebugAFailedRunExampleTest do
  use ExUnit.Case, async: true

  @moduletag :slow
  @moduletag timeout: 180_000

  @root Path.expand("../../..", __DIR__)
  @example Path.join(@root, "examples/debug-a-failed-run")

  # The example tests are the only place the whole path is exercised the way an
  # operator meets it: a real `mix ptc run` capturing a private trace and
  # inspection pair, and a second real run installing that capture as a
  # snapshot provider. An in-process Kernel run would prove neither the
  # provider alias binding nor the JSON projection the CLI forces.
  @tag :tmp_dir
  test "one PTC run walks another run's captured failure to its dependency source", %{
    tmp_dir: directory
  } do
    example = Path.join(directory, "debug-a-failed-run")
    File.cp_r!(@example, example)
    File.rm_rf!(Path.join(example, "target/.ptc"))
    File.rm_rf!(Path.join(example, "debugger/.ptc"))

    assert {target_output, 5} = run(Path.join(example, "target.ptc-project.json"))
    assert target_output =~ "execution/workflow_failed"

    assert {debugger_output, 0} = run(Path.join(example, "debugger.ptc-project.json"))
    assert Jason.decode!(debugger_output) == %{"artifact_class" => "private", "status" => "ok"}

    evidence = private_result!(Path.join(example, "debugger/.ptc/results"))

    # The walk follows frozen dependency edges, so it reaches exactly the
    # closure the failing call used and never the unused decoy component.
    assert evidence["dependency_closure"] == ["orders", "pricing.tax", "pricing.rule"]
    assert evidence["terminal_reason"] == "explicit_failure"
    assert evidence["boundary_kind"] == "workflow_failed"
    assert evidence["nested_evaluations"] == 2

    # The generated program carries the requirement, and the reached rule
    # carries the defect. Together they are what makes a diagnosis supportable.
    assert evidence["generated_source"] =~ ~s|(get quote "total") 120|
    assert List.last(evidence["reached_sources"]) =~ "(+ subtotal 2)"
    refute Enum.any?(evidence["reached_sources"], &(&1 =~ "pricing.discount"))

    # A run that fails by calling `fail` proves no direct boundary producer, so
    # the report keeps that honest `incomplete` rather than hiding it.
    assert evidence["evidence_states"] == ["complete", "incomplete", "unavailable"]
    assert evidence["diagnosis"] == nil
  end

  defp run(project) do
    System.cmd(
      System.find_executable("mix"),
      ["ptc", "run", project],
      cd: @root,
      env: [{"MIX_ENV", "test"}, {"MIX_QUIET", "1"}],
      stderr_to_stdout: true
    )
  end

  defp private_result!(directory) do
    [path] = Path.wildcard(Path.join(directory, "*.private.json"))
    path |> File.read!() |> Jason.decode!()
  end
end
