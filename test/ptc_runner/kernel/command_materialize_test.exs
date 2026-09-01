defmodule PtcRunner.Kernel.CommandMaterializeTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandEntry
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandParser

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

  test "source-out conflicts with candidate options at parse time" do
    assert {:error, rejection} =
             CommandParser.parse([
               "materialize",
               "ptc.json",
               "--workflow",
               "--component",
               "helper",
               "--source-out",
               "out.clj",
               "--source",
               "authored.clj"
             ])

    assert rejection.command == :materialize
    assert rejection.code == :conflicting_arguments
  end

  test "source-out rejects candidate-only provenance switches" do
    assert {:error, rejection} =
             CommandParser.parse([
               "materialize",
               "ptc.json",
               "--workflow",
               "--component",
               "helper",
               "--source-out",
               "out.clj",
               "--origin-run-id",
               "run-1"
             ])

    assert rejection.command == :materialize
    assert rejection.code == :conflicting_arguments
  end

  test "present false booleans do not satisfy materialize mode checks" do
    assert {:error, target} =
             CommandParser.parse([
               "materialize",
               "ptc.json",
               "--workflow=false",
               "--target-mission",
               "writer",
               "--component",
               "helper",
               "--source-out",
               "out.clj"
             ])

    assert target.command == :materialize
    assert target.code == :conflicting_arguments

    assert {:error, provenance} =
             CommandParser.parse([
               "materialize",
               "ptc.json",
               "--workflow",
               "--component",
               "helper",
               "--source-out",
               "out.clj",
               "--accept-widened-effect=false"
             ])

    assert provenance.command == :materialize
    assert provenance.code == :conflicting_arguments
  end

  test "materialize requires a target and a destination" do
    assert {:error, rejection} =
             CommandParser.parse(["materialize", "ptc.json", "--component", "helper"])

    assert rejection.command == :materialize
    assert rejection.code == :invalid_arguments
  end

  test "standalone materialize accepts the RFC 6901 root pointer" do
    assert {:ok, arguments} =
             CommandParser.parse([
               "materialize",
               "ptc.json",
               "--workflow",
               "--component",
               "helper",
               "--out",
               "candidate",
               "--from-result",
               "result.json",
               "--result-pointer",
               ""
             ])

    assert arguments.options.result_pointer == ""
  end

  test "help materialize is generated from the command declaration" do
    assert {:ok, outcome} = CommandEngine.dispatch(["help", "materialize"])
    assert outcome.envelope["result"]["topic"] == "materialize"

    assert Enum.any?(outcome.envelope["result"]["usage"], &String.contains?(&1, "--source-out"))
    assert Enum.any?(outcome.envelope["result"]["usage"], &String.contains?(&1, "--out DIR"))
  end

  @tag :tmp_dir
  test "standalone materialize --source-out writes interned source", %{tmp_dir: dir} do
    manifest = write_application(dir)
    exported = Path.join(dir, "exported.clj")

    assert {:ok, outcome} =
             CommandEngine.dispatch([
               "materialize",
               manifest,
               "--workflow",
               "--component",
               "helper",
               "--source-out",
               exported
             ])

    assert outcome.envelope["status"] == "ok"
    assert outcome.envelope["result"]["mode"] == "source-out"
    assert File.read!(exported) == @placeholder

    assert {:error, refused} =
             CommandEngine.dispatch([
               "materialize",
               manifest,
               "--workflow",
               "--component",
               "helper",
               "--source-out",
               exported
             ])

    assert refused.envelope["error"]["phase"] == "publication"
    assert refused.envelope["error"]["code"] == "source_out_destination_exists"
  end

  @tag :tmp_dir
  test "standalone materialize candidate mode publishes a gated directory", %{tmp_dir: dir} do
    manifest = write_application(dir)
    authored = Path.join(dir, "authored.clj")
    out = Path.join(dir, "candidate")
    File.write!(authored, @authored)

    assert {:ok, outcome} =
             CommandEngine.dispatch([
               "materialize",
               manifest,
               "--workflow",
               "--component",
               "helper",
               "--out",
               out,
               "--source",
               authored
             ])

    assert outcome.envelope["status"] == "ok"
    assert outcome.envelope["result"]["mode"] == "candidate"
    assert File.read!(Path.join(out, "candidate.clj")) == @authored
  end

  @tag :tmp_dir
  test "standalone candidate mode keeps the 1 MiB source bound", %{tmp_dir: dir} do
    manifest = write_application(dir)
    authored = Path.join(dir, "authored.clj")
    File.write!(authored, String.duplicate("x", 1_048_577))

    assert {:error, outcome} =
             CommandEngine.dispatch([
               "materialize",
               manifest,
               "--workflow",
               "--component",
               "helper",
               "--out",
               Path.join(dir, "candidate"),
               "--source",
               authored
             ])

    assert outcome.envelope["error"]["phase"] == "publication"
    assert outcome.envelope["error"]["code"] == "candidate_source_too_large"
    refute File.exists?(Path.join(dir, "candidate"))
  end

  @tag :tmp_dir
  test "a missing selected component is a publication diagnostic", %{tmp_dir: dir} do
    manifest = write_application(dir)

    assert {:error, outcome} =
             CommandEngine.dispatch([
               "materialize",
               manifest,
               "--workflow",
               "--component",
               "missing",
               "--source-out",
               Path.join(dir, "exported.clj")
             ])

    assert outcome.envelope["error"]["phase"] == "publication"
    assert outcome.envelope["error"]["code"] == "selected_component_missing"
    refute File.exists?(Path.join(dir, "exported.clj"))
  end

  @tag :tmp_dir
  test "materialize --source-out expands a project document to its application", %{tmp_dir: dir} do
    target = Path.join(dir, "demo")
    assert {:ok, _outcome} = CommandEngine.dispatch(["init", target])
    exported = Path.join(dir, "main.clj")

    assert {:ok, outcome} =
             CommandEngine.dispatch([
               "materialize",
               Path.join(target, "ptc-project.json"),
               "--workflow",
               "--component",
               "main",
               "--source-out",
               exported
             ])

    assert outcome.envelope["result"]["mode"] == "source-out"
    assert File.read!(exported) =~ "(defn run"
  end

  @tag :tmp_dir
  test "an envelope path equal to --source-out is refused before publication", %{tmp_dir: dir} do
    manifest = write_application(dir)
    exported = Path.join(dir, "exported.clj")

    assert {:error, entry} =
             CommandEntry.open(
               [
                 "materialize",
                 manifest,
                 "--workflow",
                 "--component",
                 "helper",
                 "--source-out",
                 exported,
                 "--envelope",
                 exported
               ],
               :standalone
             )

    assert entry.rejection.command == :materialize
    assert entry.rejection.kind == :destination_collision
    refute File.exists?(exported)
  end

  test "sealed materialize success requires an absolute destination" do
    run_ref = "cmd-00000000000000000000000001"

    assert_raise ArgumentError, fn ->
      CommandOutcome.success(:materialize, run_ref, %{
        "mode" => "source-out",
        "path" => "relative.clj"
      })
    end

    assert_raise ArgumentError, fn ->
      CommandOutcome.success(:materialize, run_ref, %{
        "mode" => "candidate",
        "directory" => "candidate"
      })
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
