defmodule PtcRunner.Kernel.CommandInitializerTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandInitializer
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.ProjectConfig

  @run_ref CommandRunRef.encode(<<0::128>>)

  @main_clj """
  (ns main)

  (defn run [input]
    (return {"greeting" (str "hello " (get input "name"))}))
  """

  @manifest """
  {
    "version": 1,
    "workflow": {
      "components": [
        {
          "id": "main",
          "path": "main.clj"
        }
      ],
      "entry": "main/run"
    },
    "input": {
      "value": {"name": "world"}
    }
  }
  """

  @tag :tmp_dir
  test "init publishes the exact validated scaffold and private-artifact ignores", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "application")

    assert {:ok, %CommandOutcome{} = outcome} = CommandEngine.dispatch(["init", target])

    assert outcome.envelope["result"] == %{
             "created" => [".gitignore", "main.clj", "ptc.json", "ptc-project.json"]
           }

    assert File.read!(Path.join(target, "main.clj")) == @main_clj
    assert File.read!(Path.join(target, "ptc.json")) == @manifest

    assert File.read!(Path.join(target, ".gitignore")) ==
             ".ptc/\n.ptc-private-*\n.ptc-private-result-*\n"

    assert {:ok, project} =
             ProjectConfig.load(Path.join(target, "ptc-project.json"))

    assert project.application == Path.join(target, "ptc.json")

    assert Enum.sort(File.ls!(target)) == [
             ".gitignore",
             "main.clj",
             "ptc-project.json",
             "ptc.json"
           ]

    assert {:ok, root} =
             JSV.build(CommandContract.schema(), atoms: false, warnings: :silent)

    assert {:ok, _validated} = JSV.validate(outcome.envelope, root, cast: false)
  end

  @tag :tmp_dir
  test "init collisions preserve the existing directory and clean unpublished staging", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "application")
    File.mkdir!(target)
    sentinel = Path.join(target, "keep.txt")
    File.write!(sentinel, "existing")

    assert_initialization_error(
      CommandEngine.dispatch(["init", target]),
      "initialization_target_exists"
    )

    assert File.read!(sentinel) == "existing"
    assert File.ls!(target) == ["keep.txt"]

    file_target = Path.join(directory, "existing-file")
    File.write!(file_target, "existing")

    assert_initialization_error(
      CommandEngine.dispatch(["init", file_target]),
      "initialization_target_exists"
    )

    assert File.read!(file_target) == "existing"
    assert staging_entries(directory) == []
  end

  @tag :tmp_dir
  test "init never follows or replaces a target symlink", %{tmp_dir: directory} do
    target = Path.join(directory, "application")
    destination = Path.join(directory, "destination")
    File.mkdir!(destination)
    sentinel = Path.join(destination, "keep.txt")
    File.write!(sentinel, "existing")
    File.ln_s!(destination, target)

    assert_initialization_error(
      CommandEngine.dispatch(["init", target]),
      "initialization_target_exists"
    )

    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(target)
    assert File.read!(sentinel) == "existing"
    assert staging_entries(directory) == []
  end

  @tag :tmp_dir
  test "absolute targets with trailing separators stage beside the normalized target", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "application")

    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target <> "/"])
    assert_exact_scaffold(target)
    assert staging_entries(directory) == []

    sentinel = Path.join(target, "keep.txt")
    File.write!(sentinel, "existing")

    assert_initialization_error(
      CommandEngine.dispatch(["init", target <> "//"]),
      "initialization_target_exists"
    )

    assert File.read!(sentinel) == "existing"
    assert staging_entries(directory) == []
  end

  @tag :tmp_dir
  test "init distinguishes a missing parent from an unusable parent", %{tmp_dir: directory} do
    missing_parent_target = Path.join([directory, "missing", "application"])

    assert_initialization_error(
      CommandEngine.dispatch(["init", missing_parent_target]),
      "initialization_parent_missing"
    )

    unusable_parent = Path.join(directory, "not-a-directory")
    File.write!(unusable_parent, "existing")

    assert_initialization_error(
      CommandEngine.dispatch(["init", Path.join(unusable_parent, "application")]),
      "initialization_parent_unusable"
    )
  end

  @tag :tmp_dir
  test "trailing normalization preserves parent symlink and dot-dot filesystem semantics", %{
    tmp_dir: directory
  } do
    physical_parent = Path.join(directory, "physical")
    nested = Path.join(physical_parent, "nested")
    File.mkdir_p!(nested)
    link = Path.join(directory, "link")
    File.ln_s!(nested, link)

    requested = Path.join([link, "..", "application"]) <> "/"
    physical_target = Path.join(physical_parent, "application")
    lexical_target = Path.join(directory, "application")

    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", requested])
    assert_exact_scaffold(physical_target)
    refute File.exists?(lexical_target)
    assert staging_entries(physical_parent) == []
  end

  @tag :tmp_dir
  test "a partial child write rolls back only owned staging and permits a clean retry", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "application")

    fault = fn
      {:during_child_write, "ptc.json"}, _context -> {:error, :partial_write}
      _stage, _context -> :ok
    end

    assert_initialization_failed(
      CommandInitializer.initialize(target, @run_ref, fault_hook: fault)
    )

    refute File.exists?(target)
    assert staging_entries(directory) == []

    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    assert_exact_scaffold(target)
  end

  @tag :tmp_dir
  test "uncertain staging ownership is left untouched and never published", %{tmp_dir: directory} do
    target = Path.join(directory, "application")
    test_process = self()

    fault = fn
      :before_publish, %{staging: staging} ->
        original = staging <> ".original"
        File.rename!(staging, original)
        File.mkdir!(staging)
        File.chmod!(staging, 0o700)
        File.write!(Path.join(staging, "replacement.txt"), "replacement")
        send(test_process, {:replaced_staging, staging, original})
        :ok

      _stage, _context ->
        :ok
    end

    assert_initialization_failed(
      CommandInitializer.initialize(target, @run_ref, fault_hook: fault)
    )

    assert_receive {:replaced_staging, replacement, original}
    refute File.exists?(target)
    assert File.read!(Path.join(replacement, "replacement.txt")) == "replacement"
    assert_exact_scaffold(original)

    File.rm_rf!(replacement)
    File.rm_rf!(original)
  end

  @tag :tmp_dir
  test "unsupported no-replace publication cleans staging without touching the target", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "application")
    publisher = fn _staging, _target -> {:error, :unsupported_platform} end

    assert_initialization_failed(
      CommandInitializer.initialize(target, @run_ref, publisher: publisher)
    )

    refute File.exists?(target)
    assert staging_entries(directory) == []
  end

  @tag :tmp_dir
  test "a target that appears at the publication commit is classified as existing", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "application")
    publisher = fn _staging, _target -> {:error, :collision} end

    assert_initialization_error(
      CommandInitializer.initialize(target, @run_ref, publisher: publisher),
      "initialization_target_exists"
    )

    refute File.exists?(target)
    assert staging_entries(directory) == []
  end

  @tag :tmp_dir
  test "a committed publication survives an indeterminate launcher status", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "application")

    publisher = fn staging, ^target ->
      File.rename!(staging, target)
      {:error, :publication_status_unknown}
    end

    assert {:ok, %CommandOutcome{}} =
             CommandInitializer.initialize(target, @run_ref, publisher: publisher)

    assert_exact_scaffold(target)
    assert staging_entries(directory) == []
  end

  @tag :tmp_dir
  test "an indeterminate status without a commit cleans owned staging", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "application")
    publisher = fn _staging, ^target -> {:error, :publication_status_unknown} end

    assert_initialization_failed(
      CommandInitializer.initialize(target, @run_ref, publisher: publisher)
    )

    refute File.exists?(target)
    assert staging_entries(directory) == []
  end

  @tag :tmp_dir
  test "the publication commit survives later frontend failure", %{tmp_dir: directory} do
    target = Path.join(directory, "application")

    assert_raise RuntimeError, "frontend output failed", fn ->
      assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
      raise "frontend output failed"
    end

    assert_exact_scaffold(target)
  end

  @tag :tmp_dir
  test "concurrent initializers have exactly one no-replace winner", %{tmp_dir: directory} do
    target = Path.join(directory, "application")

    results =
      1..4
      |> Task.async_stream(
        fn _index -> CommandEngine.dispatch(["init", target]) end,
        max_concurrency: 4,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %CommandOutcome{}}, &1)) == 1
    assert Enum.count(results, &match?({:error, %CommandOutcome{}}, &1)) == 3
    assert_exact_scaffold(target)
    assert staging_entries(directory) == []
  end

  defp assert_initialization_failed(result),
    do: assert_initialization_error(result, "initialization_failed")

  defp assert_initialization_error({:error, %CommandOutcome{} = outcome}, code) do
    assert outcome.envelope["error"]["phase"] == "publication"
    assert outcome.envelope["error"]["code"] == code
    assert outcome.envelope["error"]["provider_activity"] == false
    assert outcome.envelope["error"]["path"] == nil
    assert outcome.envelope["error"]["source"] == nil
    outcome
  end

  defp assert_exact_scaffold(target) do
    assert File.read!(Path.join(target, "main.clj")) == @main_clj
    assert File.read!(Path.join(target, "ptc.json")) == @manifest

    assert {:ok, _project} =
             ProjectConfig.load(Path.join(target, "ptc-project.json"))

    assert Enum.sort(File.ls!(target)) == [
             ".gitignore",
             "main.clj",
             "ptc-project.json",
             "ptc.json"
           ]
  end

  defp staging_entries(directory) do
    directory
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, ".ptc-private-"))
  end
end
