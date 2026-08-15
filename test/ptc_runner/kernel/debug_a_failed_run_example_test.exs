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
    # `pricing.tax` branches, so a walk that followed only its first edge
    # would silently drop one of these.
    assert Enum.sort(evidence["dependency_closure"]) ==
             ["orders", "pricing.base", "pricing.rule", "pricing.tax"]

    assert evidence["closure_complete"] == true
    assert evidence["terminal_reason"] == "explicit_failure"
    assert evidence["boundary_kind"] == "workflow_failed"
    assert evidence["nested_evaluations"] == 2

    # The generated program carries both values the check ran on, and the
    # reached rule carries the defect. Without the literal order in the capture
    # a wrong input would be indistinguishable from a wrong component, so this
    # is exactly what makes the example's diagnosis supported.
    assert evidence["generated_source"] =~ ~s|(orders/place {"subtotal" 100})|
    assert evidence["generated_source"] =~ ~s|(get quote "total") 120|
    assert Enum.any?(evidence["reached_sources"], &(&1 =~ "(+ subtotal 2)"))
    refute Enum.any?(evidence["reached_sources"], &(&1 =~ "pricing.discount"))

    # A run that fails by calling `fail` proves no direct boundary producer, so
    # the report keeps that honest `incomplete` rather than hiding it.
    assert evidence["evidence_states"] == ["complete", "incomplete", "unavailable"]
    assert evidence["diagnosis"] == nil
  end

  # The walk's component bound has to cover the roots too, not only later
  # rounds. Reproducing that with a real >64-component closure would cost far
  # more than it proves, so drive the same code path by zeroing the bound in a
  # throwaway copy: every root is then withheld. Before the bound covered root
  # seeding, the roots were followed regardless and the closure came back
  # non-empty and complete.
  @tag :tmp_dir
  test "a withheld root leaves the closure empty and explicitly incomplete", %{
    tmp_dir: directory
  } do
    example = Path.join(directory, "debug-a-failed-run")
    File.cp_r!(@example, example)
    File.rm_rf!(Path.join(example, "target/.ptc"))
    File.rm_rf!(Path.join(example, "debugger/.ptc"))

    walk = Path.join(example, "debugger/evidence.walk.clj")
    source = File.read!(walk)
    assert String.contains?(source, "(- 64 (count seen))")
    File.write!(walk, String.replace(source, "(- 64 (count seen))", "(- 0 (count seen))"))

    assert {_output, 5} = run(Path.join(example, "target.ptc-project.json"))
    assert {_output, 0} = run(Path.join(example, "debugger.ptc-project.json"))

    evidence = private_result!(Path.join(example, "debugger/.ptc/results"))

    assert evidence["dependency_closure"] == []
    assert evidence["closure_complete"] == false
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
