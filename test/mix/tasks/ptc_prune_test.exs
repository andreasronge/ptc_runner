defmodule Mix.Tasks.PtcPruneTest do
  use ExUnit.Case, async: true
  @moduletag :operator

  alias PtcRunner.MixCommandAdapter

  @tag :tmp_dir
  test "age, size, keep markers, and dry run operate on whole runs", %{tmp_dir: directory} do
    {project, root} = project!(directory)
    old = artifact_set!(root, "old", 20, 30)
    ancient = artifact_set!(root, "ancient", 30, 5)
    middle = artifact_set!(root, "middle", 10, 20)
    recent = artifact_set!(root, "recent", 1, 10)
    File.write!(Path.join([root, "keep", "old"]), "")
    File.write!(Path.join([root, "keep", "missing"]), "")
    unknown = Path.join([root, "results", "not a run.json"])
    File.write!(unknown, "unrelated")

    dry = MixCommandAdapter.execute(["prune", project, "--max-age-days", "5", "--dry-run"])
    assert dry.exit_status == 0
    assert Jason.decode!(dry.stdout)["deleted"] == ["ancient", "middle"]
    assert Enum.all?(ancient, &File.exists?/1)
    assert Enum.all?(middle, &File.exists?/1)
    assert Jason.decode!(dry.stdout)["dangling_keep_markers"] == ["missing"]

    real = MixCommandAdapter.execute(["prune", project, "--max-age-days", "5"])
    assert Jason.decode!(real.stdout)["deleted"] == ["ancient", "middle"]
    assert Enum.all?(old ++ recent, &File.exists?/1)
    assert Enum.all?(ancient ++ middle, &(not File.exists?(&1)))

    size = MixCommandAdapter.execute(["prune", project, "--max-bytes", "40"])
    assert Jason.decode!(size.stdout)["deleted"] == ["recent"]
    assert Jason.decode!(size.stdout)["remaining_bytes"] == 120
    assert Jason.decode!(size.stdout)["kept_exceeds_max_bytes"] == true
    assert Enum.all?(old, &File.exists?/1)
    assert File.exists?(Path.join([root, "keep", "old"]))
    assert File.read!(unknown) == "unrelated"
  end

  @tag :tmp_dir
  test "size deletes oldest unkept runs until the total fits", %{tmp_dir: directory} do
    {project, root} = project!(directory)
    oldest = artifact_set!(root, "oldest", 30, 10)
    next = artifact_set!(root, "next", 20, 10)
    newest = artifact_set!(root, "newest", 10, 10)

    result = MixCommandAdapter.execute(["prune", project, "--max-bytes", "50"])
    assert result.exit_status == 0
    assert Jason.decode!(result.stdout)["deleted"] == ["oldest", "next"]
    assert Enum.all?(oldest ++ next, &(not File.exists?(&1)))
    assert Enum.all?(newest, &File.exists?/1)
  end

  @tag :tmp_dir
  test "both trace variants are removed with their run", %{tmp_dir: directory} do
    {project, root} = project!(directory)
    paths = artifact_set!(root, "old", 20, 1)
    private = Path.join([root, "traces", "old.private.jsonl"])
    File.write!(private, "private")
    File.touch!(private, System.os_time(:second) - 20 * 86_400)

    result = MixCommandAdapter.execute(["prune", project, "--max-age-days", "1"])
    assert result.exit_status == 0
    assert Jason.decode!(result.stdout)["deleted"] == ["old"]
    assert Enum.all?([private | paths], &(not File.exists?(&1)))
  end

  @tag :tmp_dir
  test "in progress runs are skipped and unsafe directories are refused", %{tmp_dir: directory} do
    {project, root} = project!(directory)
    staged = artifact_set!(root, "staged", 20, 1)
    fresh = artifact_set!(root, "fresh", 0, 1)
    File.write!(hd(staged) <> ".ptc-tmp-abc", "pending")

    result = MixCommandAdapter.execute(["prune", project, "--max-bytes", "0"])
    assert result.exit_status == 0

    assert Jason.decode!(result.stdout)["skipped"] == [
             %{"run_ref" => "fresh", "reason" => "in_progress"},
             %{"run_ref" => "staged", "reason" => "in_progress"}
           ]

    assert Enum.all?(staged ++ fresh, &File.exists?/1)

    traces = Path.join(root, "traces")
    File.chmod!(traces, 0o770)
    refused = MixCommandAdapter.execute(["prune", project, "--max-bytes", "0"])
    assert refused.exit_status != 0
    assert refused.stdout == ""
    assert refused.stderr =~ "prune/prune_unsafe_directory"
  end

  @tag :tmp_dir
  test "a limit is required", %{tmp_dir: directory} do
    {project, root} = project!(directory)
    paths = artifact_set!(root, "old", 20, 1)
    result = MixCommandAdapter.execute(["prune", project])
    assert result.exit_status == 2
    assert Enum.all?(paths, &File.exists?/1)
  end

  @tag :tmp_dir
  test "a symlinked artifact directory is refused without touching its target", %{
    tmp_dir: directory
  } do
    {project, root} = project!(directory)
    traces = Path.join(root, "traces")
    outside = Path.join(directory, "outside")
    File.mkdir!(outside)
    File.chmod!(outside, 0o700)
    File.rmdir!(traces)
    File.ln_s!(outside, traces)
    target = Path.join(outside, "old.jsonl")
    File.write!(target, "evidence")

    result = MixCommandAdapter.execute(["prune", project, "--max-bytes", "0"])
    assert result.exit_status != 0
    assert result.stderr =~ "prune/prune_unsafe_directory"
    assert File.read!(target) == "evidence"
  end

  defp project!(directory) do
    target = Path.join(directory, "demo")
    assert MixCommandAdapter.execute(["init", target]).exit_status == 0
    project = Path.join(target, "ptc-project.json")
    root = Path.join(target, ".ptc")

    for child <- ~w(traces inspection results envelopes keep) do
      File.mkdir_p!(Path.join(root, child))
      File.chmod!(Path.join(root, child), 0o700)
    end

    File.chmod!(root, 0o700)
    {project, root}
  end

  defp artifact_set!(root, ref, days, bytes) do
    paths = [
      Path.join([root, "traces", ref <> ".jsonl"]),
      Path.join([root, "inspection", ref <> ".ptcins"]),
      Path.join([root, "results", ref <> ".json"]),
      Path.join([root, "envelopes", ref <> ".json"])
    ]

    for path <- paths do
      File.write!(path, :binary.copy("x", bytes))
      File.touch!(path, System.os_time(:second) - days * 86_400)
    end

    paths
  end
end
