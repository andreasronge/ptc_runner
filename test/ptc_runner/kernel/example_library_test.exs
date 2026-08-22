defmodule PtcRunner.Kernel.ExampleLibraryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.ExampleLibrary
  alias PtcRunner.Kernel.ProjectConfig

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
    assert envelope["result"] == %{"created" => created}
    assert CommandContract.valid_envelope?(envelope)

    assert {:ok, replay} = ExampleLibrary.fetch("llm-replay")
    refute Map.has_key?(replay, ".env")
  end

  test "the debug-a-failed-run README walks the standalone executable, not Mix" do
    assert {:ok, files} = ExampleLibrary.fetch("debug-a-failed-run")
    readme = files["README.md"]

    refute readme =~ "mix ptc"
    refute readme =~ "examples/debug-a-failed-run/"
    assert readme =~ "ptc run debug-a-failed-run/target.ptc-project.json"
    assert readme =~ "ptc run debug-a-failed-run/repair-agent.ptc-project.json"
    assert readme =~ "--component-override-descriptor"
    assert readme =~ "skips the host-owned suite"
    assert readme =~ "ptc docs debugging-a-failed-run"
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
    target = Path.join(directory, "llm-replay")

    assert {:ok, %CommandOutcome{}} =
             CommandEngine.dispatch(["init", target, "--example", "llm-replay"])

    assert File.exists?(Path.join(target, "ptc-project.json"))

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
end
