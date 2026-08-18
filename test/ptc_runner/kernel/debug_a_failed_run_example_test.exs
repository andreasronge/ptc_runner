defmodule PtcRunner.Kernel.DebugAFailedRunExampleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ptc.Repair
  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Kernel.WorkflowEnvironment

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

  # Configuration keys nothing reads are silent lies: the terminal-action
  # guidance must ride a key the phased loop actually delivers.
  test "the repair agent's terminal guidance lives on the phase, not a dead key" do
    agent =
      @example
      |> Path.join("repair-agent/ptc.json")
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["input", "value", "agent"])

    refute Map.has_key?(agent, "result_instruction")

    assert [%{"mission" => "synthesize", "instruction" => instruction}] = agent["phases"]
    assert instruction =~ "repair.terminal"
  end

  # The repair leg is deterministic once a report exists: materialization,
  # G1-G4, the host-owned suite, and the promoted rerun make no model call.
  # Fabricating the report keeps this test offline while proving exactly the
  # artifacts and commands the example's live repair agent hands to a human.
  @tag :tmp_dir
  test "a proposed repair is validated by the host suite and promotes to a passing run", %{
    tmp_dir: directory
  } do
    example = Path.join(directory, "debug-a-failed-run")
    File.cp_r!(@example, example)

    for artifact <- ~w(target/.ptc debugger/.ptc repair-agent/.ptc target-ambiguous/.ptc) do
      File.rm_rf!(Path.join(example, artifact))
    end

    base = File.read!(Path.join(example, "target/pricing.rule.clj"))
    candidate = String.replace(base, "(+ subtotal 2)", "(+ subtotal 20)")
    assert candidate != base

    report_path = Path.join(directory, "repair.json")
    out = Path.join(directory, "candidate")
    trial = Path.join(directory, "trial")

    File.write!(
      report_path,
      Jason.encode!(%{
        "decision" => "propose-change",
        "run_id" => "example-incident",
        "cause" => "pricing.rule adds 2 where its contract states the flat charge is 20",
        "target_environment" => "mission",
        "target_mission" => "pricing",
        "component_id" => "pricing.rule",
        "function_id" => "pricing.rule/apply-standard",
        "base_source_hash" => ComponentOverride.hash(base),
        "candidate_source" => candidate,
        "evidence" => ["the docstring and the observed total 102 both contradict (+ subtotal 2)"]
      })
    )

    output =
      capture_io(fn ->
        Repair.run([
          Path.join(example, "target/ptc.json"),
          "--report",
          report_path,
          "--out",
          out,
          "--validation-suite",
          Path.join(example, "repair-agent/suite.json"),
          "--validation-out",
          trial,
          "--allow-live-validation"
        ])
      end)

    assert output =~ "candidate passed 3 host-owned validation cases"

    trial_report = Jason.decode!(File.read!(Path.join(trial, "report.json")))
    assert trial_report["outcome"] == "pass"

    assert Enum.map(trial_report["cases"], & &1["name"]) ==
             ["observed-order", "held-out-small", "held-out-zero"]

    # Promotion stays a separate, explicit decision: the same target that
    # failed runs green under the validated override without any file edited.
    assert {_output, 0} =
             run(Path.join(example, "target.ptc-project.json"), [
               "--component-override-descriptor",
               Path.join(out, "descriptor.json")
             ])

    assert private_result!(Path.join(example, "target/.ptc/results")) == %{"total" => 120}

    # An abstention is a complete result for the agent, and a refused input
    # here: nothing is materialized from insufficient evidence.
    File.write!(
      report_path,
      Jason.encode!(%{
        "decision" => "insufficient-evidence",
        "run_id" => "example-incident",
        "cause" => "the evidence does not distinguish one faulty implementation",
        "evidence" => ["two constant components could each absorb the difference"],
        "missing_evidence" => ["a second observed case"]
      })
    )

    assert_raise Mix.Error, ~r/repair_not_proposed/, fn ->
      Repair.run([
        Path.join(example, "target/ptc.json"),
        "--report",
        report_path,
        "--out",
        Path.join(directory, "candidate-refused")
      ])
    end

    refute File.exists?(Path.join(directory, "candidate-refused"))
  end

  test "the repair report contract permits a workflow target without a mission" do
    schema =
      @example
      |> Path.join("repair-agent/report.schema.json")
      |> File.read!()
      |> Jason.decode!()

    assert {:ok, contract} = ValueContract.compile(schema)

    report = %{
      "decision" => "propose-change",
      "run_id" => "run-1",
      "cause" => "the workflow routed the wrong value",
      "target_environment" => "workflow",
      "target_mission" => nil,
      "component_id" => "main",
      "function_id" => "main/run",
      "base_source_hash" => "sha256:" <> String.duplicate("a", 64),
      "candidate_source" => "(ns main)",
      "evidence" => ["the two captured values differ"]
    }

    # nil is not an accepted spelling of "no mission": the field is either a
    # nonblank mission name or absent. The mission-target requirement itself
    # is enforced by the terminal action (which normalizes a missing mission
    # to "" so this minLength rule rejects it) and by mix ptc.repair.
    refute ValueContract.valid?(contract, report)
    assert ValueContract.valid?(contract, Map.delete(report, "target_mission"))

    mission_report =
      Map.merge(report, %{
        "target_environment" => "mission",
        "target_mission" => "pricing"
      })

    assert ValueContract.valid?(contract, mission_report)
    refute ValueContract.valid?(contract, Map.put(mission_report, "target_mission", ""))
    refute ValueContract.valid?(contract, Map.put(mission_report, "target_mission", nil))

    refute ValueContract.valid?(
             contract,
             Map.delete(Map.put(report, "target_environment", "component"), "target_mission")
           )
  end

  test "the terminal propose action enforces the target rule the schema cannot express" do
    {:ok, kernel_component} = Library.component("kernel")
    {:ok, workflow_bundle} = Kernel.compile_bundle([kernel_component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: workflow_bundle)

    {:ok, terminal_component} =
      Component.new(
        id: "repair.terminal",
        source: File.read!(Path.join(@example, "repair-agent/repair.terminal.clj")),
        origin: "example"
      )

    {:ok, terminal_bundle} = Kernel.compile_bundle([terminal_component])
    {:ok, synthesize} = MissionEnvironment.new(bundle: terminal_bundle)
    {:ok, limits} = Limits.new(subordinate_evaluations: 8)

    propose = fn report ->
      {:ok, sink} = EventSink.start(:normal, limits, run_id: "repair-terminal-example")

      {:ok, config} =
        RunConfig.new(
          workflow_environment: workflow,
          missions: %{"default" => synthesize, "synthesize" => synthesize},
          input: %{"input" => report},
          limits: limits,
          event_sink: sink
        )

      Kernel.run(
        ~S|(return (kernel/eval-source-with "synthesize" "(repair.terminal/propose data/params)" data/input))|,
        config
      )
    end

    base = %{
      "run_id" => "run-1",
      "cause" => "routing",
      "component_id" => "main",
      "function_id" => "main/run",
      "base_source_hash" => "sha256:" <> String.duplicate("a", 64),
      "candidate_source" => "(ns main)",
      "evidence" => ["captured values differ"]
    }

    # A workflow proposal is accepted, and a redundant mission name is
    # dropped rather than burning a correction turn.
    assert {:ok, %{value: evaluation}} =
             propose.(
               Map.merge(base, %{"target_environment" => "workflow", "target_mission" => "x"})
             )

    assert evaluation["outcome"] == "returned"
    assert evaluation["value"]["decision"] == "propose-change"
    refute Map.has_key?(evaluation["value"], "target_mission")

    # A mission proposal keeps its mandatory nonblank mission.
    assert {:ok, %{value: mission_evaluation}} =
             propose.(
               Map.merge(base, %{"target_environment" => "mission", "target_mission" => "pricing"})
             )

    assert mission_evaluation["outcome"] == "returned"
    assert mission_evaluation["value"]["target_mission"] == "pricing"

    # A malformed target returns and is left to the result contract, which
    # rejects it with correction feedback: a mistake costs the model one
    # turn, never the whole run. A mission target with no usable mission is
    # normalized to "" so the contract's minLength rule names the field.
    assert {:ok, %{value: malformed}} = propose.(Map.put(base, "target_environment", "mission"))
    assert malformed["outcome"] == "returned"
    assert malformed["value"]["target_mission"] == ""

    assert {:ok, %{value: refused}} = propose.(42)
    refute refused["outcome"] == "returned"
  end

  @tag :tmp_dir
  test "the same repair path replaces faulty workflow routing while preserving correct missions",
       %{tmp_dir: directory} do
    example = Path.join(directory, "debug-a-failed-run")
    File.cp_r!(@example, example)

    for artifact <- ~w(target-workflow-control/.ptc repair-agent-workflow-control/.ptc) do
      File.rm_rf!(Path.join(example, artifact))
    end

    target = Path.join(example, "target-workflow-control.ptc-project.json")
    assert {target_output, 5} = run(target)
    assert target_output =~ "execution/workflow_failed"

    base = File.read!(Path.join(example, "target-workflow-control/main.clj"))

    candidate =
      String.replace(
        base,
        ~S|"reservation_id" (get input "order_id")|,
        ~S|"reservation_id" (get reservation "reservation_id")|
      )

    assert candidate != base

    report_path = Path.join(directory, "workflow-repair.json")
    out = Path.join(directory, "workflow-candidate")
    trial = Path.join(directory, "workflow-trial")

    # A workflow target has no mission, so the report omits target_mission
    # entirely - exactly the shape the terminal action publishes.
    File.write!(
      report_path,
      Jason.encode!(%{
        "decision" => "propose-change",
        "run_id" => "workflow-control-incident",
        "cause" =>
          "main passes the incoming order id to shipping instead of the reservation id returned by inventory",
        "target_environment" => "workflow",
        "component_id" => "main",
        "function_id" => "main/run",
        "base_source_hash" => ComponentOverride.hash(base),
        "candidate_source" => candidate,
        "evidence" => [
          "inventory returned reservation:order-17, while the shipping program received order-17"
        ]
      })
    )

    output =
      capture_io(fn ->
        Repair.run([
          Path.join(example, "target-workflow-control/ptc.json"),
          "--report",
          report_path,
          "--out",
          out,
          "--validation-suite",
          Path.join(example, "repair-agent/workflow-control-suite.json"),
          "--validation-out",
          trial,
          "--allow-live-validation"
        ])
      end)

    assert output =~ "candidate passed 3 host-owned validation cases"

    trial_report = Jason.decode!(File.read!(Path.join(trial, "report.json")))
    assert trial_report["outcome"] == "pass"

    assert Enum.map(trial_report["cases"], & &1["name"]) ==
             ["observed-order", "held-out-order", "held-out-identifiers"]

    assert {_output, 0} =
             run(target, [
               "--component-override-descriptor",
               Path.join(out, "descriptor.json")
             ])

    assert private_result!(Path.join(example, "target-workflow-control/.ptc/results")) == %{
             "destination" => "north-depot",
             "reservation_id" => "reservation:order-17",
             "status" => "scheduled"
           }
  end

  # The packet builder is deterministic once a capture exists, so its honesty
  # contract is testable without a model: the workflow-control incident holds
  # two directly generated sources, and narrowing the direct page to one must
  # flip generated_sources_truncated rather than silently dropping a source.
  @tag :tmp_dir
  test "the incident packet reports direct generated-source truncation honestly", %{
    tmp_dir: directory
  } do
    example = Path.join(directory, "debug-a-failed-run")
    File.cp_r!(@example, example)

    for artifact <- ~w(target-workflow-control/.ptc repair-agent/.ptc) do
      File.rm_rf!(Path.join(example, artifact))
    end

    assert {_output, 5} = run(Path.join(example, "target-workflow-control.ptc-project.json"))

    File.write!(Path.join(example, "repair-agent/probe.clj"), """
    (ns probe "Deterministic packet acquisition entry." {:visibility :prompt})

    (defn run
      "Build the incident packet for the most recent failed capture."
      {:signature "(input :map) -> :map"}
      [_input]
      (let [evaluation
            (kernel/eval-with
              "case-derived"
              (program
                (return (debug.case/context (get data/params "run_id"))))
              {"run_id" nil})]
        (if (= :returned (get evaluation :outcome))
          (return (get evaluation :value))
          (fail (get evaluation :value)))))
    """)

    agent_manifest =
      example |> Path.join("repair-agent/ptc.json") |> File.read!() |> Jason.decode!()

    File.write!(
      Path.join(example, "repair-agent/probe-ptc.json"),
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [
            %{"id" => "probe", "path" => "probe.clj", "dependencies" => ["kernel"]},
            %{"library" => "kernel"}
          ],
          "entry" => "probe/run"
        },
        "missions" => Map.take(agent_manifest["missions"], ["case-derived"]),
        "providers" => %{"mission" => agent_manifest["providers"]["mission"]},
        "input" => %{"value" => %{}},
        "events" => %{"policy" => "private"},
        "labels" => %{"name" => "packet-probe", "tags" => %{"mode" => "deterministic"}}
      })
    )

    probe_project = Path.join(example, "probe.ptc-project.json")

    File.write!(
      probe_project,
      Jason.encode!(%{
        "kind" => "ptc-project",
        "version" => 1,
        "application" => %{"path" => "repair-agent/probe-ptc.json"},
        "host" => %{"path" => "ptc-host-workflow-control.json"},
        "artifacts" => %{
          "root" => "repair-agent/.ptc",
          "trace" => true,
          "inspection" => true,
          "result" => true,
          "envelope" => true
        }
      })
    )

    assert {_output, 0} = run(probe_project)
    packet = private_result!(Path.join(example, "repair-agent/.ptc/results"))

    assert length(packet["generated_sources"]) == 2
    assert packet["completeness"]["generated_sources_truncated"] == false
    assert packet["completeness"]["workflow_sources_complete"] == true

    assert Enum.any?(packet["workflow_sources"], fn source ->
             source["component_id"] == "main" and source["source"] =~ "shipment-source"
           end)

    # Narrow only the direct page; a dropped source must surface as
    # truncation, never as a quietly smaller packet.
    case_path = Path.join(example, "repair-agent/case.clj")
    source = File.read!(case_path)

    direct_page = ~s|"parent_evaluation_id" workflow-evaluation-id\n               "limit" 20})|
    assert String.contains?(source, direct_page)

    File.write!(
      case_path,
      String.replace(
        source,
        direct_page,
        ~s|"parent_evaluation_id" workflow-evaluation-id\n               "limit" 1})|
      )
    )

    File.rm_rf!(Path.join(example, "repair-agent/.ptc"))
    assert {_output, 0} = run(probe_project)
    narrowed = private_result!(Path.join(example, "repair-agent/.ptc/results"))

    assert length(narrowed["generated_sources"]) == 1
    assert narrowed["completeness"]["generated_sources_truncated"] == true
  end

  defp run(project, extra_args \\ []) do
    System.cmd(
      System.find_executable("mix"),
      ["ptc", "run", project] ++ extra_args,
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
