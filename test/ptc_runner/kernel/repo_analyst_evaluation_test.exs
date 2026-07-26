defmodule PtcRunner.Kernel.RepoAnalystEvaluationTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Covers the `repo-analyst` evaluation half: the trial contracts, the isolated
  evaluator, and the provider-free aggregate.

  The aggregate is exercised by running it, not by reading it. Its whole job is
  to refuse a candidate that looks good on the cases its own author cited, and
  that judgement only exists once the counting actually happens.
  """

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Kernel.WorkflowEnvironment

  @root Path.expand("../../..", __DIR__)
  @candidate %{
    "component_id" => "agent.core",
    "base_source_hash" => "sha256:base",
    "source_hash" => "sha256:candidate"
  }

  describe "components" do
    test "the evaluator declares agent.core and compiles through library resolution" do
      {:ok, manifest} = Manifest.load(path("repo-analyst-evaluate-replay.json"))
      evaluate = Enum.find(manifest.workflow_components, &(&1.id == "evaluate"))

      # The override replaces this dependency before the bundle compiles, so a
      # candidate trial is an ordinary run that names the same component.
      assert "agent.core" in evaluate.dependencies
      assert manifest.entry == "evaluate/run"
      assert {:ok, _bundle} = Kernel.compile_bundle(manifest.workflow_components)
    end

    test "the aggregate selects no provider at all" do
      {:ok, manifest} = Manifest.load(path("repo-analyst-aggregate.json"))

      assert manifest.providers.workflow == []
      assert manifest.providers.mission == []
      assert manifest.mission_components == []

      # A component that could reach a model could re-run a trial rather than
      # count it, which would make its verdict another opinion.
      {:ok, bundle} = Kernel.compile_bundle(manifest.workflow_components)
      refute inspect(bundle.prelude.exports) =~ "llm-request"
    end

    test "each trial manifest selects exactly one workflow LLM" do
      for {name, provider} <- [
            {"repo-analyst-evaluate-replay.json", "replay-llm"},
            {"repo-analyst-evaluate-live.json", "deepseek"}
          ] do
        {:ok, manifest} = Manifest.load(path(name))
        assert Enum.map(manifest.providers.workflow, & &1["name"]) == [provider]
      end
    end
  end

  describe "contracts" do
    test "every evaluation contract compiles through the bounded profile" do
      for name <- ~w(trial-input.schema.json trial.schema.json evaluation.schema.json) do
        assert {:ok, _contract} = contract(name), "#{name} is not a valid application contract"
      end
    end

    test "the committed example trial input validates against its own contract" do
      {:ok, contract} = contract("trial-input.schema.json")

      example =
        @root |> Path.join("repo-analyst/trial-input.json") |> File.read!() |> Jason.decode!()

      assert ValueContract.valid?(contract, example)
    end

    test "a trial input may not smuggle candidate source" do
      {:ok, contract} = contract("trial-input.schema.json")

      example =
        @root |> Path.join("repo-analyst/trial-input.json") |> File.read!() |> Jason.decode!()

      # Only the trusted override descriptor supplies candidate bytes. Source
      # arriving as ordinary input would put the subject under evaluation
      # inside the mission, where a generated program could read it.
      smuggled = put_in(example, ["candidate", "content"], "(ns agent.core)")
      refute ValueContract.valid?(contract, smuggled)
    end
  end

  describe "aggregation" do
    test "a candidate that regresses a held-out case is rejected" do
      assert %{"verdict" => "reject", "regressed_cases" => ["held.1"]} =
               aggregate([
                 trial("baseline", "cited.1", "motivating", false),
                 trial("candidate", "cited.1", "motivating", true),
                 trial("baseline", "held.1", "held-out", true),
                 trial("candidate", "held.1", "held-out", false)
               ])
    end

    test "a candidate that regresses a regression case is rejected" do
      assert %{"verdict" => "reject"} =
               aggregate([
                 trial("baseline", "cited.1", "motivating", false),
                 trial("candidate", "cited.1", "motivating", true),
                 trial("baseline", "reg.1", "regression", true),
                 trial("candidate", "reg.1", "regression", false)
               ])
    end

    test "a clean improvement is accepted and reports its rates" do
      assert %{"verdict" => "accept", "rates" => rates, "counts" => counts} =
               aggregate([
                 trial("baseline", "cited.1", "motivating", false),
                 trial("candidate", "cited.1", "motivating", true),
                 trial("baseline", "held.1", "held-out", true),
                 trial("candidate", "held.1", "held-out", true)
               ])

      assert rates["motivating_before"] == 0.0
      assert rates["motivating_after"] == 1.0
      assert rates["held_out_before"] == rates["held_out_after"]
      assert counts == %{"trials" => 4, "baseline" => 2, "candidate" => 2}
    end

    test "a candidate that improves nothing is inconclusive rather than accepted" do
      assert %{"verdict" => "inconclusive"} =
               aggregate([
                 trial("baseline", "cited.1", "motivating", true),
                 trial("candidate", "cited.1", "motivating", true)
               ])
    end

    test "a trial whose declared subject disagrees with its run identity is invalid" do
      # A candidate must carry an override source hash and a baseline must not.
      # Trusting the label alone would let a mislabelled artifact compare a run
      # against itself and report a perfect improvement.
      assert %{"verdict" => "invalid", "reasons" => reasons} =
               aggregate([
                 trial("baseline", "cited.1", "motivating", false),
                 trial("candidate", "cited.1", "motivating", true, override?: false)
               ])

      assert Enum.any?(reasons, &(&1 =~ "run identity"))
    end

    test "an unpaired case is invalid rather than counted as an improvement" do
      assert %{"verdict" => "invalid", "reasons" => reasons} =
               aggregate([
                 trial("baseline", "cited.1", "motivating", false),
                 trial("candidate", "cited.1", "motivating", true),
                 trial("candidate", "orphan.1", "motivating", true)
               ])

      assert Enum.any?(reasons, &(&1 =~ "unpaired"))
    end

    test "trials evaluating different candidates are invalid" do
      other = Map.put(@candidate, "source_hash", "sha256:other")

      assert %{"verdict" => "invalid", "reasons" => reasons} =
               aggregate([
                 trial("baseline", "cited.1", "motivating", false),
                 Map.put(trial("candidate", "cited.1", "motivating", true), "candidate", other)
               ])

      assert Enum.any?(reasons, &(&1 =~ "more than one candidate"))
    end

    test "an empty trial set fails rather than reporting an empty success" do
      assert {:error, _reason} = run_aggregate([])
    end

    test "every aggregate result validates against the shipped contract" do
      {:ok, contract} = contract("evaluation.schema.json")

      value =
        aggregate([
          trial("baseline", "cited.1", "motivating", false),
          trial("candidate", "cited.1", "motivating", true)
        ])

      assert ValueContract.valid?(contract, value)
    end
  end

  describe "negative controls" do
    test "the set checks the harness rather than the candidate" do
      data = case_set("negative-control")
      kinds = Enum.map(data["cases"], &get_in(&1, ["expect", "kind"]))

      assert data["case_set"] == "negative-control"
      assert length(data["cases"]) >= 3

      # One case every subject must pass and one every subject must fail. An
      # evaluation that scores everything as passing looks exactly like an
      # evaluation of a very good candidate, and only these separate them.
      assert "returns-value" in kinds
      assert Enum.any?(data["cases"], &(&1["id"] == "negative-control.always-fails"))

      for kase <- data["cases"] do
        assert is_binary(kase["task"]) and kase["task"] != ""
        assert is_map(kase["workspace_fixture"]) and map_size(kase["workspace_fixture"]) > 0
        assert is_binary(get_in(kase, ["expect", "reason"]))
      end
    end

    test "every case set the evaluator consumes uses a kind the trial contract allows" do
      {:ok, contract} = contract("trial-input.schema.json")

      template =
        @root |> Path.join("repo-analyst/trial-input.json") |> File.read!() |> Jason.decode!()

      for set <- ~w(motivating regression held-out negative-control),
          kase <- case_set(set)["cases"] do
        input =
          template
          |> put_in(["case", "id"], kase["id"])
          |> put_in(["case", "set"], set)
          |> put_in(["case", "task"], kase["task"])
          |> put_in(["case", "expect"], kase["expect"])

        assert ValueContract.valid?(contract, input),
               "#{kase["id"]} cannot be turned into a trial input: " <>
                 "expect.kind #{inspect(get_in(kase, ["expect", "kind"]))} is not accepted"
      end
    end
  end

  defp path(name), do: Path.join(@root, name)

  defp case_set(name) do
    @root |> Path.join("repo-analyst/evaluation/#{name}.json") |> File.read!() |> Jason.decode!()
  end

  defp contract(name) do
    @root
    |> Path.join("repo-analyst/#{name}")
    |> File.read!()
    |> Jason.decode!()
    |> ValueContract.compile()
  end

  defp trial(subject, id, set, passed?, opts \\ []) do
    override? = Keyword.get(opts, :override?, subject == "candidate")

    identity =
      %{"workflow_bundle_hash" => "sha256:bundle", "provider_snapshot_hashes" => ["sha256:p"]}
      |> then(fn base ->
        if override?, do: Map.put(base, "override_source_hash", "sha256:candidate"), else: base
      end)

    %{
      "subject" => subject,
      "repetition" => 1,
      "candidate" => @candidate,
      "case" => %{"id" => id, "set" => set, "case_hash" => "sha256:case"},
      "passed" => passed?,
      "detail" => "synthetic",
      "run_identity" => identity
    }
  end

  defp aggregate(trials) do
    {:ok, result} = run_aggregate(trials)
    result.value
  end

  # Runs the shipped aggregate component exactly as its manifest would, with no
  # provider of any kind.
  defp run_aggregate(trials) do
    {:ok, component} =
      Component.new(
        id: "aggregate",
        source: File.read!(Path.join(@root, "repo-analyst/aggregate.clj")),
        origin: "file"
      )

    {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)

    {:ok, sink} =
      EventSink.start(:normal, limits, run_id: "aggregate-#{System.unique_integer([:positive])}")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{"input" => %{"trials" => trials}},
        limits: limits,
        event_sink: sink
      )

    Kernel.run("(aggregate/run data/input)", config)
  after
    :ok = ensure_library_loaded()
  end

  defp ensure_library_loaded, do: Library.component("cap") |> elem(0) && :ok
end
