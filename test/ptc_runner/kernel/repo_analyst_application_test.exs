defmodule PtcRunner.Kernel.RepoAnalystApplicationTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Covers the `repo-analyst` application package as files rather than runtime.

  Every assertion here is about host JSON, manifests, PTC-Lisp, and schemas. If
  one of these fails, the cause is an edited application file, not an edited
  Elixir module — which is the property Slice G exists to demonstrate.
  """

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Lisp.Prelude

  @root Path.expand("../../..", __DIR__)
  @host Path.join(@root, "repo-analyst.host.json")

  # Frozen by direction plan section 8.3. A stub that renames one of these to
  # make a Wave 1 test pass would silently diverge from the source E1 installs.
  @private_operations ~w(
    private-history.capability-calls
    private-history.effective-preludes
    private-history.generated-sources
    private-history.model-exchanges
    private-history.provider-exchanges
  )

  # Works around a defect in the host decoder, not in this application.
  #
  # `HostConfig` turns three enumerated string fields into atoms with
  # `String.to_existing_atom/1`: `error_feedback` (host_config.ex:513), the
  # transport auth `scheme` (:461), and `data_class`/`accepts_data` (:595).
  # None of those atoms is interned by `HostConfig` itself — `:bounded` and
  # `:private_inspection` exist only once `MCPProtocol` or `MCPSource` has been
  # loaded. Decoding a valid host document therefore raises ArgumentError
  # instead of returning a result whenever `HostConfig` is exercised first.
  #
  # `host_config_test.exs:142` already covers `"error_feedback": "bounded"` and
  # passes only because the surrounding suite happens to load those modules
  # first. This file decodes a host document that uses both `bounded` feedback
  # and `private_inspection` before anything else touches MCP, so it fails on
  # every seed without this.
  #
  # The fix belongs to the host-decoder owner (#1130), not to Slice G: issue
  # #1128 owns application files only. Remove this block once the decoder maps
  # its own enumerated values instead of borrowing another module's atom table.
  setup_all do
    Code.ensure_loaded!(PtcRunner.Kernel.MCPSource)
    Code.ensure_loaded!(PtcRunner.Kernel.MCPProtocol)
    :ok
  end

  describe "host installation" do
    test "installs the aliases the manifests select, and no implicit provider" do
      assert {:ok, host} = HostConfig.load(@host)

      # private-history is absent until the inspection source lands; see the
      # deferred-installation test below.
      assert host.install |> Map.keys() |> Enum.sort() == ["deepseek", "history", "workspace"]
      assert host.install["workspace"].source == :mcp
      assert host.install["history"].source == :ptc_trace_snapshot
      assert host.install["deepseek"].source == :llm
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
      assert {:ok, manifest} = Manifest.load(path("repo-analyst-answer.json"))

      assert Enum.map(manifest.providers.mission, & &1["name"]) == ["workspace"]
      assert Enum.map(manifest.providers.workflow, & &1["name"]) == ["deepseek"]
      assert manifest.entry == "agent.main/run"
      assert Enum.map(manifest.mission_components, & &1.id) == ["cap", "repo"]
    end

    test "the review and improve manifests add the evidence surface and nothing else" do
      for name <- ~w(repo-analyst-review.json repo-analyst-improve.json) do
        assert {:ok, manifest} = Manifest.load(path(name)), "#{name} failed to load"

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
          {:ok, manifest} = Manifest.load(path(name))
          assert manifest.contracts.result, "#{name} must declare a result contract"
          manifest.contracts.result.schema
        end

      assert length(Enum.uniq(contracts)) == 3
    end

    test "selecting private-history fails until the inspection source is installed" do
      {:ok, host} = HostConfig.load(@host)

      refute Map.has_key?(host.install, "private-history"),
             """
             This test is the Wave 1 boundary marker for issue #1128.

             When #1127 lands ptc_inspection_snapshot, add the private-history
             installation to repo-analyst.host.json and replace this test with
             one that asserts the review manifest assembles. Real assembly and
             execution of the review and improve manifests is owned by #1132.
             """
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

    test "runs exposes the seven documented evidence functions over both sources" do
      assert {:ok, bundle} = compile_facade("runs")

      assert facade_names(bundle) ==
               ~w(runs/capability-calls runs/effective-preludes runs/generated-sources
                  runs/list-runs runs/model-exchanges runs/provider-exchanges runs/turns)

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

    test "repo assembles against the four mapped workspace tools" do
      {:ok, bundle} = compile_facade("repo")

      granted = ~w(workspace.find workspace.list workspace.read workspace.search)

      assert {:ok, _mission} =
               MissionEnvironment.new(bundle: bundle, capabilities: stubs(granted))
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

      refute ValueContract.valid?(contract, %{"answer" => "It is bounded.", "citations" => []}),
             "an uncited answer must not validate"

      refute ValueContract.valid?(contract, %{
               "answer" => "It is bounded.",
               "citations" => [Map.delete(citation, "snapshot_hash")]
             }),
             "a citation with no snapshot hash is not bound to any bytes"
    end

    test "declining a change is a first-class improvement decision" do
      {:ok, contract} = contract("candidate.schema.json")

      evidence = [%{"provider" => "history", "snapshot_hash" => "sha256:abc"}]

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

    test "a proposed change must carry complete hashed replacement source" do
      {:ok, contract} = contract("candidate.schema.json")

      assert ValueContract.valid?(contract, proposal())

      refute ValueContract.valid?(
               contract,
               put_in(
                 proposal(),
                 ["candidate"],
                 Map.delete(proposal()["candidate"], "source_hash")
               )
             ),
             "an unhashed candidate cannot be verified before compilation"

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
               "evidence" => [%{"provider" => "history", "snapshot_hash" => "sha256:abc"}]
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
                "snapshot_hash" => "sha256:abc",
                "run_id" => "run-1",
                "event_sequences" => [12, 18]
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

  # Compiles the shipped facade exactly as a manifest would: the real file, with
  # the shipped cap library as its only declared dependency.
  defp compile_facade(namespace) do
    {:ok, manifest} = Manifest.load(path("repo-analyst-review.json"))
    component = Enum.find(manifest.mission_components, &(&1.id == namespace))
    {:ok, cap} = Library.component("cap")

    Kernel.compile_bundle([cap, component])
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

  # Bounded stubs standing in for capabilities issue #1127 installs. They carry
  # the frozen names and the paged envelope shape and nothing else; they exist
  # to prove the facade selects the right names, not to model the source.
  defp stubs(names) do
    Enum.map(names, fn name ->
      {:ok, capability} =
        Capability.new(
          name: name,
          effect: :read,
          input_schema: %{"type" => "object", "additionalProperties" => true},
          callback: fn _args -> {:ok, %{"items" => [], "snapshot_hash" => "sha256:stub"}} end
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
          "snapshot_hash" => "sha256:abc",
          "run_id" => "run-1",
          "event_sequences" => [12, 18]
        }
      ],
      "candidate" => %{
        "format" => "component-source",
        "component_id" => "agent.core",
        "base_source_hash" => "sha256:base",
        "source_hash" => "sha256:candidate",
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
