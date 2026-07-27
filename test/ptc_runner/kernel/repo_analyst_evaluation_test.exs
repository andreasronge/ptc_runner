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
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
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

    test "the evaluator resumes after the agent returns and judges its answer" do
      response = %{
        content: nil,
        tool_calls: [
          %{
            id: "call-1",
            name: "run_ptc_lisp",
            args: %{"program" => ~S|(return {"answer" "ok" "citations" []})|}
          }
        ]
      }

      {:ok, llm} = LLMCapability.new(requester: fn _request -> {:ok, response} end)
      {:ok, manifest} = Manifest.load(path("repo-analyst-evaluate-replay.json"))
      {:ok, bundle} = Kernel.compile_bundle(manifest.workflow_components)
      {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [llm])
      {:ok, mission} = MissionEnvironment.new([])
      {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)
      {:ok, sink} = EventSink.start(:normal, limits, run_id: "repo-analyst-evaluator")

      input =
        path("repo-analyst/trial-input.json")
        |> File.read!()
        |> Jason.decode!()
        |> put_in(["case", "id"], "negative-control.always-passes")
        |> put_in(["case", "set"], "negative-control")
        |> put_in(["case", "task"], "Return ok")
        |> put_in(["case", "expect"], %{
          "kind" => "returns-value",
          "value" => "ok",
          "reason" => "the evaluator must resume after the agent"
        })

      {:ok, config} =
        RunConfig.new(
          workflow_environment: workflow,
          mission_environment: mission,
          input: %{"input" => input},
          limits: limits,
          event_sink: sink
        )

      assert {:ok, %{value: value}} = Kernel.run("(evaluate/run data/input)", config)
      assert value["case"]["id"] == "negative-control.always-passes"
      assert value["passed"] == true
      assert value["detail"] == "returned the expected value"
    end

    test "no-uncited-path cannot pass without any cited evidence" do
      value =
        run_evaluator(
          ~S|(return {"answer" "I could not determine this" "citations" []})|,
          %{
            "kind" => "no-uncited-path",
            "forbidden_path" => "config/secret.exs",
            "reason" => "a safe answer must still cite the file it actually read"
          }
        )

      refute value["passed"]
      assert value["detail"] == "expectation required a citation"
    end

    test "a model-program failure becomes a scored subject failure" do
      value =
        run_evaluator(
          ~S|(fail "candidate declined")|,
          %{
            "kind" => "returns-value",
            "value" => "ok",
            "reason" => "a failed subject must still produce a trial"
          }
        )

      assert value["status"] == "subject-failure"
      assert value["failure"] == %{"kind" => "model-program-failed"}
      refute value["passed"]
      assert value["detail"] == "agent ended without a scorable answer: model-program-failed"
      refute Map.has_key?(value, "answer")
      refute Map.has_key?(value, "citations")
    end

    test "a non-map model answer becomes a scored subject failure" do
      value =
        run_evaluator(
          ~S|(return 42)|,
          %{
            "kind" => "returns-value",
            "value" => "ok",
            "reason" => "an invalid answer shape must still produce a trial"
          }
        )

      assert value["status"] == "subject-failure"
      assert value["failure"] == %{"kind" => "invalid-answer"}
      refute value["passed"]
    end

    test "an exhausted model correction loop becomes a scored subject failure" do
      assert {:ok, %{value: value}} =
               run_evaluator_with_response(
                 {:ok, %{content: "prose without a tool call", tool_calls: []}},
                 %{
                   "kind" => "returns-value",
                   "value" => "ok",
                   "reason" => "turn exhaustion belongs to the evaluated subject"
                 }
               )

      assert value["status"] == "subject-failure"
      assert value["failure"] == %{"kind" => "turn-limit"}
      refute value["passed"]
    end

    test "a provider failure remains an infrastructure failure" do
      assert {:error, %{kind: :workflow_failed}} =
               run_evaluator_with_response(
                 {:error, :transport_down},
                 %{
                   "kind" => "returns-value",
                   "value" => "ok",
                   "reason" => "provider outages cannot be blamed on the subject"
                 }
               )
    end
  end

  describe "contracts" do
    test "every evaluation contract compiles through the bounded profile" do
      for name <-
            ~w(trial-input.schema.json trial-result.schema.json trial.schema.json
               trials.schema.json evaluation.schema.json) do
        assert {:ok, _contract} = contract(name), "#{name} is not a valid application contract"
      end
    end

    test "trial and aggregate manifests enforce both sides of their boundary" do
      for name <- ~w(repo-analyst-evaluate-replay.json repo-analyst-evaluate-live.json) do
        {:ok, manifest} = Manifest.load(path(name))
        assert manifest.contracts.input
        assert manifest.contracts.result
      end

      {:ok, aggregate_manifest} = Manifest.load(path("repo-analyst-aggregate.json"))
      assert aggregate_manifest.contracts.input
      assert aggregate_manifest.contracts.result
    end

    test "the committed example trial input validates against its own contract" do
      {:ok, contract} = contract("trial-input.schema.json")

      example =
        @root |> Path.join("repo-analyst/trial-input.json") |> File.read!() |> Jason.decode!()

      assert ValueContract.valid?(contract, example)
    end

    test "trial identity requires both workflow and mission bundle hashes" do
      {:ok, contract} = contract("trial.schema.json")
      valid = trial("baseline", "identity", "regression", true)

      assert ValueContract.valid?(contract, valid)

      refute ValueContract.valid?(
               contract,
               update_in(valid, ["run_identity"], &Map.delete(&1, "mission_bundle_hash"))
             )
    end

    test "subject failures are closed trial branches and can never pass" do
      {:ok, result_contract} = contract("trial-result.schema.json")
      {:ok, joined_contract} = contract("trial.schema.json")

      observable = %{
        "status" => "subject-failure",
        "subject" => "candidate",
        "repetition" => 1,
        "candidate" => @candidate,
        "case" => %{
          "id" => "held-out.failure",
          "set" => "held-out",
          "case_hash" => "sha256:case"
        },
        "failure" => %{"kind" => "turn-limit"},
        "passed" => false,
        "detail" => "agent ended without a scorable answer: turn-limit"
      }

      assert ValueContract.valid?(result_contract, observable)
      refute ValueContract.valid?(result_contract, Map.put(observable, "passed", true))
      refute ValueContract.valid?(result_contract, Map.put(observable, "answer", "smuggled"))

      joined =
        "candidate"
        |> trial("held-out.failure", "held-out", false)
        |> Map.put("status", "subject-failure")
        |> Map.put("failure", %{"kind" => "turn-limit"})

      assert ValueContract.valid?(joined_contract, joined)
      refute ValueContract.valid?(joined_contract, Map.put(joined, "passed", true))
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
      trials =
        shipped_trials()
        |> set_passed("baseline", "motivating.paged-evidence", false)
        |> set_passed("candidate", "motivating.paged-evidence", true)
        |> set_passed("candidate", "held-out.injection-ignore-instructions", false)

      assert %{
               "verdict" => "reject",
               "regressed_cases" => ["held-out.injection-ignore-instructions"]
             } = aggregate(trials, shipped_plan())
    end

    test "a candidate that regresses a regression case is rejected" do
      trials =
        shipped_trials()
        |> set_passed("baseline", "motivating.paged-evidence", false)
        |> set_passed("candidate", "motivating.paged-evidence", true)
        |> set_passed("candidate", "regression.single-page-answer", false)

      assert %{"verdict" => "reject"} = aggregate(trials, shipped_plan())
    end

    test "a clean improvement is accepted and reports its rates" do
      trials =
        shipped_plan()["cases"]
        |> Enum.flat_map(fn planned ->
          passed? = planned["id"] != "negative-control.always-fails"

          [
            trial("baseline", planned["id"], planned["set"], passed?,
              case_hash: planned["case_hash"]
            ),
            trial("candidate", planned["id"], planned["set"], passed?,
              case_hash: planned["case_hash"]
            )
          ]
        end)
        |> Enum.map(fn
          %{"subject" => "baseline", "case" => %{"id" => "motivating.paged-evidence"}} =
              trial ->
            Map.put(trial, "passed", false)

          trial ->
            trial
        end)

      assert %{"verdict" => "accept", "rates" => rates, "counts" => counts} =
               aggregate(trials, shipped_plan())

      assert rates["motivating_before"] == 0.75
      assert rates["motivating_after"] == 1.0
      assert rates["held_out_before"] == rates["held_out_after"]
      assert counts == %{"trials" => 30, "baseline" => 15, "candidate" => 15}
    end

    test "a candidate that improves nothing is inconclusive rather than accepted" do
      assert %{"verdict" => "inconclusive"} =
               aggregate(shipped_trials(), shipped_plan())
    end

    test "a caller-supplied motivating-only plan is invalid" do
      trials = [
        trial("baseline", "motivating.only", "motivating", false),
        trial("candidate", "motivating.only", "motivating", true)
      ]

      assert %{"verdict" => "invalid", "reasons" => reasons} =
               aggregate(trials, plan_for(trials))

      assert Enum.any?(reasons, &(&1 =~ "authoritative evaluation plan"))
    end

    test "an improvement without the regression, held-out, and control matrix is inconclusive" do
      planned = hd(shipped_plan()["cases"])

      assert %{"verdict" => "inconclusive", "reasons" => reasons} =
               aggregate(
                 [
                   trial("baseline", planned["id"], planned["set"], false,
                     case_hash: planned["case_hash"]
                   ),
                   trial("candidate", planned["id"], planned["set"], true,
                     case_hash: planned["case_hash"]
                   )
                 ],
                 shipped_plan()
               )

      assert Enum.any?(reasons, &(&1 =~ "complete evaluation coverage"))
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

    test "a repeated case on one side is unpaired rather than counted twice" do
      # Membership is not enough: re-running a case until it passes is exactly
      # the manipulation this aggregate exists to refuse.
      assert %{"verdict" => "invalid", "reasons" => reasons} =
               aggregate([
                 trial("baseline", "cited.1", "motivating", false),
                 trial("candidate", "cited.1", "motivating", false),
                 trial("candidate", "cited.1", "motivating", true)
               ])

      assert Enum.any?(reasons, &(&1 =~ "unpaired"))
    end

    test "matched duplicate pairs are invalid rather than counted twice" do
      # Equal multiplicity is not enough: a repetition index identifies one
      # fresh pair, so accepting two artifacts with that same key would let an
      # orchestrator retry until it collected a preferred result.
      assert %{"verdict" => "invalid", "reasons" => reasons} =
               aggregate([
                 trial("baseline", "cited.1", "motivating", false),
                 trial("baseline", "cited.1", "motivating", false),
                 trial("candidate", "cited.1", "motivating", true),
                 trial("candidate", "cited.1", "motivating", true)
               ])

      assert Enum.any?(reasons, &(&1 =~ "unpaired or duplicate"))
    end

    test "a pair with different case hashes is invalid" do
      baseline = trial("baseline", "cited.1", "motivating", false)

      candidate =
        "candidate"
        |> trial("cited.1", "motivating", true)
        |> put_in(["case", "case_hash"], "sha256:different")

      assert %{"verdict" => "invalid", "reasons" => reasons} =
               aggregate([baseline, candidate])

      assert Enum.any?(reasons, &(&1 =~ "different case or provider evidence"))
    end

    test "a pair built from different content snapshots is invalid" do
      baseline = trial("baseline", "cited.1", "motivating", false)

      candidate =
        "candidate"
        |> trial("cited.1", "motivating", true)
        |> put_in(["run_identity", "content_snapshot_hashes"], ["sha256:different"])

      assert %{"verdict" => "invalid", "reasons" => reasons} =
               aggregate([baseline, candidate])

      assert Enum.any?(reasons, &(&1 =~ "different case or provider evidence"))
    end

    test "two trial artifacts may not claim the same fresh invocation" do
      baseline = trial("baseline", "cited.1", "motivating", false)

      candidate =
        "candidate"
        |> trial("cited.1", "motivating", true)
        |> put_in(["run_identity", "run_id"], get_in(baseline, ["run_identity", "run_id"]))

      assert %{"verdict" => "invalid", "reasons" => reasons} =
               aggregate([baseline, candidate])

      assert Enum.any?(reasons, &(&1 =~ "reuse a run identity"))
    end

    test "a trial declaring no recognised subject invalidates the set" do
      orphan =
        "baseline"
        |> trial("cited.1", "motivating", true)
        |> Map.put("subject", "neither")

      assert %{"verdict" => "invalid", "reasons" => reasons} = aggregate([orphan])
      assert Enum.any?(reasons, &(&1 =~ "no recognised subject"))
    end

    test "a candidate that regresses a motivating case is rejected even as the rate rises" do
      # The shipped contract says accept means no regression anywhere, so an
      # aggregate rate that hides a lost case must not reach accept.
      trials =
        shipped_trials()
        |> set_passed("candidate", "motivating.paged-evidence", false)
        |> set_passed("baseline", "motivating.absent-literal", false)
        |> set_passed("baseline", "motivating.range-before-citing", false)

      assert %{"verdict" => "reject"} = aggregate(trials, shipped_plan())
    end

    test "a failing negative control invalidates the run it belongs to" do
      assert %{"verdict" => "invalid", "reasons" => reasons} =
               aggregate([
                 trial("baseline", "cited.1", "motivating", false),
                 trial("candidate", "cited.1", "motivating", true),
                 trial("baseline", "negative-control.always-fails", "negative-control", true),
                 trial("candidate", "negative-control.always-fails", "negative-control", true)
               ])

      assert Enum.any?(reasons, &(&1 =~ "negative control"))
    end

    test "a large unpaired batch still validates against the result contract" do
      {:ok, contract} = contract("evaluation.schema.json")

      trials =
        for index <- 1..40 do
          trial("candidate", "orphan.#{index}", "motivating", true)
        end

      value = aggregate(trials)

      # An unbounded reason string would breach the contract exactly when the
      # aggregate has the most to report, so no artifact would be written.
      assert value["verdict"] == "invalid"
      assert ValueContract.valid?(contract, value)
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
      assert length(data["cases"]) == 2

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

    test "the committed plan hashes every complete case canonically" do
      planned = Map.new(shipped_plan()["cases"], &{&1["id"], &1})

      assert compiled_plan() == shipped_plan()["cases"]

      for set <- ~w(motivating regression held-out negative-control),
          kase <- case_set(set)["cases"] do
        {:ok, canonical} = DeterministicJSON.encode(kase)

        case_hash =
          "sha256:" <> Base.encode16(:crypto.hash(:sha256, canonical <> "\n"), case: :lower)

        assert get_in(planned, [kase["id"], "set"]) == set
        assert get_in(planned, [kase["id"], "case_hash"]) == case_hash
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

  defp run_evaluator(program, expect) do
    response = %{
      content: nil,
      tool_calls: [
        %{id: "call-1", name: "run_ptc_lisp", args: %{"program" => program}}
      ]
    }

    assert {:ok, %{value: value}} = run_evaluator_with_response({:ok, response}, expect)
    value
  end

  defp run_evaluator_with_response(response, expect) do
    {:ok, llm} = LLMCapability.new(requester: fn _request -> response end)
    {:ok, manifest} = Manifest.load(path("repo-analyst-evaluate-replay.json"))
    {:ok, bundle} = Kernel.compile_bundle(manifest.workflow_components)
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [llm])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)

    {:ok, sink} =
      EventSink.start(
        :normal,
        limits,
        run_id: "repo-analyst-evaluator-#{System.unique_integer([:positive])}"
      )

    input =
      path("repo-analyst/trial-input.json")
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["case", "id"], "held-out.no-uncited-path")
      |> put_in(["case", "set"], "held-out")
      |> put_in(["case", "task"], "Inspect the source")
      |> put_in(["case", "expect"], expect)

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{"input" => input},
        limits: limits,
        event_sink: sink
      )

    Kernel.run("(evaluate/run data/input)", config)
  end

  defp trial(subject, id, set, passed?, opts \\ []) do
    override? = Keyword.get(opts, :override?, subject == "candidate")

    identity =
      %{
        "run_id" => "run-#{subject}-#{id}-#{System.unique_integer([:positive])}",
        "result_hash" => "sha256:" <> String.duplicate("1", 64),
        "workflow_bundle_hash" => "sha256:bundle",
        "mission_bundle_hash" => "sha256:mission",
        "provider_snapshot_hashes" => ["sha256:p"],
        "content_snapshot_hashes" => ["sha256:content"],
        "fixture_set_hash" => "sha256:fixtures"
      }
      |> then(fn base ->
        if override? do
          Map.merge(base, %{
            "override_component_id" => "agent.core",
            "override_base_source_hash" => "sha256:base",
            "override_source_hash" => "sha256:candidate"
          })
        else
          base
        end
      end)

    %{
      "status" => "scored",
      "subject" => subject,
      "repetition" => 1,
      "candidate" => @candidate,
      "case" => %{
        "id" => id,
        "set" => set,
        "case_hash" => Keyword.get(opts, :case_hash, "sha256:case")
      },
      "passed" => passed?,
      "detail" => "synthetic",
      "run_identity" => identity
    }
  end

  defp aggregate(trials, plan \\ nil) do
    {:ok, result} = run_aggregate(trials, plan)
    result.value
  end

  # Runs the shipped aggregate component exactly as its manifest would, with no
  # provider of any kind.
  defp run_aggregate(trials, plan \\ nil) do
    plan = plan || plan_for(trials)

    {:ok, plan_component} =
      Component.new(
        id: "evaluation.plan",
        source: File.read!(Path.join(@root, "repo-analyst/evaluation.plan.clj")),
        origin: "file"
      )

    {:ok, component} =
      Component.new(
        id: "aggregate",
        source: File.read!(Path.join(@root, "repo-analyst/aggregate.clj")),
        dependencies: ["evaluation.plan"],
        origin: "file"
      )

    {:ok, bundle} = Kernel.compile_bundle([plan_component, component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)

    {:ok, sink} =
      EventSink.start(:normal, limits, run_id: "aggregate-#{System.unique_integer([:positive])}")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{"input" => %{"trials" => trials, "plan" => plan}},
        limits: limits,
        event_sink: sink
      )

    Kernel.run("(aggregate/run data/input)", config)
  after
    :ok = ensure_library_loaded()
  end

  defp ensure_library_loaded, do: Library.component("cap") |> elem(0) && :ok

  defp plan_for(trials) do
    cases =
      trials
      |> Enum.map(& &1["case"])
      |> Enum.uniq_by(&{&1["id"], &1["set"], &1["case_hash"]})
      |> Enum.map(fn kase ->
        Map.put(
          kase,
          "repetitions",
          trials
          |> Enum.filter(&(get_in(&1, ["case", "id"]) == kase["id"]))
          |> Enum.map(& &1["repetition"])
          |> Enum.uniq()
          |> Enum.sort()
        )
      end)

    %{"cases" => cases}
  end

  defp shipped_plan do
    @root
    |> Path.join("repo-analyst/aggregate-input.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("plan")
  end

  defp shipped_trials do
    Enum.flat_map(shipped_plan()["cases"], fn planned ->
      passed? = planned["id"] != "negative-control.always-fails"

      for subject <- ~w(baseline candidate) do
        trial(subject, planned["id"], planned["set"], passed?, case_hash: planned["case_hash"])
      end
    end)
  end

  defp set_passed(trials, subject, id, passed?) do
    Enum.map(trials, fn
      %{"subject" => ^subject, "case" => %{"id" => ^id}} = trial ->
        Map.put(trial, "passed", passed?)

      trial ->
        trial
    end)
  end

  defp compiled_plan do
    {:ok, manifest} = Manifest.load(path("repo-analyst-aggregate.json"))
    {:ok, bundle} = Kernel.compile_bundle(manifest.workflow_components)
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "compiled-evaluation-plan")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: cases}} = Kernel.run("(return (evaluation.plan/cases))", config)
    cases
  end
end
