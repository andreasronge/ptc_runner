defmodule PtcRunner.Kernel.TutorialExamplesTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.ProjectConfig
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.TestSupport.RunLifecycle

  @examples Path.expand("../../../examples/kernel-tutorial", __DIR__)
  @host Path.join(@examples, "ptc-host.json")
  @viewer_examples Path.expand("../../../examples/viewer-demo", __DIR__)
  @replay_example Path.expand("../../../examples/llm-replay", __DIR__)

  test "the deterministic tutorial manifest returns the documented value" do
    {:ok, registry} = ProviderRegistry.new()

    assert {:ok,
            %{
              value: %{
                "order_count" => 3,
                "paid_count" => 2,
                "paid_total" => 335.75,
                "pending_ids" => ["A-101"]
              }
            }} =
             "01-orders"
             |> path()
             |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
             |> RunLifecycle.build(registry)
             |> RunLifecycle.execute()
  end

  test "the live-model tutorial manifests and shared host installation load strictly" do
    assert {:ok, host} = HostConfig.load(@host)
    assert host.install |> Map.keys() |> Enum.sort() == ["deepseek", "workspace"]

    for example <- ["02-deepseek-extract", "03-file-agent", "04-multi-turn-agent"] do
      assert {:ok, manifest} = Manifest.load(path(example))
      assert manifest.entry =~ "/"

      if example == "04-multi-turn-agent" do
        assert manifest.limits.run_duration_ms == 120_000
        assert manifest.limits.workflow_timeout_ms == 120_000
        assert manifest.limits.run_duration_ms < manifest.installed_limits.run_duration_ms
        assert manifest.limits.workflow_timeout_ms < manifest.installed_limits.workflow_timeout_ms
      end
    end
  end

  test "every tutorial project strictly resolves its application and local artifact root" do
    examples =
      ~w(01-orders 02-deepseek-extract 03-file-agent 04-multi-turn-agent 05-signature-feedback)

    for example <- examples do
      project_path = Path.join(@examples, "#{example}.ptc-project.json")
      assert {:ok, project} = ProjectConfig.load(project_path)
      assert project.application == path(example)
      assert project.artifact_root == Path.join([@examples, example, ".ptc"])
      # The tutorial teaches by showing the PTC-Lisp a run actually loaded and
      # generated, and the Viewer serves neither without both settings.
      assert project.artifacts == %{trace: true, inspection: true, result: false, envelope: true}
      assert project.viewer == %{port: 0, open: true, repl: true, private: true}

      if example in ~w(02-deepseek-extract 03-file-agent 04-multi-turn-agent) do
        assert project.host == @host
        assert project.env_file == Path.join(@examples, ".env")
      else
        assert project.host == nil
        assert project.env_file == nil
      end
    end
  end

  test "the signature tutorial renders retryable model feedback without a provider" do
    {:ok, registry} = ProviderRegistry.new()

    assert {:ok, result} =
             "05-signature-feedback"
             |> path()
             |> ApplicationPackage.request_directory(
               installed_limits: registry.installed_limits,
               result_projection: :json
             )
             |> RunLifecycle.build(registry)
             |> RunLifecycle.execute()

    assert %{
             "invalid_evaluation" => %{
               "kind" => "prelude_contract_error",
               "outcome" => "evaluation_error",
               "retryable?" => true,
               "details" => %{
                 "ref" => "tutorial.signatures/double",
                 "phase" => "input",
                 "path" => ["value"]
               }
             },
             "model_feedback" => feedback,
             "corrected_evaluation" => %{"outcome" => "returned", "value" => 42}
           } = result.value

    assert feedback =~ "tutorial.signatures/double input value: expected int, got string"
    assert feedback =~ "Send one corrected run_ptc_lisp call"
    assert result.usage.subordinate_evaluations == 2
    assert result.usage.capability_calls.workflow == %{}
    assert result.usage.capability_calls.mission == %{}
  end

  test "the replay example returns its frozen response without network access" do
    assert {:ok, %{value: %{"content" => "Frozen answer"}}} = run_replay(@replay_example)
  end

  test "the replay example project remembers the host installation" do
    assert {:ok, project} = ProjectConfig.load(Path.join(@replay_example, "ptc-project.json"))
    assert project.application == Path.join(@replay_example, "ptc.json")
    assert project.host == Path.join(@replay_example, "ptc-host.json")
    assert project.env_file == nil
    assert project.artifacts.inspection
    assert project.viewer.private
  end

  test "every shipped example project records inspection and grants it to the Viewer" do
    examples = Path.expand("../../../examples", __DIR__)

    projects =
      Path.wildcard(Path.join(examples, "**/*ptc-project.json"))
      |> Enum.sort()

    assert projects != []

    for path <- projects do
      assert {:ok, project} = ProjectConfig.load(path), path
      assert project.artifacts.inspection, path
      assert project.viewer.private, path
    end
  end

  @tag :tmp_dir
  test "a replay miss fails the shipped example instead of returning the error as the value", %{
    tmp_dir: directory
  } do
    example = Path.join(directory, "llm-replay")
    File.cp_r!(@replay_example, example)

    workflow = Path.join(example, "workflow.clj")
    source = File.read!(workflow)
    assert source =~ "What value is frozen?"

    File.write!(
      workflow,
      String.replace(source, "What value is frozen?", "What value is frozen NOW?")
    )

    assert {:error, %{kind: :workflow_failed, reason: :explicit_failure}} = run_replay(example)
  end

  test "the viewer journeys load against one strict host-only installation" do
    assert {:ok, host} = HostConfig.load(Path.join(@viewer_examples, "ptc-host.json"))
    assert host.install |> Map.keys() |> Enum.sort() == ["deepseek", "workspace"]

    for journey <- ~w(01-recovery 02-bulk 03-limits 04-loop-limit 05-memory) do
      assert {:ok, manifest} =
               Manifest.load(Path.join(@viewer_examples, "#{journey}.json"))

      assert Enum.map(manifest.providers.workflow, & &1["name"]) == ["deepseek"]
      assert Enum.map(manifest.providers.mission, & &1["name"]) == ["workspace"]
    end
  end

  defp path(example), do: Path.join([@examples, example, "ptc.json"])

  defp run_replay(directory) do
    {:ok, host} = HostConfig.load(Path.join(directory, "ptc-host.json"))

    {:ok, registry} =
      HostInstallation.catalog(host)
      |> then(fn {:ok, catalog} ->
        HostInstallation.runtime_registry(host, catalog)
      end)

    directory
    |> Path.join("ptc.json")
    |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
    |> RunLifecycle.build(registry)
    |> RunLifecycle.execute()
  end
end
