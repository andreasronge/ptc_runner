defmodule Mix.Tasks.Ptc.MaterializeTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Covers the promotion loop end to end: model-authored source becomes a gated
  candidate, and a later run executes the promoted component.
  """

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ptc
  alias Mix.Tasks.Ptc.Materialize
  alias Mix.Tasks.Ptc.Repair
  alias PtcRunner.Kernel.ComponentOverride

  # The placeholder idiom. It must stub every export its consumers call: a
  # component that declares nothing cannot be depended on, because the base
  # application would not compile and there would be no baseline to compare a
  # candidate against. The stub also fixes the dependency surface the generated
  # component is permitted to consume.
  @placeholder """
  (ns helper "Generated helpers." {:visibility :prompt})

  (defn double
    "Doubles a number."
    {:signature "(n :int) -> :int"}
    [_n]
    0)
  """

  @authored """
  (ns helper "Generated helpers." {:visibility :prompt})

  (defn double
    "Doubles a number."
    {:signature "(n :int) -> :int"}
    [n]
    (* 2 n))
  """

  @tag :tmp_dir
  test "an authored library becomes a candidate a later run executes", %{tmp_dir: dir} do
    manifest = write_application(dir)
    File.write!(Path.join(dir, "authored.clj"), @authored)
    out = Path.join(dir, "candidate")

    output =
      capture_io(fn ->
        Mix.Task.reenable("ptc.materialize")

        Materialize.run([
          manifest,
          "--workflow",
          "--component",
          "helper",
          "--out",
          out,
          "--source",
          Path.join(dir, "authored.clj"),
          "--origin-run-id",
          "run-2026-08-03-0001"
        ])
      end)

    assert output =~ "candidate ready"
    assert output =~ "G1 pass"
    assert File.exists?(Path.join(out, "candidate.clj"))

    descriptor = Path.join(out, "descriptor.json")

    assert %{"provenance" => %{"run_id" => "run-2026-08-03-0001"}} =
             Jason.decode!(File.read!(descriptor))

    # The point of the whole exercise: source the model wrote in one run is
    # compiled, hash-verified, and executed by a later one.
    run_output =
      capture_io(fn ->
        Mix.Task.reenable("ptc")
        Ptc.run(["run", manifest, "--component-override-descriptor", descriptor])
      end)

    # The placeholder's stub returns 0, so 42 is proof the candidate's source
    # compiled and ran rather than the shipped source.
    assert Jason.decode!(run_output) == 42
  end

  @tag :tmp_dir
  test "a mission target is explicit in the published descriptor", %{tmp_dir: dir} do
    manifest = write_mission_application(dir)
    File.write!(Path.join(dir, "authored.clj"), @authored)
    out = Path.join(dir, "mission-candidate")

    capture_io(fn ->
      Mix.Task.reenable("ptc.materialize")

      Materialize.run([
        manifest,
        "--target-mission",
        "writer",
        "--component",
        "helper",
        "--out",
        out,
        "--source",
        Path.join(dir, "authored.clj")
      ])
    end)

    descriptor = out |> Path.join("descriptor.json") |> File.read!() |> Jason.decode!()
    assert descriptor["target"] == %{"environment" => "mission", "mission" => "writer"}
  end

  @tag :tmp_dir
  test "a candidate reaching a new capability is refused and leaves nothing behind", %{
    tmp_dir: dir
  } do
    manifest = write_application(dir)

    File.write!(Path.join(dir, "authored.clj"), """
    (ns helper "Generated helpers." {:visibility :prompt})

    (defn double
      "Doubles a number."
      {:signature "(n :int) -> :int"}
      [n]
      (* 2 n))

    (defn reach
      "Reaches a capability the placeholder never did."
      {:signature "() -> :string" :effect :read}
      []
      (tool/some-thing {}))
    """)

    out = Path.join(dir, "candidate")

    assert_raise Mix.Error, ~r/candidate refused/, fn ->
      capture_io(fn ->
        Mix.Task.reenable("ptc.materialize")

        Materialize.run([
          manifest,
          "--workflow",
          "--component",
          "helper",
          "--out",
          out,
          "--source",
          Path.join(dir, "authored.clj")
        ])
      end)
    end

    refute File.exists?(out)
  end

  @tag :tmp_dir
  test "an acknowledged widening is materialized and recorded", %{tmp_dir: dir} do
    manifest = write_application(dir)

    File.write!(Path.join(dir, "authored.clj"), """
    (ns helper "Generated helpers." {:visibility :prompt})

    (defn double
      "Doubles a number."
      {:signature "(n :int) -> :int"}
      [n]
      (* 2 n))

    (defn reach
      "Reaches a capability the placeholder never did."
      {:signature "() -> :string" :effect :read}
      []
      (tool/some-thing {}))
    """)

    out = Path.join(dir, "candidate")

    output =
      capture_io(fn ->
        Mix.Task.reenable("ptc.materialize")

        Materialize.run([
          manifest,
          "--workflow",
          "--component",
          "helper",
          "--out",
          out,
          "--source",
          Path.join(dir, "authored.clj"),
          "--accept-widened-effect"
        ])
      end)

    assert output =~ "acknowledged by the operator"

    # Acknowledging a widening records the decision rather than hiding it.
    assert %{"provenance" => %{"accept_widened_effect" => true}} =
             Jason.decode!(File.read!(Path.join(out, "descriptor.json")))
  end

  @tag :tmp_dir
  test "a candidate extracted from a result artifact uses one JSON pointer", %{tmp_dir: dir} do
    manifest = write_application(dir)

    File.write!(
      Path.join(dir, "result.json"),
      Jason.encode!(%{"value" => %{"source" => @authored}})
    )

    out = Path.join(dir, "candidate")

    output =
      capture_io(fn ->
        Mix.Task.reenable("ptc.materialize")

        Materialize.run([
          manifest,
          "--workflow",
          "--component",
          "helper",
          "--out",
          out,
          "--from-result",
          Path.join(dir, "result.json"),
          "--result-pointer",
          "/value/source"
        ])
      end)

    assert output =~ "candidate ready"
    assert File.read!(Path.join(out, "candidate.clj")) == @authored
  end

  @tag :tmp_dir
  test "a pointer that does not resolve to a string is refused", %{tmp_dir: dir} do
    manifest = write_application(dir)
    File.write!(Path.join(dir, "result.json"), Jason.encode!(%{"value" => %{"source" => 7}}))

    assert_raise Mix.Error, ~r/result_pointer_not_a_string/, fn ->
      capture_io(fn ->
        Mix.Task.reenable("ptc.materialize")

        Materialize.run([
          manifest,
          "--workflow",
          "--component",
          "helper",
          "--out",
          Path.join(dir, "candidate"),
          "--from-result",
          Path.join(dir, "result.json"),
          "--result-pointer",
          "/value/source"
        ])
      end)
    end
  end

  @tag :tmp_dir
  test "a candidate that drops the workflow entry is refused", %{tmp_dir: dir} do
    manifest = write_application(dir)

    # This compiles cleanly and only *removes* an export, so without an entry
    # check it would pass the gate and leave every later run failing at entry
    # validation instead.
    File.write!(
      Path.join(dir, "authored.clj"),
      ~S|(ns main) (defn go [_i] (return (helper/double 21)))|
    )

    assert_raise Mix.Error, ~r/candidate refused/, fn ->
      capture_io(fn ->
        Mix.Task.reenable("ptc.materialize")

        Materialize.run([
          manifest,
          "--workflow",
          "--component",
          "main",
          "--out",
          Path.join(dir, "candidate"),
          "--source",
          Path.join(dir, "authored.clj")
        ])
      end)
    end

    refute File.exists?(Path.join(dir, "candidate"))
  end

  @tag :tmp_dir
  test "the root pointer and array indices resolve per RFC 6901", %{tmp_dir: dir} do
    manifest = write_application(dir)

    File.write!(Path.join(dir, "root.json"), Jason.encode!(@authored))

    File.write!(
      Path.join(dir, "array.json"),
      Jason.encode!(%{"value" => [%{"src" => @authored}]})
    )

    for {artifact, pointer, out} <- [
          {"root.json", "", "candidate-root"},
          {"array.json", "/value/0/src", "candidate-array"}
        ] do
      capture_io(fn ->
        Mix.Task.reenable("ptc.materialize")

        Materialize.run([
          manifest,
          "--workflow",
          "--component",
          "helper",
          "--out",
          Path.join(dir, out),
          "--from-result",
          Path.join(dir, artifact),
          "--result-pointer",
          pointer
        ])
      end)

      assert File.read!(Path.join([dir, out, "candidate.clj"])) == @authored
    end
  end

  @tag :tmp_dir
  test "an oversized candidate file is refused without loading it whole", %{tmp_dir: dir} do
    manifest = write_application(dir)
    File.write!(Path.join(dir, "authored.clj"), String.duplicate("x", 1_048_577))

    assert_raise Mix.Error, ~r/candidate_source_too_large/, fn ->
      capture_io(fn ->
        Mix.Task.reenable("ptc.materialize")

        Materialize.run([
          manifest,
          "--workflow",
          "--component",
          "helper",
          "--out",
          Path.join(dir, "candidate"),
          "--source",
          Path.join(dir, "authored.clj")
        ])
      end)
    end
  end

  @tag :tmp_dir
  test "a structured repair report passes a host-owned private validation suite", %{
    tmp_dir: dir
  } do
    manifest = write_application(dir)
    report = Path.join(dir, "repair.json")
    suite = Path.join(dir, "suite.json")
    validation_out = Path.join(dir, "validation")
    out = Path.join(dir, "candidate")

    File.write!(report, Jason.encode!(repair_report(ComponentOverride.hash(@placeholder))))
    write_validation_suite(suite, [{"observed", 21, 42}, {"held-out", 5, 10}], "input")

    output =
      capture_io(fn ->
        Mix.Task.reenable("ptc.repair")

        Repair.run([
          manifest,
          "--report",
          report,
          "--out",
          out,
          "--validation-suite",
          suite,
          "--validation-out",
          validation_out,
          "--allow-live-validation",
          "--origin-run-id",
          "debugger-run-1"
        ])
      end)

    assert output =~ "candidate ready"
    assert output =~ "candidate passed 2 host-owned validation cases"
    refute output =~ "42"
    assert File.read!(Path.join(out, "candidate.clj")) == @authored

    assert %{
             "candidate_source_hash" => source_hash,
             "cases" => [
               %{
                 "name" => "observed",
                 "status" => "pass",
                 "artifacts" => %{
                   "inspection" => "01/inspection/run.inspection.jsonl",
                   "traces" => "01/traces"
                 }
               },
               %{"name" => "held-out", "status" => "pass"}
             ],
             "outcome" => "pass"
           } = Jason.decode!(File.read!(Path.join(validation_out, "report.json")))

    assert source_hash == ComponentOverride.hash(@authored)
    assert File.dir?(Path.join(validation_out, "01/traces"))
    assert File.regular?(Path.join(validation_out, "01/inspection/run.inspection.jsonl"))

    assert %{
             "base_source_hash" => base_hash,
             "provenance" => %{"run_id" => "debugger-run-1"}
           } = Jason.decode!(File.read!(Path.join(out, "descriptor.json")))

    assert base_hash == ComponentOverride.hash(@placeholder)
  end

  @tag :tmp_dir
  test "a held-out case rejects a hard-coded candidate that passes the observed input", %{
    tmp_dir: dir
  } do
    manifest = write_application(dir)
    report = Path.join(dir, "repair.json")
    suite = Path.join(dir, "suite.json")
    validation_out = Path.join(dir, "validation")
    out = Path.join(dir, "candidate")

    hard_coded = String.replace(@authored, "(* 2 n)", "42")

    File.write!(
      report,
      Jason.encode!(repair_report(ComponentOverride.hash(@placeholder), hard_coded))
    )

    write_validation_suite(suite, [{"observed", 21, 42}, {"held-out", 5, 10}])

    assert_raise Mix.Error, ~r/1 of 2 host-owned validation cases failed/, fn ->
      capture_io(fn ->
        Mix.Task.reenable("ptc.repair")

        Repair.run([
          manifest,
          "--report",
          report,
          "--out",
          out,
          "--validation-suite",
          suite,
          "--validation-out",
          validation_out,
          "--allow-live-validation"
        ])
      end)
    end

    assert File.exists?(out)

    assert %{
             "cases" => [
               %{"name" => "observed", "status" => "pass"},
               %{"name" => "held-out", "status" => "fail"}
             ],
             "outcome" => "fail"
           } = Jason.decode!(File.read!(Path.join(validation_out, "report.json")))

    assert %{
             "kind" => "repair-validation-feedback",
             "state" => "candidate-rejected",
             "candidate" => %{
               "authority" => "model-authored-untrusted",
               "value" => %{"candidate_source" => ^hard_coded}
             },
             "validation" => %{
               "authority" => "host-authored",
               "outcome" => "fail",
               "cases" => [
                 %{
                   "name" => "observed",
                   "input" => %{"value" => 21},
                   "expected" => 42,
                   "actual" => %{"state" => "available", "value" => 42}
                 },
                 %{
                   "name" => "held-out",
                   "input" => %{"value" => 5},
                   "expected" => 10,
                   "actual" => %{"state" => "available", "value" => 42},
                   "reason" => "result_mismatch"
                 }
               ]
             },
             "version" => 1
           } = Jason.decode!(File.read!(Path.join(validation_out, "feedback.json")))
  end

  @tag :tmp_dir
  test "validation requires an explicit live-effects acknowledgement", %{tmp_dir: dir} do
    manifest = write_application(dir)
    report = Path.join(dir, "repair.json")
    suite = Path.join(dir, "suite.json")

    File.write!(report, Jason.encode!(repair_report(ComponentOverride.hash(@placeholder))))
    write_validation_suite(suite, [{"observed", 21, 42}])

    assert_raise Mix.Error, ~r/allow-live-validation/, fn ->
      capture_io(fn ->
        Mix.Task.reenable("ptc.repair")

        Repair.run([
          manifest,
          "--report",
          report,
          "--out",
          Path.join(dir, "candidate"),
          "--validation-suite",
          suite,
          "--validation-out",
          Path.join(dir, "validation")
        ])
      end)
    end
  end

  # A suite is caller input: a case that is not a map must be refused as an
  # invalid suite, not crash name extraction with an Access error.
  @tag :tmp_dir
  test "a suite entry that is not a map is refused as an invalid suite", %{tmp_dir: dir} do
    manifest = write_application(dir)
    report = Path.join(dir, "repair.json")
    File.write!(report, Jason.encode!(repair_report(ComponentOverride.hash(@placeholder))))

    valid_case = %{"name" => "observed", "input" => %{"value" => 21}, "expected" => 42}

    for bad_cases <- [[1], [nil], ["case"], [[]], [valid_case, 7]] do
      suite = Path.join(dir, "suite.json")
      File.write!(suite, Jason.encode!(%{"version" => 1, "cases" => bad_cases}))

      assert_raise Mix.Error, ~r/invalid_validation_suite/, fn ->
        Mix.Task.reenable("ptc.repair")

        Repair.run([
          manifest,
          "--report",
          report,
          "--out",
          Path.join(dir, "candidate"),
          "--validation-suite",
          suite,
          "--validation-out",
          Path.join(dir, "validation"),
          "--allow-live-validation"
        ])
      end
    end
  end

  @tag :tmp_dir
  test "automatic repair refuses a stale captured base and discards the candidate", %{
    tmp_dir: dir
  } do
    manifest = write_application(dir)
    report = Path.join(dir, "repair.json")
    out = Path.join(dir, "candidate")

    File.write!(report, Jason.encode!(repair_report("sha256:" <> String.duplicate("0", 64))))

    assert_raise Mix.Error, ~r/captured base hash does not match/, fn ->
      capture_io(fn ->
        Mix.Task.reenable("ptc.repair")
        Repair.run([manifest, "--report", report, "--out", out])
      end)
    end

    refute File.exists?(out)
  end

  defp write_application(dir) do
    File.write!(Path.join(dir, "helper.clj"), @placeholder)

    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return (helper/double (get input "value"))))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [
          %{"id" => "helper", "path" => "helper.clj"},
          %{"id" => "main", "path" => "main.clj", "dependencies" => ["helper"]}
        ],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{"value" => 21}},
      "limits" => %{"run_duration_ms" => 30_000}
    }

    path = Path.join(dir, "ptc.json")
    File.write!(path, Jason.encode!(manifest))
    path
  end

  defp write_mission_application(dir) do
    File.write!(Path.join(dir, "helper.clj"), @placeholder)
    File.write!(Path.join(dir, "main.clj"), ~S|(ns main) (defn run [_i] (return 1))|)

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "missions" => %{
        "writer" => %{"components" => [%{"id" => "helper", "path" => "helper.clj"}]}
      },
      "input" => %{"value" => %{}},
      "limits" => %{"run_duration_ms" => 30_000}
    }

    path = Path.join(dir, "mission-ptc.json")
    File.write!(path, Jason.encode!(manifest))
    path
  end

  defp repair_report(base_source_hash, source \\ @authored) do
    %{
      "decision" => "propose-change",
      "run_id" => "debugger-run-1",
      "target_environment" => "workflow",
      "target_mission" => "default",
      "component_id" => "helper",
      "base_source_hash" => base_source_hash,
      "candidate_source" => source
    }
  end

  defp write_validation_suite(path, cases, input_key \\ "private_input") do
    encoded_cases =
      Enum.map(cases, fn {name, input, expected} ->
        %{"name" => name, input_key => %{"value" => input}, "expected" => expected}
      end)

    File.write!(path, Jason.encode!(%{"version" => 1, "cases" => encoded_cases}))
  end
end
