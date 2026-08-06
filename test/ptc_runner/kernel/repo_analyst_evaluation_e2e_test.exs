defmodule PtcRunner.Kernel.RepoAnalystEvaluationE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  Proves the shipped replay recipe as ordinary application configuration.

  Baseline and candidate are separate Kernel builds with separate replay and
  MCP owners. The trusted jq join binds each validated trial value to its own
  canonical run-started metadata, then the provider-free aggregate consumes
  only those joined records.
  """

  @moduletag :e2e
  @moduletag timeout: 120_000

  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.ValueContract

  @root Path.expand("../../..", __DIR__)
  @replay_manifest Path.join(@root, "repo-analyst-evaluate-replay.json")
  @aggregate_manifest Path.join(@root, "repo-analyst-aggregate.json")
  @host Path.join(@root, "repo-analyst.host.json")
  @evaluation_host Path.join(@root, "repo-analyst-evaluation.host.json")
  @base_source Path.join(@root, "priv/preludes/kernel/agent.core.clj")
  @trial_input Path.join(@root, "repo-analyst/trial-input.json")
  @join Path.join(@root, "repo-analyst/join-trial.jq")

  test "fresh baseline and candidate replay runs join and aggregate deterministically" do
    pair = prepare_pair(&(&1 <> "\n;; deterministic replay wiring candidate\n"))
    {baseline_joined, candidate_joined} = run_pair(@replay_manifest, pair)
    assert_pair_contract(pair, baseline_joined, candidate_joined)
    assert baseline_joined["passed"]
    assert candidate_joined["passed"]

    evaluation = aggregate_pair(pair.directory, baseline_joined, candidate_joined)
    assert evaluation.value["verdict"] == "inconclusive"
    assert evaluation.value["counts"] == %{"trials" => 2, "baseline" => 1, "candidate" => 1}
    assert_join_rejects_crossed_artifacts(pair)
    assert_join_rejects_unread_citation(pair)
  end

  test "deterministic replay detects a behavior-changing candidate" do
    pair =
      prepare_pair(fn base ->
        before = "(returned-outcome (get evaluation :value))"
        replacement = ~S|(returned-outcome (assoc (get evaluation :value) "citations" []))|
        assert String.contains?(base, before)
        String.replace(base, before, replacement)
      end)

    {baseline_joined, candidate_joined} = run_pair(@replay_manifest, pair)
    assert_pair_contract(pair, baseline_joined, candidate_joined)
    assert baseline_joined["passed"]
    refute candidate_joined["passed"]
    assert candidate_joined["detail"] == "did not cite lib/zz_beacon.ex"

    evaluation = aggregate_pair(pair.directory, baseline_joined, candidate_joined)
    assert evaluation.value["verdict"] == "reject"
    assert evaluation.value["regressed_cases"] == ["motivating.paged-evidence"]
  end

  test "a candidate subject failure survives result persistence and trusted joining" do
    pair =
      prepare_pair(fn base ->
        before = "(returned-outcome (get evaluation :value))"
        replacement = "(subject-failure :model-program-failed :candidate-declined)"
        assert String.contains?(base, before)
        String.replace(base, before, replacement)
      end)

    {baseline_joined, candidate_joined} = run_pair(@replay_manifest, pair)
    assert_pair_contract(pair, baseline_joined, candidate_joined)
    assert baseline_joined["status"] == "scored"
    assert baseline_joined["passed"]
    assert candidate_joined["status"] == "subject-failure"
    assert candidate_joined["failure"] == %{"kind" => "model-program-failed"}
    refute candidate_joined["passed"]

    evaluation = aggregate_pair(pair.directory, baseline_joined, candidate_joined)
    assert evaluation.value["verdict"] == "reject"
    assert evaluation.value["regressed_cases"] == ["motivating.paged-evidence"]
  end

  test "the shipped replay manifest and dedicated host config run unchanged" do
    {:ok, host} = HostConfig.load(@evaluation_host)

    {:ok, registry} =
      HostInstallation.catalog(host)
      |> then(fn {:ok, catalog} ->
        HostInstallation.runtime_registry(host, catalog)
      end)

    assert {:ok, result} = RunBuilder.run(@replay_manifest, registry)
    assert result.value["status"] == "scored"
    assert result.value["passed"]
    assert result.value["detail"] == "cited lib/zz_beacon.ex"
  end

  defp prepare_pair(candidate_fun) do
    jq = System.find_executable("jq") || flunk("jq is required for the evaluation tutorial")
    directory = private_directory()
    on_exit(fn -> File.rm_rf!(directory) end)

    base = File.read!(@base_source)
    candidate = candidate_fun.(base)
    refute candidate == base
    base_hash = ComponentOverride.hash(base)
    candidate_hash = ComponentOverride.hash(candidate)

    candidate_path = Path.join(directory, "agent.core.candidate.clj")
    descriptor_path = Path.join(directory, "agent.core.override.json")
    File.write!(candidate_path, candidate)

    write_json(descriptor_path, %{
      "component_id" => "agent.core",
      "base_source_hash" => base_hash,
      "source_hash" => candidate_hash,
      "path" => Path.basename(candidate_path)
    })

    template = @trial_input |> File.read!() |> Jason.decode!()

    baseline_input =
      template
      |> put_in(["subject"], "baseline")
      |> put_in(["candidate", "base_source_hash"], base_hash)
      |> put_in(["candidate", "source_hash"], candidate_hash)

    candidate_input = put_in(baseline_input, ["subject"], "candidate")
    baseline_input_path = Path.join(directory, "baseline.input.json")
    candidate_input_path = Path.join(directory, "candidate.input.json")
    write_json(baseline_input_path, baseline_input)
    write_json(candidate_input_path, candidate_input)

    workspace = materialize_workspace(directory, get_in(baseline_input, ["case", "id"]))
    host_path = prepare_host(directory, workspace)
    {:ok, host} = HostConfig.load(host_path)

    {:ok, registry} =
      HostInstallation.catalog(host)
      |> then(fn {:ok, catalog} ->
        HostInstallation.runtime_registry(host, catalog)
      end)

    %{
      jq: jq,
      directory: directory,
      registry: registry,
      baseline_input_path: baseline_input_path,
      candidate_input_path: candidate_input_path,
      descriptor_path: descriptor_path,
      candidate_hash: candidate_hash
    }
  end

  defp run_pair(manifest, pair) do
    baseline_trace = Path.join(pair.directory, "baseline.private.jsonl")
    candidate_trace = Path.join(pair.directory, "candidate.private.jsonl")

    baseline =
      run_trial(manifest, pair.registry, pair.baseline_input_path, baseline_trace)

    candidate =
      run_trial(manifest, pair.registry, pair.candidate_input_path, candidate_trace,
        component_override_descriptor: pair.descriptor_path
      )

    {
      join(
        pair.jq,
        baseline,
        baseline_trace,
        String.replace_suffix(baseline_trace, ".jsonl", ".inspection.jsonl"),
        Path.join(pair.directory, "baseline.joined.json")
      ),
      join(
        pair.jq,
        candidate,
        candidate_trace,
        String.replace_suffix(candidate_trace, ".jsonl", ".inspection.jsonl"),
        Path.join(pair.directory, "candidate.joined.json")
      )
    }
  end

  defp assert_pair_contract(pair, baseline, candidate) do
    {:ok, trial_contract} =
      @root
      |> Path.join("repo-analyst/trial.schema.json")
      |> File.read!()
      |> Jason.decode!()
      |> ValueContract.compile()

    assert ValueContract.valid?(trial_contract, baseline)
    assert ValueContract.valid?(trial_contract, candidate)

    baseline_identity = baseline["run_identity"]
    candidate_identity = candidate["run_identity"]

    refute baseline_identity["run_id"] == candidate_identity["run_id"]

    refute baseline_identity["workflow_bundle_hash"] ==
             candidate_identity["workflow_bundle_hash"]

    assert baseline_identity["provider_snapshot_hashes"] ==
             candidate_identity["provider_snapshot_hashes"]

    assert baseline_identity["content_snapshot_hashes"] ==
             candidate_identity["content_snapshot_hashes"]

    assert baseline_identity["fixture_set_hash"] == candidate_identity["fixture_set_hash"]
    refute Map.has_key?(baseline_identity, "override_source_hash")
    assert candidate_identity["override_source_hash"] == pair.candidate_hash
  end

  defp aggregate_pair(directory, baseline, candidate) do
    trials_path = Path.join(directory, "trials.json")

    plan =
      @root
      |> Path.join("repo-analyst/aggregate-input.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("plan")

    write_json(trials_path, %{"trials" => [baseline, candidate], "plan" => plan})
    {:ok, empty_registry} = ProviderRegistry.new()

    assert {:ok, evaluation} =
             RunBuilder.run(@aggregate_manifest, empty_registry,
               private_mission: relative(trials_path)
             )

    evaluation
  end

  defp run_trial(manifest, registry, input_path, trace_path, opts \\ []) do
    inspection_path = String.replace_suffix(trace_path, ".jsonl", ".inspection.jsonl")

    opts =
      [
        private_mission: relative(input_path),
        trace: trace_path,
        inspect: inspection_path
      ] ++ opts

    case RunBuilder.run(manifest, registry, opts) do
      {:ok, result} ->
        assert File.regular?(inspection_path)
        result.value

      {:error, error} ->
        flunk("trial failed: #{inspect(error)}")
    end
  end

  defp join(jq, result, trace_path, inspection_path, output_path) do
    result_path = output_path <> ".result"
    {:ok, canonical} = DeterministicJSON.encode(result)
    File.write!(result_path, canonical)
    result_hash = "sha256:" <> Base.encode16(:crypto.hash(:sha256, canonical), case: :lower)

    {joined, 0} =
      System.cmd(
        jq,
        [
          "-n",
          "--arg",
          "result_hash",
          result_hash,
          "--slurpfile",
          "result",
          result_path,
          "--slurpfile",
          "trace",
          trace_path,
          "--slurpfile",
          "inspection",
          inspection_path,
          "-f",
          @join
        ],
        stderr_to_stdout: true
      )

    File.write!(output_path, joined)
    Jason.decode!(joined)
  end

  defp assert_join_rejects_crossed_artifacts(pair) do
    result_path = Path.join(pair.directory, "candidate.joined.json.result")
    trace_path = Path.join(pair.directory, "baseline.private.jsonl")
    inspection_path = Path.join(pair.directory, "baseline.private.inspection.jsonl")

    assert {message, status} = join_command(pair.jq, result_path, trace_path, inspection_path)
    assert status != 0
    assert message =~ "trial result digest does not match run-stopped"
  end

  defp assert_join_rejects_unread_citation(pair) do
    original_result = Path.join(pair.directory, "baseline.joined.json.result")
    original_trace = Path.join(pair.directory, "baseline.private.jsonl")
    inspection_path = Path.join(pair.directory, "baseline.private.inspection.jsonl")
    result_path = Path.join(pair.directory, "fabricated.result.json")
    trace_path = Path.join(pair.directory, "fabricated.trace.jsonl")

    result =
      original_result
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["citations", Access.at(0), "path"], "lib/not-read.ex")

    {:ok, canonical} = DeterministicJSON.encode(result)
    File.write!(result_path, canonical)
    result_hash = sha256(canonical)

    original_trace
    |> decode_jsonl()
    |> Enum.map(fn
      %{"type" => "run-stopped"} = event ->
        put_in(event, ["data", "result_hash"], result_hash)

      event ->
        event
    end)
    |> Enum.map_join("", &(Jason.encode!(&1) <> "\n"))
    |> then(&File.write!(trace_path, &1))

    assert {message, status} = join_command(pair.jq, result_path, trace_path, inspection_path)
    assert status != 0
    assert message =~ "trial citation is not backed by an exact workspace.read result"
  end

  defp join_command(jq, result_path, trace_path, inspection_path) do
    result_hash = result_path |> File.read!() |> sha256()

    System.cmd(
      jq,
      [
        "-n",
        "--arg",
        "result_hash",
        result_hash,
        "--slurpfile",
        "result",
        result_path,
        "--slurpfile",
        "trace",
        trace_path,
        "--slurpfile",
        "inspection",
        inspection_path,
        "-f",
        @join
      ],
      stderr_to_stdout: true
    )
  end

  # The trial input is passed to the run as an application logical name, and
  # those are lowercase by grammar, so the suffix must be too. Base64 emits
  # upper-case bytes and made this directory an invalid name in all but a
  # fraction of runs.
  defp private_directory do
    suffix = Base.encode32(:crypto.strong_rand_bytes(9), case: :lower, padding: false)

    path =
      Path.join(
        @root,
        "tmp/repo-analyst-evaluation-#{suffix}"
      )

    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp materialize_workspace(directory, case_id) do
    workspace = Path.join(directory, "workspace")

    motivating =
      @root
      |> Path.join("repo-analyst/evaluation/motivating.json")
      |> File.read!()
      |> Jason.decode!()

    kase = Enum.find(motivating["cases"], &(&1["id"] == case_id))

    for {relative, content} <- kase["workspace_fixture"] do
      path = Path.join(workspace, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    workspace
  end

  defp prepare_host(directory, workspace) do
    document = @host |> File.read!() |> Jason.decode!()
    args = get_in(document, ["install", "workspace", "transport", "args"])
    root_index = Enum.find_index(args, &(&1 == "--root"))
    args = List.replace_at(args, root_index + 1, workspace)

    document =
      document
      |> put_in(["install", "workspace", "transport", "cwd"], @root)
      |> put_in(["install", "workspace", "transport", "args"], args)
      |> put_in(["install", "replay-llm", "fixtures"], "replay.jsonl")

    File.cp!(
      Path.join(@root, "repo-analyst/evaluation/replay.jsonl"),
      Path.join(directory, "replay.jsonl")
    )

    path = Path.join(directory, "repo-analyst.host.json")
    write_json(path, document)
    path
  end

  defp relative(path), do: Path.relative_to(path, @root)
  defp write_json(path, value), do: File.write!(path, Jason.encode!(value))

  defp decode_jsonl(path) do
    path
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
  end

  defp sha256(value),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)
end
