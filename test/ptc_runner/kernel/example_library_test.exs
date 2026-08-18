defmodule PtcRunner.Kernel.ExampleLibraryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.ExampleLibrary

  @root Path.expand("../../..", __DIR__)

  test "every embedded tree is the checked-in tree, byte for byte" do
    for name <- ExampleLibrary.names() do
      assert {:ok, files} = ExampleLibrary.fetch(name)

      for {relative, content} <- files do
        source = Path.join([@root, "examples", name, relative])

        assert File.regular?(source), "#{name} embeds #{relative}, which is not a file"
        assert File.read!(source) == content, "#{name}/#{relative} drifted from its source"
      end
    end
  end

  test "run artifacts and local environment files are not embedded" do
    for name <- ExampleLibrary.names(),
        {:ok, files} = ExampleLibrary.fetch(name),
        relative <- Map.keys(files) do
      segments = Path.split(relative)

      refute ".ptc" in segments, "#{name} embeds a run artifact: #{relative}"
      refute List.last(segments) == ".env", "#{name} embeds a local environment file"
    end
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
