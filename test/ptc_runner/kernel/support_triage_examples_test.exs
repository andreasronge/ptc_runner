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
end
