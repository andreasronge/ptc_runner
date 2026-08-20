defmodule PtcRunner.Kernel.ProjectConfigTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ProjectArtifactRoot
  alias PtcRunner.Kernel.ProjectConfig

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
      assert {:error, :project_invalid} = ProjectConfig.load(path)
    end)
  end

  @tag :tmp_dir
  test "classifies documents only by the explicit kind discriminator", %{tmp_dir: directory} do
    project = Path.join(directory, "anything.json")
    manifest = Path.join(directory, "ptc-project.json")
    foreign = Path.join(directory, "foreign.json")

    File.write!(project, ~s({"kind":"ptc-project","version":1,"application":{"path":"ptc.json"}}))
    File.write!(manifest, ~s({"version":1,"workflow":{}}))
    File.write!(foreign, ~s({"kind":"something-else"}))

    assert {:project, _config} = ProjectConfig.classify(project)
    assert :application = ProjectConfig.classify(manifest)
    assert {:error, :project_invalid} = ProjectConfig.classify(foreign)
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
      assert {:error, :project_invalid} = ProjectConfig.load(path)
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
