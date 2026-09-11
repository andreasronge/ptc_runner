defmodule PtcRunner.Kernel.ExampleLibraryTest do
  # async: false — two cases mutate the OS environment (OPENROUTER_API_KEY, a .env load) and
  # reinstall the :default logger handler (class D); the other 13 could run async in a sibling
  # module.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PtcRunner.Dotenv
  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.ExampleLibrary
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProjectConfig
  alias PtcRunner.MixCommandAdapter

  @root Path.expand("../../..", __DIR__)

  test "every embedded tree is the checked-in tree, byte for byte" do
    for name <- ExampleLibrary.names() do
      assert {:ok, files} = ExampleLibrary.fetch(name)

      for {relative, content} <- files do
        source = Path.join([@root, "examples", name, relative])

        if File.regular?(source) do
          assert File.read!(source) == content, "#{name}/#{relative} drifted from its source"
        end
      end
    end
  end

  @tag :tmp_dir
  test "every materialized PTC document identifies and passes its runtime schema boundary", %{
    tmp_dir: directory
  } do
    schema_by_role = %{
      application: "https://ptc-runner.dev/schemas/ptc-application-manifest.schema.json",
      host: "https://ptc-runner.dev/schemas/ptc-host-config.schema.json",
      project: "https://ptc-runner.dev/schemas/ptc-project-config.schema.json"
    }

    for name <- ExampleLibrary.names() do
      target = Path.join(directory, name)

      assert {:ok, %CommandOutcome{}} =
               CommandEngine.dispatch(["init", target, "--example", name])

      installed_limits = installed_limits_for(target)

      for path <- Path.wildcard(Path.join(target, "**/*.json")) do
        source = File.read!(path)
        document = Jason.decode!(source)

        case ptc_document_role(document) do
          nil ->
            :ok

          role ->
            assert document["$schema"] == schema_by_role[role], path
            assert String.starts_with?(source, ~s({\n  "$schema":)), path
            assert_runtime_loads(role, path, installed_limits)
        end
      end
    end
  end

  test "the materializable multi-turn tutorial relies on the default run clocks" do
    assert {:ok, files} = ExampleLibrary.fetch("kernel-tutorial")

    manifest = files["04-multi-turn-agent/ptc.json"] |> Jason.decode!()

    refute Map.has_key?(manifest, "limits")
  end

  test "the materializable cost-budget tutorial includes both spend ceilings and a tariff" do
    assert {:ok, files} = ExampleLibrary.fetch("kernel-tutorial")

    manifest = files["06-cost-budget/ptc.json"] |> Jason.decode!()
    host = files["ptc-host-cost-budget.json"] |> Jason.decode!()

    assert manifest["limits"]["llm_cost_microusd"] == 1
    assert host["limits"]["llm_cost_microusd"] == 1

    assert host["install"]["deepseek"]["reservation_tariff"] == %{
             "currency" => "USD",
             "id" => "openrouter-model-pricing-v1"
           }
  end

  test "run artifacts are not embedded and local .env files are not copied from the source tree" do
    for name <- ExampleLibrary.names(),
        {:ok, files} = ExampleLibrary.fetch(name),
        {relative, _content} <- files do
      segments = Path.split(relative)
      source = Path.join([@root, "examples", name, relative])

      refute ".ptc" in segments, "#{name} embeds a run artifact: #{relative}"

      if List.last(segments) == ".env" do
        refute File.regular?(source), "#{name} copied a local environment file"
      end
    end
  end

  test "every materializable example ships in the hex package" do
    packaged = Mix.Project.config()[:package][:files]

    for name <- ExampleLibrary.names() do
      assert "examples/#{name}" in packaged,
             "examples/#{name} is materializable but missing from mix.exs package files"
    end
  end

  @tag :tmp_dir
  test "init materializes env stubs, gitignore, and docs commands instead of checkout paths", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "kernel-tutorial")

    assert {:ok, %CommandOutcome{envelope: envelope}} =
             CommandEngine.dispatch(["init", target, "--example", "kernel-tutorial"])

    assert File.exists?(Path.join(target, ".env"))
    assert File.exists?(Path.join(target, ".gitignore"))

    # The routing card is the scaffold's, minus the scaffold's file names: an
    # agent dropped into a materialized example finds the same commands.
    card = File.read!(Path.join(target, "AGENTS.md"))
    assert card =~ "ptc docs agent-guide"
    assert card =~ "README.md"
    refute card =~ "main.clj"
    refute File.read!(Path.join(target, "README.md")) =~ "../../docs/"
    refute File.read!(Path.join(target, ".env")) == ""

    for name <- ExampleLibrary.names() do
      assert {:ok, files} = ExampleLibrary.fetch(name)

      if Map.has_key?(files, "README.md") do
        refute files["README.md"] =~ "../../docs/",
               "#{name} README still points at checkout documentation"
      end
    end

    for project_path <- Path.wildcard(Path.join(target, "*.ptc-project.json")) do
      assert {:ok, project} = ProjectConfig.load(project_path)

      if is_binary(project.env_file) do
        assert File.exists?(project.env_file), project.env_file
      end
    end

    assert {:ok, created} = ExampleLibrary.created("kernel-tutorial")
    assert ".env" in created
    assert ".gitignore" in created
    assert "AGENTS.md" in created
    assert envelope["result"] == %{"created" => created}
    assert CommandContract.valid_envelope?(envelope)

    assert {:ok, replay} = ExampleLibrary.fetch("llm-replay")
    refute Map.has_key?(replay, ".env")
  end

  @tag :tmp_dir
  test "model-backed examples keep inherited credentials through comment-only env stubs", %{
    tmp_dir: directory
  } do
    key = "OPENROUTER_API_KEY"
    previous = System.get_env(key)
    sentinel = "inherited-sentinel"
    System.put_env(key, sentinel)

    on_exit(fn ->
      if previous, do: System.put_env(key, previous), else: System.delete_env(key)
    end)

    for example <- ["kernel-tutorial", "support-triage"] do
      target = Path.join(directory, example)

      assert {:ok, %CommandOutcome{}} =
               CommandEngine.dispatch(["init", target, "--example", example])

      env_file = Path.join(target, ".env")
      contents = File.read!(env_file)
      assert contents =~ "# #{key}"
      refute contents =~ ~r/^#{key}=/m
      assert :ok = Dotenv.load_file(env_file)
      assert System.get_env(key) == sentinel
    end
  end

  test "the debugging README leads to the standalone self-improvement script" do
    assert {:ok, files} = ExampleLibrary.fetch("debug-a-failed-run")
    readme = files["README.md"]
    script = files["run-self-improvement.sh"]

    assert readme =~ "sh debug-a-failed-run/run-self-improvement.sh"
    assert readme =~ "self-debugger/debug.start.clj"
    assert readme =~ "ptc docs debug"
    refute script =~ "mix ptc"
    assert script =~ "expect_failure target.ptc-project.json"
    assert script =~ "ptc run self-improver.ptc-project.json"
    assert script =~ "ptc run self-repair.ptc-project.json"
    assert script =~ "--component-override-descriptor"
    assert script =~ "self-debugger/validation/*.json"
  end

  test "the adaptive parser repairs inside PTC and reuses an accepted program without a model" do
    assert {:ok, files} = ExampleLibrary.fetch("adaptive-web-parser")

    replay_host = Jason.decode!(files["ptc-host.json"])
    live_host = Jason.decode!(files["ptc-host.live.json"])
    application = Jason.decode!(files["ptc.json"])

    assert replay_host["install"]["repair-model"]["source"] == "llm_replay"
    assert live_host["install"]["repair-model"]["source"] == "llm"

    assert replay_host["install"]["web"]["transport"]["args"] ==
             ["-y", "ptc-web@0.1.0"]

    assert replay_host["install"]["candidate-store"]["transport"]["args"] ==
             ["-y", "ptc-fs-mcp@0.4.0", "--root", ".ptc-private-demo", "--include", "*.clj"]

    assert application["missions"]["browser"]["providers"] == ["web"]
    assert application["missions"]["artifact"]["providers"] == ["candidate-store"]

    assert application["providers"]["mission"] |> List.last() |> get_in(["config", "allow"]) ==
             ["candidate.read", "candidate.write"]

    assert application["providers"]["workflow"] == [%{"name" => "repair-model"}]
    assert files["README.md"] =~ "needs no LLM key"
    assert files["workflow.clj"] =~ "kernel/check-terminal-source"
    assert files["workflow.clj"] =~ ~s(write-source "accepted.clj")
    assert files["run.mjs"] =~ "reuse must not call a model"
  end

  @tag :tmp_dir
  test "init materializes a nested tree the documented commands then run", %{tmp_dir: directory} do
    target = Path.join(directory, "kernel-tutorial")

    assert {:ok, %CommandOutcome{envelope: envelope}} =
             CommandEngine.dispatch(["init", target, "--example", "kernel-tutorial"])

    assert {:ok, created} = ExampleLibrary.created("kernel-tutorial")
    assert envelope["result"] == %{"created" => created}
    assert CommandContract.valid_envelope?(envelope)

    assert {:ok, files} = ExampleLibrary.fetch("kernel-tutorial")

    for {relative, content} <- files do
      assert File.read!(Path.join(target, relative)) == content
    end

    # The nested layout is what keeps the project documents' relative paths
    # valid, so the materialized copy runs from wherever it was created.
    assert File.dir?(Path.join(target, "01-orders"))

    assert {:ok, %CommandOutcome{envelope: run_envelope}} =
             CommandEngine.dispatch(["run", Path.join(target, "01-orders.ptc-project.json")])

    assert run_envelope["result"]["value"] == %{
             "order_count" => 3,
             "paid_count" => 2,
             "paid_total" => 335.75,
             "pending_ids" => ["A-101"]
           }
  end

  @tag :tmp_dir
  test "init materializes the replay example as a one-argument project run", %{
    tmp_dir: directory
  } do
    assert {:ok, %CommandOutcome{envelope: docs_envelope}} =
             CommandEngine.dispatch(["docs", "agent-guide"])

    guide = docs_envelope["result"]["content"]
    assert guide =~ "Choose one `ptc init` form"
    assert guide =~ "ptc init hello-ptc --example llm-replay"
    assert guide =~ "ptc repl --project hello-ptc/ptc-project.json -e '(dir)'"

    target = Path.join(directory, "llm-replay")

    assert {:ok, %CommandOutcome{}} =
             CommandEngine.dispatch(["init", target, "--example", "llm-replay"])

    assert File.exists?(Path.join(target, "ptc-project.json"))

    repl_output =
      capture_io(fn ->
        MixCommandAdapter.run_task([
          "repl",
          "--project",
          Path.join(target, "ptc-project.json"),
          "-e",
          "(dir)"
        ]).outcome
      end)

    assert repl_output == ~s(["cap" "example.replay"]\n)

    assert {:ok, %CommandOutcome{envelope: envelope}} =
             CommandEngine.dispatch(["run", Path.join(target, "ptc-project.json")])

    assert envelope["result"]["value"] == %{
             "content" => "Frozen answer",
             "model" => "frozen-model"
           }
  end

  @tag :tmp_dir
  test "an unknown example is refused before any target work, with the names", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "absent")

    assert {:error, %CommandOutcome{envelope: envelope}} =
             CommandEngine.dispatch(["init", target, "--example", "sensitive-example-name"])

    assert envelope["error"]["phase"] == "arguments"
    assert envelope["error"]["code"] == "example_unknown"
    refute envelope |> Jason.encode!() |> String.contains?("sensitive-example-name")
    refute File.exists?(target)
  end

  @tag :tmp_dir
  test "an existing target is never replaced by an example", %{tmp_dir: directory} do
    target = Path.join(directory, "occupied")
    File.mkdir_p!(target)
    File.write!(Path.join(target, "keep.txt"), "original")

    assert {:error, %CommandOutcome{envelope: envelope}} =
             CommandEngine.dispatch(["init", target, "--example", "llm-replay"])

    assert envelope["error"]["phase"] == "publication"
    assert File.ls!(target) == ["keep.txt"]
  end

  defp ptc_document_role(%{"kind" => "ptc-project"}), do: :project

  defp ptc_document_role(%{"version" => 1, "workflow" => workflow}) when is_map(workflow),
    do: :application

  defp ptc_document_role(%{"install" => install}) when is_map(install), do: :host
  defp ptc_document_role(_document), do: nil

  defp installed_limits_for(target) do
    overrides =
      target
      |> Path.join("**/*.json")
      |> Path.wildcard()
      |> Enum.reduce(%{}, fn path, acc ->
        case path |> File.read!() |> Jason.decode!() do
          %{"install" => install} = host when is_map(install) ->
            host
            |> Map.get("limits", %{})
            |> Enum.reduce(acc, fn {name, value}, limits ->
              {:ok, field} = Limits.name(name)
              Map.update(limits, field, value, &max(&1, value))
            end)

          _document ->
            acc
        end
      end)

    {:ok, limits} = Limits.installed(overrides)
    limits
  end

  defp assert_runtime_loads(:project, path, _installed_limits),
    do: assert({:ok, _project} = ProjectConfig.load(path))

  defp assert_runtime_loads(:application, path, installed_limits),
    do:
      assert(
        {:ok, _request} =
          ApplicationPackage.request_directory(path, installed_limits: installed_limits)
      )

  defp assert_runtime_loads(:host, path, _installed_limits),
    do: assert({:ok, _host} = HostConfig.load(path))
end
