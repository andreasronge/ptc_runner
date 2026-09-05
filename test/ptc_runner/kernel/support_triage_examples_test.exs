defmodule PtcRunner.Kernel.SupportTriageExamplesTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.ProjectConfig

  @examples Path.expand("../../../examples/support-triage", __DIR__)

  test "the shared host installs only the tutorial model alias" do
    assert {:ok, host} = HostConfig.load(Path.join(@examples, "ptc-host.json"))
    assert Map.keys(host.install) == ["deepseek"]
  end

  test "every step validates its bundles without provider activity" do
    for {step, port} <- [
          {"01-one-question", 4131},
          {"02-domain-api", 4132},
          {"03-specialists", 4133}
        ] do
      project_path = Path.join(@examples, "#{step}.ptc-project.json")
      assert {:ok, project} = ProjectConfig.load(project_path)
      assert project.application == Path.join([@examples, step, "ptc.json"])
      assert project.artifact_root == Path.join([@examples, step, ".ptc"])
      assert project.host == Path.join(@examples, "ptc-host.json")
      assert project.env_file == Path.join(@examples, ".env")
      # The tutorial reads the generated PTC-Lisp in the Viewer, so every step
      # retains inspection and grants it; each step gets its own Viewer port.
      assert project.artifacts == %{trace: true, inspection: true, result: false, envelope: true}
      assert project.viewer == %{port: port, open: true, repl: true, private: true}

      assert {:ok, %CommandOutcome{envelope: envelope}} =
               CommandEngine.dispatch(["validate", project_path])

      assert envelope["result"]["provider_activity"] == false
    end
  end

  test "the specialist step compiles both mission bundles and its result contract" do
    project_path = Path.join(@examples, "03-specialists.ptc-project.json")

    assert {:ok, %CommandOutcome{envelope: envelope}} =
             CommandEngine.dispatch(["validate", project_path])

    assert envelope["result"]["mission_bundle_hashes"] |> Map.keys() |> Enum.sort() ==
             ["escalation", "triage"]
  end

  @tag :tmp_dir
  test "the boundary check denies the triage grants inside the escalation mission", %{
    tmp_dir: tmp_dir
  } do
    tree = copy_tree!(tmp_dir)
    project_path = Path.join(tree, "mission-boundary-check.ptc-project.json")

    # The check needs neither a model nor a credential, so it names no host
    # document and no environment file. A copy without a `.env` still runs.
    assert {:ok, project} = ProjectConfig.load(project_path)
    assert project.host == nil
    assert project.env_file == nil
    refute File.exists?(Path.join(tree, ".env"))

    assert {:ok, %CommandOutcome{} = outcome} = CommandEngine.dispatch(["run", project_path])
    assert outcome.exit_status == 0, inspect(outcome.envelope, pretty: true)
    assert outcome.envelope["execution"]["usage"]["llm_usage"] == []

    assert outcome.envelope["result"]["value"] == %{
             "granted" => %{
               "mission" => "triage",
               "tickets_visible" => 6,
               "probe_priority" => 55
             },
             "denied" => %{
               "mission" => "escalation",
               "mission_data" =>
                 "runtime_error: data/tickets is not a granted data name. Granted: (none)",
               "mission_component" => "invalid_form: unknown namespace triage.rules/"
             }
           }
  end

  test "the boundary check runs the specialist step's own mission definitions" do
    # The check copies step 03's missions and policy files, because a manifest
    # cannot reference files above its own directory. This keeps the copy
    # honest: a grant changed in step 03 must change here too.
    assert manifest!("mission-boundary-check")["missions"] ==
             manifest!("03-specialists")["missions"]

    for file <- ~w(triage.clj escalation.clj) do
      assert File.read!(Path.join([@examples, "mission-boundary-check", file])) ==
               File.read!(Path.join([@examples, "03-specialists", file]))
    end
  end

  @tag :tmp_dir
  test "the boundary check fails when the escalation mission can answer", %{tmp_dir: tmp_dir} do
    tree = copy_tree!(tmp_dir)
    manifest = Path.join(tree, "mission-boundary-check/ptc.json")
    opened = manifest |> File.read!() |> Jason.decode!()
    tickets = opened["missions"]["triage"]["data"]

    File.write!(
      manifest,
      Jason.encode!(put_in(opened, ["missions", "escalation", "data"], tickets))
    )

    assert_explicit_failure(tree)
  end

  @tag :tmp_dir
  test "the boundary check fails on a refusal it did not expect", %{tmp_dir: tmp_dir} do
    tree = copy_tree!(tmp_dir)
    check = Path.join(tree, "mission-boundary-check/check.clj")
    source = File.read!(check)

    rewritten =
      String.replace(
        source,
        ~S|(refused (read-mission-data "escalation")|,
        ~S|(refused (read-mission-data "nowhere")|
      )

    assert rewritten != source
    File.write!(check, rewritten)

    assert_explicit_failure(tree)
  end

  defp manifest!(step) do
    [@examples, step, "ptc.json"] |> Path.join() |> File.read!() |> Jason.decode!()
  end

  defp copy_tree!(tmp_dir) do
    tree = Path.join(tmp_dir, "support-triage")
    File.cp_r!(@examples, tree)
    File.rm_rf!(Path.join(tree, "mission-boundary-check/.ptc"))
    tree
  end

  # The check's `fail` value is retained only in the run's inspection record,
  # so the command boundary shows the failure as its exit status and code.
  defp assert_explicit_failure(tree) do
    project_path = Path.join(tree, "mission-boundary-check.ptc-project.json")

    assert {:error, %CommandOutcome{} = outcome} = CommandEngine.dispatch(["run", project_path])
    assert outcome.exit_status == 5, inspect(outcome.envelope, pretty: true)
    assert outcome.envelope["error"]["code"] == "explicit_failure"
    assert outcome.envelope["error"]["provider_activity"] == false
  end
end
