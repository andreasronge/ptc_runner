defmodule PtcRunner.Kernel.PreludeSearchLabTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.LLMReplay
  alias PtcRunner.Labs.PreludeSearch
  alias PtcRunner.Labs.PreludeSearch.Phase1
  alias PtcRunner.Labs.PreludeSearch.Statistics

  @moduletag :nightly

  lab = Path.expand("../../../scripts/labs/prelude-search", __DIR__)
  Code.require_file("support/mutations.exs", lab)
  Code.require_file("support/inputs.exs", lab)
  Code.require_file("support/lab.exs", lab)
  Code.require_file("support/statistics.exs", lab)
  Code.require_file("support/phase1.exs", lab)

  test "diagnosis scoring accepts qualification but rejects empty form and false evidence" do
    instance = %{
      subject: "intervals",
      ground_truth: %{"function" => "f", "form" => "(+ 1 2)"},
      visible: [%{"observed" => 7}]
    }

    rows = [
      %{
        "value" => %{
          "diagnosis" => %{
            "function" => "lab.intervals/f",
            "form" => "(+ 1 2)",
            "cited_executions" => [%{"index" => 0, "observed_json" => "7"}]
          }
        }
      },
      %{
        "value" => %{
          "diagnosis" => %{
            "function" => "other/f",
            "form" => "",
            "cited_executions" => [%{"index" => 0, "observed_json" => "8"}]
          }
        }
      }
    ]

    [correct, wrong] = Phase1.score(rows, instance)
    assert correct["function_correct"] and correct["form_correct"] and correct["citations_valid"]
    refute wrong["function_correct"] or wrong["form_correct"] or wrong["citations_valid"]
  end

  test "fixture export preserves provider failures and refuses post-provider failures" do
    assert Phase1.replay_outcome(%{
             "status" => "error",
             "kind" => "provider_error",
             "reason" => "timeout",
             "details" => "provider timed out",
             "retryable?" => true
           }) == %{
             "error" => %{
               "kind" => "timeout",
               "details" => "provider timed out",
               "retryable" => true
             }
           }

    for {kind, reason} <- [
          {"invalid_result", "output_schema_mismatch"},
          {"provider_error", "reservation_bound_exceeded"},
          {"timeout", "llm_request_timeout"}
        ] do
      assert_raise RuntimeError, ~r/retain artifacts and reservation/, fn ->
        Phase1.replay_outcome(%{"status" => "error", "kind" => kind, "reason" => reason})
      end
    end
  end

  test "parallel proposals have distinct replay identities with the same visible evidence" do
    instance = %{mutated_source: "source", visible: [%{"input" => 1, "observed" => 2}]}
    proposals = Phase1.proposal_params(instance, 4)

    hashes =
      Enum.map(proposals, fn params ->
        {:ok, hash} =
          LLMReplay.request_hash(%{"prompt" => Jason.encode!(params)})

        hash
      end)

    assert length(Enum.uniq(hashes)) == 4

    assert proposals |> Enum.map(&Map.delete(&1, "candidate_index")) |> Enum.uniq() |> length() ==
             1
  end

  test "paired comparison refuses missing and duplicate observations" do
    row = %{"subject" => "s", "seed" => 1, "experiment" => "base", "solved" => true}
    [comparison] = Statistics.compare([row], "base", ["candidate"])
    assert comparison["status"] == "incomplete_pairs"

    assert_raise ArgumentError, fn ->
      Statistics.compare([row, row], "base", ["candidate"])
    end
  end

  test "every mutation has disjoint visible, selection and final inputs and is observable" do
    for subject <- PreludeSearch.subjects(), seed <- 20_260_920..20_260_924 do
      instance = PreludeSearch.instance(subject, seed)

      sets =
        Enum.map([instance.visible, instance.selection, instance.final], fn rows ->
          MapSet.new(rows, & &1["input"])
        end)

      [visible, selection, final] = sets
      assert MapSet.disjoint?(visible, selection)
      assert MapSet.disjoint?(visible, final)
      assert MapSet.disjoint?(selection, final)
      assert Enum.any?(instance.selection, & &1["reached_mutation"]), "#{subject}/#{seed}"
      assert Enum.any?(instance.final, & &1["reached_mutation"]), "#{subject}/#{seed}"
    end
  end

  @tag :tmp_dir
  test "selection is recorded and cannot replace a winner after final-test failure", %{
    tmp_dir: root
  } do
    instance = PreludeSearch.instance("intervals", 20_260_920)
    # The first candidate passes selection but deliberately fails the untouched final set.
    instance = %{
      instance
      | selection: Enum.map(instance.selection, &Map.put(&1, "oracle", %{"wrong" => true}))
    }

    bad = ~S|(ns lab.intervals) (defn merge-with-tolerance [_] (return {"wrong" true}))|
    result = PreludeSearch.select_candidates(instance, [bad, instance.source], root)
    assert result["selected"] == 0
    refute result["final_pass"]
    assert File.regular?(Path.join(root, "selection.ptcins"))
  end

  @tag :tmp_dir
  test "report counts only candidates that reached selection evaluation", %{tmp_dir: root} do
    instance = PreludeSearch.instance("intervals", 20_260_920)
    sources = ["(invalid", nil, instance.source]
    selection = PreludeSearch.select_candidates(instance, sources, root)

    candidates =
      Phase1.score(Enum.map(sources, &%{"value" => %{"candidate_source" => &1}}), instance)

    row = %{
      "experiment" => "E2 K=4",
      "subject" => "intervals",
      "candidates" => candidates,
      "selection" => selection,
      "solved" => selection["final_pass"],
      "wall_ms" => 0
    }

    report =
      Enum.find(Phase1.report([row]), &(&1.experiment == "E2 K=4" and &1.subject == "intervals"))

    assert report.candidates_generated == 2
    assert report.candidates_checked == 1
    assert report.checked_per_solved == 1.0
  end

  test "Phase 0 re-executes every recorded execution byte-equally" do
    output =
      Path.join(System.tmp_dir!(), "prelude-search-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(output) end)

    assert {:ok, [result]} =
             PreludeSearch.run(
               output: output,
               subjects: ["intervals"],
               seed: 20_260_917,
               executions: 10
             )

    assert result.equal == 10
    assert result.unequal == []

    # Replay must work after relocation, in another VM with no retained packages.
    relocated = output <> "-relocated"
    File.rename!(output, relocated)
    on_exit(fn -> File.rm_rf!(relocated) end)

    {console, status} =
      System.cmd(
        System.find_executable("mix"),
        [
          "run",
          "scripts/labs/prelude-search/run.exs",
          "--replay-artifacts",
          relocated
        ],
        stderr_to_stdout: true
      )

    assert status == 0, console
    assert console =~ "| intervals | 10 | 10 | 0 |"

    source = Path.join(relocated, "intervals/oracle-bundle/subject.clj")
    File.write!(source, File.read!(source) <> "\n; changed\n")

    assert_raise RuntimeError, ~r/bundle identity changed/, fn ->
      PreludeSearch.replay(relocated)
    end
  end
end
