defmodule PtcRunner.Kernel.ProjectCommandTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandEntry
  alias PtcRunner.Kernel.CommandFrontend
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRuntime

  @tag :tmp_dir
  test "an initialized project runs through its single project document", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")

    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    assert {:ok, %CommandOutcome{envelope: %{"status" => "ok", "run_ref" => run_ref}}} =
             CommandEngine.dispatch(["run", project])

    assert [trace] = Path.wildcard(Path.join([target, ".ptc", "traces", "*.jsonl"]))
    assert File.regular?(trace)

    envelope = Path.join([target, ".ptc", "envelopes", run_ref <> ".json"])
    assert Jason.decode!(File.read!(envelope))["run_ref"] == run_ref
  end

  @tag :tmp_dir
  test "preparation remains read-only and creates the project artifact layout only at dispatch",
       %{
         tmp_dir: directory
       } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    artifact_root = Path.join(target, ".ptc")

    assert {:ok, preparation} = CommandEngine.prepare(["run", project])
    refute File.exists?(artifact_root)
    assert :ok = CommandPreparation.close(preparation)

    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
    assert File.dir?(artifact_root)
  end

  @tag :tmp_dir
  test "a first-run application failure still publishes its project envelope", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = Jason.decode!(File.read!(project_path))
    project = put_in(project, ["application", "path"], "missing.json")
    File.write!(project_path, Jason.encode!(project))

    assert {:error, %CommandOutcome{envelope: outcome}} =
             CommandEngine.dispatch(["run", project_path])

    assert outcome["error"]["phase"] == "application"
    envelope_path = Path.join([target, ".ptc", "envelopes", outcome["run_ref"] <> ".json"])
    assert Jason.decode!(File.read!(envelope_path))["error"]["phase"] == "application"
  end

  @tag :tmp_dir
  test "the frontend publishes a first-run failure envelope from project defaults", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = Jason.decode!(File.read!(project_path))
    project = put_in(project, ["application", "path"], "missing.json")
    File.write!(project_path, Jason.encode!(project))

    presentation =
      CommandFrontend.execute(["run", project_path], :standalone, fn _arguments ->
        {:ok, CommandRuntime.standalone()}
      end)

    assert presentation.outcome.envelope["error"]["phase"] == "application"
    assert File.regular?(presentation.envelope_path)
  end

  @tag :tmp_dir
  test "project defaults are merged and explicit command values win", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    explicit_traces = Path.join(target, "explicit-traces")
    File.mkdir!(explicit_traces)
    run_ref = "cmd-00000000000000000000000000"

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["run", project, "--trace-dir", explicit_traces],
               :mix,
               run_ref
             )

    assert entry.arguments.application == Path.join(target, "ptc.json")
    assert entry.arguments.options.trace_dir == explicit_traces
    assert entry.envelope_path == Path.join([target, ".ptc", "envelopes", run_ref <> ".json"])
  end

  @tag :tmp_dir
  test "project-backed repl preserves the manifest grammar", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["repl", "--project", project, "--eval", "(+ 1 2)"],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert entry.arguments.options.manifest == Path.join(target, "ptc.json")

    assert Keyword.get(entry.arguments.ordered_options, :manifest) ==
             Path.join(target, "ptc.json")

    assert Keyword.get(entry.arguments.ordered_options, :eval) == "(+ 1 2)"
  end

  test "the repl option terminator leaves project-looking script arguments positional" do
    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["repl", "--", "--project=missing.json"],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert entry.arguments.application == "--project=missing.json"
    assert entry.arguments.project == nil
  end

  @tag :tmp_dir
  test "project-backed repl inserts defaults before the option terminator", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["repl", "--project", project, "--", "--manifest"],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert entry.arguments.application == "--manifest"
    assert entry.arguments.options.manifest == Path.join(target, "ptc.json")
    assert entry.arguments.project.config.path == project
  end

  @tag :tmp_dir
  test "passive doctor accepts a project and does not require its missing environment file", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = Jason.decode!(File.read!(project_path))

    project =
      Map.put(project, "host", %{
        "path" => "missing-host.json",
        "env_file" => %{"path" => "missing.env"}
      })

    File.write!(project_path, Jason.encode!(project))

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["doctor", project_path],
               :mix,
               "cmd-00000000000000000000000000"
             )

    refute Keyword.has_key?(entry.arguments.frontend_options, :env_file)
    assert entry.arguments.options.host_config == Path.join(target, "missing-host.json")
  end

  @tag :tmp_dir
  test "a project declaring no host says so rather than blaming the arguments", %{
    tmp_dir: directory
  } do
    # `ptc init` scaffolds no host block, so the two commands that need one are
    # reached with exactly the argument form their own --help prints. Blaming
    # the command line sends the reader back to the syntax, which was correct.
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    for argv <- [["models", project], ["doctor", project, "--connect"]] do
      assert {:error, %CommandOutcome{} = outcome} = CommandEngine.dispatch(argv)

      assert outcome.envelope["error"]["code"] == "project_host_undeclared"
      assert outcome.envelope["error"]["phase"] == "arguments"
      assert outcome.envelope["error"]["message"] =~ "--host-config"
    end
  end

  @tag :tmp_dir
  test "an explicit --host-config still serves a project that declares no host", %{
    tmp_dir: directory
  } do
    # The rejection must name a missing declaration, not forbid the command, so
    # the documented alternative in `ptc models --help` keeps working.
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    host_path = Path.join(target, "ptc-host.json")

    File.write!(
      host_path,
      Jason.encode!(%{
        "credentials" => %{"key" => %{"env" => "PTC_PROJECT_ABSENT_KEY"}},
        "install" => %{
          "model" => %{
            "source" => "llm",
            "installation_revision" => "model-v1",
            "model" => "openrouter:test/model",
            "credential" => "key"
          }
        }
      })
    )

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["models", "--host-config", host_path])

    assert [%{"alias" => "model"}] = outcome.envelope["result"]["installations"]
  end

  @tag :tmp_dir
  test "repl rejects ambiguous project authority modes", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    assert {:error, entry} =
             CommandEntry.open_with_ref(
               ["repl", "--project", project, "--manifest", "other.json"],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert entry.rejection.code == :conflicting_arguments
  end
end
