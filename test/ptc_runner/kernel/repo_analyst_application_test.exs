defmodule PtcRunner.Kernel.RepoAnalystApplicationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Covers the `repo-analyst` application package as files rather than runtime.

  Every assertion here is about host JSON, manifests, PTC-Lisp, and schemas. If
  one of these fails, the cause is an edited application file, not an edited
  Elixir module — which is the property Slice G exists to demonstrate.
  """

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp.Prelude

  @root Path.expand("../../..", __DIR__)
  @host Path.join(@root, "repo-analyst.host.json")
  @base_source_hash "sha256:" <> String.duplicate("0", 64)

  # Frozen by direction plan section 8.3. A stub that renames one of these
  # would silently diverge from the native inspection source.
  @private_operations ~w(
    private-history.capability-calls
    private-history.effective-preludes
    private-history.generated-sources
    private-history.model-exchanges
    private-history.provider-exchanges
  )

  describe "host installation" do
    test "installs the aliases the manifests select, and no implicit provider" do
      assert {:ok, host} = HostConfig.load(@host)

      assert host.install |> Map.keys() |> Enum.sort() ==
               ["deepseek", "history", "private-history", "replay-llm", "workspace"]

      assert host.install["workspace"].source == :mcp
      assert host.install["history"].source == :ptc_trace_snapshot
      assert host.install["private-history"].source == :ptc_inspection_snapshot
      assert host.install["deepseek"].source == :llm
      assert host.install["replay-llm"].source == :llm_replay
    end

    test "maps exactly the five read tools and keeps every one model-invisible" do
      {:ok, host} = HostConfig.load(@host)
      tools = host.install["workspace"].tools

      assert tools |> Map.values() |> Enum.map(& &1.as) |> Enum.sort() ==
               ~w(workspace.find workspace.info workspace.list workspace.read workspace.search)

      assert Enum.all?(tools, fn {_upstream, tool} -> tool.effect == :read end)
      refute Enum.any?(tools, fn {_upstream, tool} -> tool.model_visible end)
    end

    test "accepts private inspection data on every provider a private run may reach" do
      {:ok, host} = HostConfig.load(@host)

      for alias_name <- ~w(deepseek workspace) do
        assert "private_inspection" in Enum.map(
                 host.install[alias_name].accepts_data,
                 &to_string/1
               ),
               "#{alias_name} must accept private inspection or the review manifest cannot assemble"
      end
    end
  end

  describe "task manifests" do
    test "the answer manifest never selects a prior-run source" do
      assert {:ok, manifest} = load_manifest("repo-analyst-answer.json")

      assert Enum.map(manifest.providers.mission, & &1["name"]) == ["workspace"]
      assert Enum.map(manifest.providers.workflow, & &1["name"]) == ["deepseek"]
      assert manifest.entry == "agent.main/run"
      assert Enum.map(manifest.mission_components, & &1.id) == ["cap", "repo"]
    end

    test "the review and improve manifests add the evidence surface and nothing else" do
      for name <- ~w(repo-analyst-review.json repo-analyst-improve.json) do
        assert {:ok, manifest} = load_manifest(name), "#{name} failed to load"

        assert Enum.map(manifest.providers.mission, & &1["name"]) ==
                 ["workspace", "history", "private-history"]

        assert Enum.map(manifest.mission_components, & &1.id) == ["cap", "repo", "runs"]
        assert manifest.entry == "agent.main/run"
      end
    end

    test "each task compiles its own result contract rather than sharing one union" do
      contracts =
        for name <- ~w(repo-analyst-answer.json repo-analyst-review.json
                       repo-analyst-improve.json) do
          {:ok, manifest} = load_manifest(name)
          assert manifest.contracts.result, "#{name} must declare a result contract"
          manifest.contracts.result.schema
        end

      assert length(Enum.uniq(contracts)) == 3
    end

    test "agent and mission deadlines are explicit rather than inherited defaults" do
      for {name, workflow_timeout_ms} <- [
            {"repo-analyst-answer.json", 110_000},
            {"repo-analyst-review.json", 110_000},
            {"repo-analyst-improve.json", 110_000}
          ] do
        {:ok, manifest} = load_manifest(name)

        assert manifest.limits.run_duration_ms == 120_000
        assert manifest.limits.workflow_timeout_ms == workflow_timeout_ms
        assert manifest.limits.evaluation_timeout_ms == 20_000
      end
    end

    test "the improvement turn budget is reachable through installed and selected limits" do
      assert {:ok, host} = HostConfig.load(@host)
      assert {:ok, manifest} = Manifest.load(path("repo-analyst-improve.json"), host.limits)

      max_turns =
        path("repo-analyst/improve-input.json")
        |> File.read!()
        |> Jason.decode!()
        |> get_in(["agent", "max_turns"])

      assert manifest.limits.subordinate_evaluations >= max_turns
      assert manifest.limits.workflow_capability_calls_per_name >= max_turns
      assert manifest.limits.normal_event_count >= max_turns * 11 + 4
    end

    @tag :tmp_dir
    test "review and improve assemble against the installed private source", %{tmp_dir: root} do
      trace_directory = Path.join(root, "traces")
      inspection_directory = Path.join(root, "inspection")
      File.mkdir_p!(trace_directory)
      File.mkdir_p!(inspection_directory)

      host_path =
        write_host_fixture(root,
          trace_directory: trace_directory,
          inspection_directory: inspection_directory
        )

      assert {:ok, host} = HostConfig.load(host_path)

      assert {:ok, registry} =
               HostInstallation.catalog(host)
               |> then(fn {:ok, catalog} ->
                 HostInstallation.runtime_registry(host, catalog)
               end)

      for name <- ~w(repo-analyst-review.json repo-analyst-improve.json) do
        assert {:ok, built} = RunBuilder.load_and_build(path(name), registry)
        assert built.config.event_sink.policy == :private

        assert built.config.connector_snapshots
               |> Enum.map(& &1["provider"])
               |> Enum.sort() == ["deepseek", "history", "private-history", "workspace"]

        assert :ok = RunBuilder.close(built)
      end
    end
  end

  describe "prompt-visible facades" do
    test "cap stays composition-only so it never enters the prompt catalog" do
      assert {:ok, component} = Library.component("cap")
      assert {:ok, bundle} = Kernel.compile_bundle([component])

      assert Prelude.prompt_exports(bundle.prelude) == []
    end

    test "repo exposes bounded exploration over the filesystem server's own contract" do
      assert {:ok, bundle} = compile_facade("repo")

      assert facade_names(bundle) ==
               ~w(repo/find-files repo/ls repo/read-range repo/search repo/search-under)

      assert tool_refs(bundle, "repo") ==
               ~w(workspace.find workspace.list workspace.read workspace.search)
    end

    # A task prompt that paraphrases its own result schema drifts from it, and
    # the drift only surfaces as a rejected result after a live run has been
    # paid for. Four separate prompt defects in this application were exactly
    # that. The schema is the shape authority; the prompt embeds what it says.
    test "the improvement prompt embeds the shape its result schema declares" do
      assert {:ok, contract} =
               "repo-analyst/candidate.schema.json"
               |> File.read!()
               |> Jason.decode!()
               |> ValueContract.compile()

      task =
        "repo-analyst/improve-input.json"
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("task")

      for branch <- String.split(ValueContract.describe(contract), "\n") do
        assert String.contains?(task, branch),
               "improve-input.json omits a declared branch shape:\n#{branch}"
      end
    end

    test "runs exposes the documented evidence functions over both sources" do
      assert {:ok, bundle} = compile_facade("runs")

      assert facade_names(bundle) ==
               ~w(runs/capability-calls runs/effective-prelude runs/effective-preludes
                  runs/generated-sources runs/latest-generated-source
                  runs/latest-model-exchange runs/list-runs runs/model-exchanges
                  runs/provenance runs/provider-exchanges runs/review-seed runs/turns)

      assert tool_refs(bundle, "runs") ==
               Enum.sort(["history.list-runs", "history.list-turns"] ++ @private_operations)
    end

    test "every facade function carries a signature the model can read" do
      for namespace <- ~w(repo runs) do
        {:ok, bundle} = compile_facade(namespace)

        for export <- Prelude.prompt_exports(bundle.prelude) do
          assert is_binary(export.signature) and export.signature =~ "->",
                 "#{export.ref} has no signature"

          assert is_binary(export.doc) and export.doc != "",
                 "#{export.ref} has no documentation"
        end
      end
    end
  end

  describe "capability requirements" do
    test "runs cannot be selected into a mission that lacks the private operations" do
      {:ok, bundle} = compile_facade("runs")

      assert {:error, {:missing_capability_requirement, missing}} =
               MissionEnvironment.new(bundle: bundle, capabilities: stubs(["history.list-runs"]))

      assert missing == Enum.sort(["history.list-turns"] ++ @private_operations)
    end

    test "runs assembles against the frozen operation names" do
      {:ok, bundle} = compile_facade("runs")
      granted = ["history.list-runs", "history.list-turns"] ++ @private_operations

      assert {:ok, _mission} =
               MissionEnvironment.new(bundle: bundle, capabilities: stubs(granted))
    end

    test "each runs function calls its own operation and unwraps the envelope" do
      {:ok, bundle} = compile_facade("runs")
      granted = ["history.list-runs", "history.list-turns"] ++ @private_operations
      {:ok, calls} = Agent.start_link(fn -> [] end)

      {:ok, mission} =
        MissionEnvironment.new(bundle: bundle, capabilities: stubs(granted, calls))

      # Assembly alone proves only that the names resolve. Calling each function
      # proves the facade reaches the operation it claims and that cap/unwrap!
      # returns the value rather than the envelope.
      for {function, operation, limit} <- [
            {~s|(runs/list-runs 10 nil)|, "history.list-runs", 10},
            {~s|(runs/turns "run-1" {"status" "error" "ignored" true} nil)|, "history.list-turns",
             20},
            {~s|(runs/model-exchanges "run-1" nil)|, "private-history.model-exchanges", 1},
            {~s|(runs/latest-model-exchange "run-1")|, "private-history.model-exchanges", 1},
            {~s|(runs/capability-calls "run-1" nil)|, "private-history.capability-calls", 1},
            {~s|(runs/generated-sources "run-1" nil)|, "private-history.generated-sources", 1},
            {~s|(runs/latest-generated-source "run-1")|, "private-history.generated-sources", 1},
            {~s|(runs/effective-preludes "run-1" nil)|, "private-history.effective-preludes", 1},
            {~s|(runs/provider-exchanges "run-1" nil)|, "private-history.provider-exchanges", 1}
          ] do
        Agent.update(calls, fn _previous -> [] end)

        assert {:ok, %{value: %{outcome: :returned, value: value}}} =
                 Kernel.run(
                   "(return (kernel/eval (program (return #{function}))))",
                   run_config(mission)
                 ),
               "#{function} did not evaluate"

        assert [{^operation, args}] = Agent.get(calls, & &1),
               "#{function} must call exactly #{operation}"

        # cap/unwrap! returns the value; an unwrapped envelope would still carry :status.
        assert value["snapshot_hash"] == "sha256:stub"

        expected_provider =
          if String.starts_with?(operation, "history."), do: "history", else: "private-history"

        assert value["provider"] == expected_provider
        refute Map.has_key?(value, :status)

        # A nil cursor is the first page and must not appear in the arguments.
        refute Map.has_key?(args, "cursor")
        assert args["limit"] == limit

        if operation == "history.list-turns" do
          assert args["run_id"] == "run-1"
          assert args["status"] == "error"
          refute Map.has_key?(args, "ignored")
        end
      end
    end

    test "review-seed composes three audited source reads into one bounded observation" do
      {:ok, bundle} = compile_facade("runs")
      granted = ["history.list-runs", "history.list-turns"] ++ @private_operations
      {:ok, calls} = Agent.start_link(fn -> [] end)

      values = %{
        "private-history.model-exchanges" => %{
          "items" => [
            %{
              "capability_id" => "llm-1",
              "input_sequence" => 7,
              "output_sequence" => 8,
              "result" => %{"content" => "answer"},
              "run_id" => "run-1",
              "trace_id" => "trace-1"
            }
          ],
          "snapshot_hash" => "sha256:inspection"
        },
        "private-history.generated-sources" => %{
          "items" => [
            %{
              "run_id" => "run-1",
              "sequence" => 9,
              "source" => "(return 42)"
            }
          ],
          "snapshot_hash" => "sha256:inspection"
        },
        "history.list-turns" => %{
          "items" => [
            %{"run_id" => "run-1", "sequence" => 11, "type" => "evaluation-stopped"}
          ],
          "snapshot_hash" => "sha256:trace"
        }
      }

      {:ok, mission} =
        MissionEnvironment.new(bundle: bundle, capabilities: stubs(granted, calls, values))

      assert {:ok, %{value: %{outcome: :returned, value: value}}} =
               Kernel.run(
                 ~S|(return (kernel/eval (program (return (runs/review-seed "run-1")))))|,
                 run_config(mission)
               )

      assert Map.keys(value) |> Enum.sort() == ["model_action", "program", "trace_errors"]
      assert value["model_action"]["provider"] == "private-history"
      assert value["program"]["provider"] == "private-history"
      assert value["trace_errors"]["provider"] == "history"
      assert value["model_action"]["resource"] == "run-1"
      assert value["model_action"]["positions"] == [7, 8]
      assert value["program"]["resource"] == "run-1"
      assert value["program"]["positions"] == [9]
      assert value["trace_errors"]["resource"] == "run-1"
      assert value["trace_errors"]["positions"] == [11]

      assert Enum.map(Agent.get(calls, & &1), &elem(&1, 0)) == [
               "private-history.model-exchanges",
               "private-history.generated-sources",
               "history.list-turns"
             ]
    end

    test "catalog, provenance, and effective source expose copyable citation positions" do
      {:ok, bundle} = compile_facade("runs")
      granted = ["history.list-runs", "history.list-turns"] ++ @private_operations
      {:ok, calls} = Agent.start_link(fn -> [] end)

      values = %{
        "history.list-runs" => %{
          "items" => [
            %{
              "run_id" => "run-1",
              "component_overrides" => [],
              "workflow_prelude" => %{"hash" => "workflow"},
              "mission_prelude" => %{"hash" => "mission"},
              "positions" => [1]
            }
          ],
          "snapshot_hash" => "sha256:trace"
        },
        "history.list-turns" => %{
          "items" => [
            %{
              "sequence" => 1,
              "type" => "run-started",
              "data" => %{
                "component_overrides" => [],
                "workflow_prelude" => %{"hash" => "workflow"},
                "mission_prelude" => %{"hash" => "mission"}
              }
            }
          ],
          "snapshot_hash" => "sha256:trace"
        },
        "private-history.effective-preludes" => %{
          "items" => [
            %{
              "component_id" => "agent.retry",
              "sequence" => 9,
              "source_hash" => "sha256:source"
            }
          ],
          "snapshot_hash" => "sha256:inspection"
        }
      }

      {:ok, mission} =
        MissionEnvironment.new(
          bundle: bundle,
          capabilities: stubs(granted, calls, values)
        )

      for {expression, provider, snapshot_hash, resource, positions} <- [
            {~S|(first (get (runs/list-runs 10 nil) "items"))|, "history", "sha256:trace",
             "run-1", [1]},
            {~S|(runs/provenance "run-1")|, "history", "sha256:trace", "run-1", [1]},
            {~S|(runs/effective-prelude "run-1" "agent.retry")|, "private-history",
             "sha256:inspection", "run-1", [9]}
          ] do
        assert {:ok, %{value: %{outcome: :returned, value: value}}} =
                 Kernel.run(
                   "(return (kernel/eval (program (return #{expression}))))",
                   run_config(mission)
                 )

        assert Map.take(value, ~w(provider snapshot_hash resource positions)) == %{
                 "provider" => provider,
                 "snapshot_hash" => snapshot_hash,
                 "resource" => resource,
                 "positions" => positions
               }
      end

      assert Agent.get(calls, & &1)
             |> Enum.map(&elem(&1, 0))
             |> Enum.count(&(&1 == "history.list-runs")) == 1

      assert Agent.get(calls, & &1)
             |> Enum.map(&elem(&1, 0))
             |> Enum.count(&(&1 == "history.list-turns")) == 1
    end

    test "repo assembles against the four mapped workspace tools" do
      {:ok, bundle} = compile_facade("repo")

      granted = ~w(workspace.find workspace.list workspace.read workspace.search)

      assert {:ok, mission} = MissionEnvironment.new(bundle: bundle, capabilities: stubs(granted))

      assert {:ok, %{value: %{outcome: :returned, value: %{"provider" => "workspace"}}}} =
               Kernel.run(
                 ~S|(return (kernel/eval (program (return (repo/ls "" nil)))))|,
                 run_config(mission)
               )
    end
  end

  describe "result contracts" do
    test "every schema compiles through the bounded application profile" do
      for name <- ~w(answer.schema.json review.schema.json candidate.schema.json) do
        assert {:ok, _contract} = contract(name), "#{name} is not a valid application contract"
      end
    end

    test "an answer must carry a citation bound to captured bytes" do
      {:ok, contract} = contract("answer.schema.json")

      citation = %{
        "provider" => "workspace",
        "snapshot_hash" => "sha256:abc",
        "path" => "lib/ptc_runner/kernel/capability.ex",
        "lines" => [10, 24]
      }

      assert ValueContract.valid?(contract, %{
               "answer" => "It is bounded.",
               "citations" => [citation]
             })

      # Reporting that nothing in the snapshot supports a claim is a real
      # answer. Requiring a citation for it would only reward inventing one.
      assert ValueContract.valid?(contract, %{
               "answer" => "No file in the snapshot contains that literal.",
               "citations" => []
             })

      refute ValueContract.valid?(contract, %{
               "answer" => "It is bounded.",
               "citations" => [Map.delete(citation, "snapshot_hash")]
             }),
             "a citation with no snapshot hash is not bound to any bytes"

      refute ValueContract.valid?(contract, %{
               "answer" => "It is bounded.",
               "citations" => [Map.delete(citation, "lines")]
             }),
             "a citation with no line range does not say what was read"
    end

    test "declining a change is a first-class improvement decision" do
      {:ok, contract} = contract("candidate.schema.json")

      evidence = [
        %{
          "provider" => "history",
          "snapshot_hash" => "sha256:" <> String.duplicate("a", 64),
          "resource" => "run-1",
          "positions" => [12, 18]
        }
      ]

      assert ValueContract.valid?(contract, %{
               "decision" => "no-change",
               "rationale" => "One malformed input, not a reusable gap.",
               "evidence" => evidence
             })

      assert ValueContract.valid?(contract, %{
               "decision" => "insufficient-evidence",
               "rationale" => "No captured run reached the failing branch.",
               "missing_evidence" => ["a run that exercises the retry path"]
             })
    end

    test "review and improvement evidence document each provider's position coordinate" do
      candidate =
        "repo-analyst/candidate.schema.json"
        |> path()
        |> File.read!()
        |> Jason.decode!()

      review =
        "repo-analyst/review.schema.json"
        |> path()
        |> File.read!()
        |> Jason.decode!()

      descriptions =
        Enum.map(Enum.take(candidate["oneOf"], 2), fn branch ->
          get_in(branch, [
            "properties",
            "evidence",
            "items",
            "properties",
            "positions",
            "description"
          ])
        end) ++
          [
            get_in(review, [
              "properties",
              "findings",
              "items",
              "properties",
              "evidence",
              "items",
              "properties",
              "positions",
              "description"
            ])
          ]

      assert Enum.all?(
               descriptions,
               &String.contains?(&1, "canonical event sequence IDs for history")
             )

      assert Enum.all?(
               descriptions,
               &String.contains?(&1, "inspection-record sequence IDs for private-history")
             )

      assert Enum.all?(descriptions, &String.contains?(&1, "source line numbers for workspace"))

      for input_name <- ~w(review-input.json improve-input.json) do
        task =
          "repo-analyst/#{input_name}"
          |> path()
          |> File.read!()
          |> Jason.decode!()
          |> Map.fetch!("task")

        assert task =~ "history positions are canonical event sequence IDs"
        assert task =~ "private-history positions are inspection-record sequence IDs"
        assert task =~ "workspace positions are source line numbers"

        assert task =~
                 "runs/list-runs positions cite only run-started provenance, not outcome or aggregate counts"
      end
    end

    test "a proposed change carries complete source while the trusted host derives its hash" do
      {:ok, contract} = contract("candidate.schema.json")

      assert ValueContract.valid?(contract, proposal())

      refute ValueContract.valid?(
               contract,
               put_in(proposal(), ["candidate", "base_source_hash"], String.duplicate("0", 64))
             ),
             "a bare artifact digest cannot be materialized as an override descriptor"

      refute ValueContract.valid?(
               contract,
               put_in(proposal(), ["candidate", "base_source_hash"], String.duplicate("x", 71))
             ),
             "a length-correct non-hash cannot be materialized as an override descriptor"

      refute ValueContract.valid?(
               contract,
               Map.put(proposal(), "evidence", [
                 %{
                   "provider" => "history",
                   "snapshot_hash" => "sha256:" <> String.duplicate("a", 64)
                 }
               ])
             ),
             "a hash alone does not locate evidence inside a snapshot"

      refute ValueContract.valid?(
               contract,
               put_in(proposal(), ["evidence", Access.at(0), "positions"], [0])
             ),
             "trace sequences and source lines are both one-based"

      refute Map.has_key?(proposal()["candidate"], "source_hash"),
             "PTC-Lisp cannot compute SHA-256; trusted materialization must derive it"

      refute ValueContract.valid?(
               contract,
               put_in(proposal(), ["candidate", "source_hash"], "sha256:model-invented")
             ),
             "a model-authored hash must not enter the trusted override identity"

      refute ValueContract.valid?(
               contract,
               put_in(proposal(), ["candidate"], Map.delete(proposal()["candidate"], "content"))
             ),
             "a diff is not executable truth; complete source is required"

      refute ValueContract.valid?(contract, Map.put(proposal(), "evidence", [])),
             "a proposal with no cited evidence must not validate"
    end

    test "an unknown decision tag matches no branch" do
      {:ok, contract} = contract("candidate.schema.json")

      refute ValueContract.valid?(contract, %{
               "decision" => "apply-change",
               "rationale" => "…",
               "evidence" => [
                 %{
                   "provider" => "history",
                   "snapshot_hash" => "sha256:" <> String.duplicate("a", 64),
                   "resource" => "run-1",
                   "positions" => [12]
                 }
               ]
             })
    end

    test "a review reports an isolated finding as one occurrence, not a pattern" do
      {:ok, contract} = contract("review.schema.json")

      review = %{
        "summary" => "One run exceeded its turn budget.",
        "findings" => [
          %{
            "finding" => "The loop retried a rejected argument unchanged.",
            "occurrences" => 1,
            "evidence" => [
              %{
                "provider" => "private-history",
                "snapshot_hash" => "sha256:" <> String.duplicate("a", 64),
                "resource" => "run-1",
                "positions" => [12, 18]
              }
            ]
          }
        ],
        "recommended_next_action" => "fix-one-off-defect",
        "rationale" => "A single occurrence does not establish a reusable gap."
      }

      assert ValueContract.valid?(contract, review)
      assert ValueContract.valid?(contract, %{review | "findings" => []})

      refute ValueContract.valid?(
               contract,
               put_in(review, ["findings"], [
                 %{"finding" => "…", "occurrences" => 1, "evidence" => []}
               ])
             ),
             "a finding with no evidence must not validate"
    end
  end

  describe "evaluation case data" do
    test "each case set is well formed and its ids are unique and namespaced" do
      for set <- ~w(motivating regression held-out) do
        data = case_set(set)

        assert data["case_set"] == set
        assert length(data["cases"]) >= 4, "#{set} needs enough cases to be worth running"

        ids = Enum.map(data["cases"], & &1["id"])
        assert ids == Enum.uniq(ids), "#{set} has duplicate case ids"

        assert Enum.all?(ids, &String.starts_with?(&1, set <> ".")),
               "#{set} ids must be namespaced"

        for kase <- data["cases"] do
          assert is_binary(kase["task"]) and kase["task"] != ""
          assert is_map(kase["expect"]) and is_binary(kase["expect"]["reason"])
          assert is_map(kase["workspace_fixture"]) and map_size(kase["workspace_fixture"]) > 0
        end
      end
    end

    test "held-out cases include prompt injection and never overlap the cited sets" do
      held_out = case_set("held-out")

      injection =
        Enum.filter(
          held_out["cases"],
          &(&1["expect"]["kind"] in ~w(resists-injection no-uncited-path))
        )

      assert length(injection) >= 3, "held-out evaluation must include prompt-injection data"

      assert Enum.all?(injection, fn kase ->
               kase["workspace_fixture"]
               |> Map.values()
               |> Enum.any?(&String.contains?(String.downcase(&1), ["ignore", "cite", "read "]))
             end),
             "an injection case must actually carry an injected instruction in file content"

      cited =
        Enum.flat_map(
          ~w(motivating regression),
          &Enum.map(case_set(&1)["cases"], fn c -> c["id"] end)
        )

      held = Enum.map(held_out["cases"], & &1["id"])

      assert MapSet.disjoint?(MapSet.new(cited), MapSet.new(held))
    end

    test "held-out fixtures stay outside the workspace include set" do
      {:ok, host} = HostConfig.load(@host)
      args = host.install["workspace"].transport.args

      includes =
        args
        |> Enum.zip(Enum.drop(args, 1))
        |> Enum.filter(fn {flag, _value} -> flag == "--include" end)
        |> Enum.map(fn {_flag, value} -> value end)

      refute Enum.any?(includes, &String.contains?(&1, "evaluation")),
             "a scout that can read the held-out cases is grading its own homework"

      assert "repo-analyst/*.clj" in includes,
             "the scout must be able to inspect its own policy"

      excludes =
        args
        |> Enum.zip(Enum.drop(args, 1))
        |> Enum.filter(fn {flag, _value} -> flag == "--exclude" end)
        |> Enum.map(fn {_flag, value} -> value end)

      # examples/** and priv/** otherwise pull in dependency trees. The server
      # snapshots the working tree rather than git, so a gitignored
      # node_modules still counts against the source ceiling.
      assert "**/node_modules/**" in excludes
      assert "**/_build/**" in excludes
      assert "**/deps/**" in excludes
    end
  end

  defp path(name), do: Path.join(@root, name)

  defp write_host_fixture(root, paths) do
    workspace_directory = Path.join(root, "workspace")
    File.mkdir_p!(workspace_directory)
    File.write!(Path.join(workspace_directory, "fixture.txt"), "bounded fixture\n")

    host =
      @host
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["credentials", "openrouter_key", "env"], "PATH")
      |> put_in(["install", "workspace", "transport", "cwd"], @root)
      |> put_in(
        ["install", "workspace", "transport", "args"],
        [
          "examples/mcp/filesystem/dist/server.js",
          "--root",
          workspace_directory,
          "--include",
          "**"
        ]
      )
      |> put_in(["install", "history", "directory"], paths[:trace_directory])
      |> put_in(
        ["install", "private-history", "directory"],
        paths[:inspection_directory]
      )

    path = Path.join(root, "repo-analyst.host.json")
    File.write!(path, Jason.encode!(host))
    path
  end

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

  # Compiles the shipped facade exactly as a manifest would: the real file, with
  # the shipped cap library as its only declared dependency.
  defp compile_facade(namespace) do
    {:ok, manifest} = Manifest.load(path("repo-analyst-review.json"))
    component = Enum.find(manifest.mission_components, &(&1.id == namespace))
    {:ok, cap} = Library.component("cap")

    Kernel.compile_bundle([cap, component])
  end

  defp load_manifest(name) do
    with {:ok, host} <- HostConfig.load(@host) do
      Manifest.load(path(name), host.limits)
    end
  end

  defp facade_names(%{prelude: prelude}) do
    prelude
    |> Prelude.prompt_exports()
    |> Enum.map(& &1.ref)
    |> Enum.sort()
  end

  # Only the facade's own references. The bundle also carries `cap`, whose
  # cap-list/cap-describe refs are implicit mission capabilities.
  defp tool_refs(%{prelude: prelude}, namespace) do
    prelude.exports
    |> Enum.filter(&(&1.namespace == namespace))
    |> Enum.flat_map(&Map.get(&1, :tool_refs, []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp run_config(mission) do
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)
    {:ok, kernel_component} = Library.component("kernel")
    {:ok, workflow_bundle} = Kernel.compile_bundle([kernel_component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: workflow_bundle)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "facade-call")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    config
  end

  # Bounded recording stubs isolate facade argument/envelope behavior from
  # native provider acquisition. The assembly test above exercises the real
  # trace and private-inspection sources.
  defp stubs(names, recorder \\ nil, values \\ %{}) do
    Enum.map(names, fn name ->
      callback = fn args ->
        if recorder, do: Agent.update(recorder, &(&1 ++ [{name, args}]))

        {:ok,
         Map.get(values, name, %{
           "items" => [],
           "snapshot_hash" => "sha256:stub"
         })}
      end

      {:ok, capability} =
        Capability.new(
          name: name,
          effect: :read,
          input_schema: %{"type" => "object", "additionalProperties" => true},
          callback: callback
        )

      capability
    end)
  end

  defp proposal do
    %{
      "decision" => "propose-change",
      "target" => "agent.core",
      "generalized_failure" => "The loop stops at the first page of a paged capability result.",
      "evidence" => [
        %{
          "provider" => "history",
          "snapshot_hash" => "sha256:" <> String.duplicate("a", 64),
          "resource" => "run-1",
          "positions" => [12, 18]
        }
      ],
      "candidate" => %{
        "format" => "component-source",
        "component_id" => "agent.core",
        "base_source_hash" => @base_source_hash,
        "content" => "(ns agent.core \"…\")"
      },
      "evaluation_plan" => %{
        "motivating_cases" => ["motivating.paged-evidence"],
        "regression_cases" => ["regression.single-page-answer"],
        "metrics" => ["success", "tool_calls"]
      }
    }
  end
end
