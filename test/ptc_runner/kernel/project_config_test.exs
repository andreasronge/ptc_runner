defmodule PtcRunner.Kernel.ProjectConfigTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.CommandRenderer
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.ProjectArtifactRoot
  alias PtcRunner.Kernel.ProjectConfig
  alias PtcRunner.Kernel.SchemaViolation
  alias PtcRunner.Kernel.SchemaViolationDiagnostic

  @tag :tmp_dir
  test "loads the closed project document and resolves paths below its directory", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "ptc-project.json")

    File.write!(
      path,
      Jason.encode!(%{
        "$schema" => "https://ptc-runner.dev/schemas/ptc-project-config.schema.json",
        "kind" => "ptc-project",
        "version" => 1,
        "application" => %{"path" => "ptc.json"},
        "host" => %{"path" => "host/ptc-host.json", "env_file" => %{"path" => ".env"}},
        "artifacts" => %{
          "root" => ".ptc",
          "trace" => true,
          "inspection" => true,
          "result" => false,
          "envelope" => true
        },
        "viewer" => %{"port" => 4123, "open" => true, "repl" => true, "private" => true}
      })
    )

    assert {:ok, project} = ProjectConfig.load(path)
    assert project.application == Path.join(directory, "ptc.json")
    assert project.host == Path.join([directory, "host", "ptc-host.json"])
    assert project.env_file == Path.join(directory, ".env")
    assert project.artifact_root == Path.join(directory, ".ptc")
    assert project.artifacts.inspection
    assert project.viewer.private
  end

  @tag :tmp_dir
  test "an omitted Viewer port asks the operating system for a free port", %{tmp_dir: directory} do
    path = Path.join(directory, "ptc-project.json")

    File.write!(
      path,
      Jason.encode!(%{
        "kind" => "ptc-project",
        "version" => 1,
        "application" => %{"path" => "ptc.json"},
        "viewer" => %{}
      })
    )

    assert {:ok, project} = ProjectConfig.load(path)
    assert project.viewer.port == 0
    assert ProjectConfig.schema()["properties"]["viewer"]["properties"]["port"]["default"] == 0
  end

  @tag :tmp_dir
  test "rejects duplicate, unknown, traversing, and inconsistent values", %{tmp_dir: directory} do
    path = Path.join(directory, "ptc-project.json")

    invalid = [
      ~s({"kind":"ptc-project","kind":"ptc-project","version":1,"application":{"path":"ptc.json"}}),
      ~s({"kind":"ptc-project","version":1,"application":{"path":"ptc.json"},"extra":true}),
      ~s({"kind":"ptc-project","version":1,"application":{"path":"../ptc.json"}}),
      ~s({"kind":"ptc-project","version":1,"application":{"path":"ptc.json"},"artifacts":{"root":".ptc","inspection":true}})
    ]

    Enum.each(invalid, fn bytes ->
      File.write!(path, bytes)

      assert {:error, {:project_schema_invalid, %SchemaViolation{}}} =
               ProjectConfig.load(path)
    end)
  end

  @tag :tmp_dir
  test "preserves bounded schema violations for project document failures", %{tmp_dir: directory} do
    path = Path.join(directory, "ptc-project.json")

    base = %{
      "kind" => "ptc-project",
      "version" => 1,
      "application" => %{"path" => "ptc.json"}
    }

    cases = [
      {Map.put(base, "artifactz", %{}), :unknown_property, []},
      {Map.delete(base, "application"), :required, [{:property, "application"}]},
      {Map.put(base, "artifacts", %{"root" => ".ptc", "trace" => "yes"}), :type,
       [{:property, "artifacts"}, {:property, "trace"}]},
      {Map.put(base, "viewer", %{"port" => 65_536}), :maximum,
       [{:property, "viewer"}, {:property, "port"}]},
      {put_in(base, ["application", "path"], "../ptc.json"), :pattern,
       [{:property, "application"}, {:property, "path"}]},
      {Map.put(base, "artifacts", %{
         "root" => ".ptc",
         "trace" => false,
         "inspection" => true
       }), :const, [{:property, "artifacts"}, {:property, "trace"}]}
    ]

    for {document, rule, segments} <- cases do
      File.write!(path, Jason.encode!(document))

      assert {:error, {:project_schema_invalid, %SchemaViolation{rule: ^rule, path: ^segments}}} =
               ProjectConfig.load(path)
    end

    File.write!(
      path,
      ~s({"kind":"ptc-project","version":1,"application":{"path":"ptc.json","path":"other.json"}})
    )

    assert {:error,
            {:project_schema_invalid,
             %SchemaViolation{
               rule: :duplicate_property,
               path: [{:property, "application"}]
             }}} = ProjectConfig.load(path)
  end

  test "project diagnostics accept only project source and schema-authorized paths" do
    source = CommandSource.fixed(:project)
    segments = [{:property, "viewer"}, {:property, "port"}]
    assert {:ok, path} = CommandPath.project(segments)
    assert {:ok, message} = SchemaViolationDiagnostic.message(:project, :maximum)

    assert {:ok, diagnostic} =
             CommandDiagnostic.new(:project, :project_schema_invalid,
               source: source,
               path: path,
               message: message
             )

    assert CommandDiagnostic.to_map(diagnostic) == %{
             "phase" => "project",
             "code" => "project_schema_invalid",
             "message" => "the project configuration violates the maximum schema rule",
             "source" => %{"kind" => "project", "name" => "ptc-project.json"},
             "path" => "/viewer/port",
             "span" => nil,
             "subject" => nil,
             "notes" => [],
             "retryable" => false,
             "provider_activity" => false
           }

    outcome =
      CommandOutcome.error(:validate, "cmd-00000000000000000000000000", diagnostic)

    assert CommandRenderer.render(outcome) ==
             {:stderr,
              "error: project/project_schema_invalid: " <>
                "the project configuration violates the maximum schema rule " <>
                "at /viewer/port (run_ref: cmd-00000000000000000000000000)\n"}

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:project, :project_schema_invalid,
               source: CommandSource.fixed(:application),
               path: path,
               message: message
             )
  end

  @tag :tmp_dir
  test "classifies documents only by the explicit kind discriminator", %{tmp_dir: directory} do
    project = Path.join(directory, "anything.json")
    manifest = Path.join(directory, "ptc-project.json")
    foreign = Path.join(directory, "foreign.json")

    File.write!(project, ~s({"kind":"ptc-project","version":1,"application":{"path":"ptc.json"}}))
    File.write!(manifest, ~s({"version":1,"workflow":{}}))

    File.write!(
      foreign,
      ~s({"kind":"something-else","artifacts":{"root":"artifacts","inspection":true}})
    )

    assert {:project, _config} = ProjectConfig.classify(project)
    assert :application = ProjectConfig.classify(manifest)

    assert {:error,
            {:project_schema_invalid, %SchemaViolation{rule: :const, path: [{:property, "kind"}]}}} =
             ProjectConfig.classify(foreign)

    File.write!(
      project,
      ~s({"kind":"ptc-project","version":1,"application":{"path":"ptc.json","path":"other.json"}})
    )

    assert {:error,
            {:project_schema_invalid,
             %SchemaViolation{
               rule: :duplicate_property,
               path: [{:property, "application"}]
             }}} = ProjectConfig.classify(project)

    File.write!(
      foreign,
      ~s({"kind":"something-else","application":{"path":"ptc.json","path":"other.json"}})
    )

    assert {:error,
            {:project_schema_invalid, %SchemaViolation{rule: :const, path: [{:property, "kind"}]}}} =
             ProjectConfig.classify(foreign)

    nested = String.duplicate("[", 65) <> "0" <> String.duplicate("]", 65)

    File.write!(
      project,
      ~s({"kind":"ptc-project","version":1,"application":{"path":"ptc.json"},"viewer":#{nested}})
    )

    assert {:error, {:project_schema_invalid, %SchemaViolation{rule: :schema, path: []}}} =
             ProjectConfig.classify(project)
  end

  @tag :tmp_dir
  test "an oversized document keeps an early project discriminator", %{tmp_dir: directory} do
    path = Path.join(directory, "oversized.json")

    File.write!(
      path,
      ~s({"kind":"ptc-project","version":1,"application":{"path":"ptc.json"},"padding":") <>
        String.duplicate("x", 300_000) <> ~s("})
    )

    assert {:error, {:project_schema_invalid, %SchemaViolation{rule: :schema, path: []}}} =
             ProjectConfig.classify(path)
  end

  @tag :tmp_dir
  test "accepts schema-integral JSON numbers in the manual decoder", %{tmp_dir: directory} do
    path = Path.join(directory, "ptc-project.json")

    File.write!(
      path,
      ~s({"kind":"ptc-project","version":1.0,"application":{"path":"ptc.json"},"viewer":{"port":3000.0}})
    )

    assert {:ok, project} = ProjectConfig.load(path)
    assert project.viewer.port == 3_000
  end

  @tag :tmp_dir
  test "generated schema and runtime reject non-portable path forms consistently", %{
    tmp_dir: directory
  } do
    assert {:ok, validator} =
             JSV.build(ProjectConfig.schema(), atoms: false, warnings: :silent)

    for application <- [".", "foo/./bar", "..", "foo/../bar", "artifacts/"] do
      document = %{
        "kind" => "ptc-project",
        "version" => 1,
        "application" => %{"path" => application}
      }

      assert {:error, _details} = JSV.validate(document, validator, cast: false)

      path = Path.join(directory, "ptc-project.json")
      File.write!(path, Jason.encode!(document))

      assert {:error, {:project_schema_invalid, %SchemaViolation{rule: :pattern}}} =
               ProjectConfig.load(path)
    end

    valid = %{
      "kind" => "ptc-project",
      "version" => 1,
      "application" => %{"path" => ".config/ptc.json"}
    }

    assert {:ok, _validated} = JSV.validate(valid, validator, cast: false)
  end

  @tag :tmp_dir
  test "artifact roots are complete, owner-only, and safe under concurrent creation", %{
    tmp_dir: directory
  } do
    root = Path.join(directory, ".ptc")

    results =
      1..4
      |> Task.async_stream(fn _index -> ProjectArtifactRoot.ensure(root) end,
        max_concurrency: 4,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &(&1 == :ok))
    assert Enum.sort(File.ls!(root)) == ~w(envelopes inspection results traces)

    for path <- [root | Enum.map(File.ls!(root), &Path.join(root, &1))] do
      assert {:ok, %File.Stat{type: :directory, mode: mode}} = File.lstat(path)
      assert Bitwise.band(mode, 0o077) == 0
    end
  end

  @tag :tmp_dir
  test "an incomplete existing artifact root is never repaired in place", %{tmp_dir: directory} do
    root = Path.join(directory, ".ptc")
    File.mkdir!(root)
    File.chmod!(root, 0o700)

    assert {:error, {:project_artifact_root_incomplete, ^root}} = ProjectArtifactRoot.ensure(root)
    assert File.ls!(root) == []
  end
end
