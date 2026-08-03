defmodule Mix.Tasks.Ptc.MaterializeTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Covers the promotion loop end to end: model-authored source becomes a gated
  candidate, and a later run executes the promoted component.
  """

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ptc.Materialize
  alias Mix.Tasks.Ptc.Run

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
        Mix.Task.reenable("ptc.run")
        Run.run([manifest, "--component-override-descriptor", descriptor])
      end)

    # The placeholder's stub returns 0, so 42 is proof the candidate's source
    # compiled and ran rather than the shipped source.
    assert %{"value" => 42} = Jason.decode!(run_output)
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

  defp write_application(dir) do
    File.write!(Path.join(dir, "helper.clj"), @placeholder)

    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [_i] (return (helper/double 21)))|
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
      "input" => %{"value" => %{}},
      "limits" => %{"run_duration_ms" => 30_000}
    }

    path = Path.join(dir, "ptc.json")
    File.write!(path, Jason.encode!(manifest))
    path
  end
end
