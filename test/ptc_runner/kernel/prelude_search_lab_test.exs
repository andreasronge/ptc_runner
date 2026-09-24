defmodule PtcRunner.Kernel.PreludeSearchLabTest do
  use ExUnit.Case, async: false
  @moduletag :operator

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

  @tag :tmp_dir
  test "stopped model commands finalize evidence and replay only the completed prefix", %{
    tmp_dir: tmp
  } do
    output = Path.join(tmp, "live")
    owner = self()

    runner = fn _command, args, _options ->
      send(owner, {:command_args, args})
      {"injected command failure", 1}
    end

    assert [] ==
             Phase1.run(
               output: output,
               subjects: ["intervals"],
               instances: 1,
               command_runner: runner
             )

    assert_receive {:command_args, args}
    assert "--trace-dir" in args
    summary = output |> Path.join("summary.json") |> File.read!() |> Jason.decode!()
    assert summary["stop_reason"] == "case_failed_reserved_at_ceiling"
    assert summary["spent_or_reserved_microusd"] == 100_000
    assert summary["completed_cases"] == 0
    assert File.read!(Path.join(output, "fixtures/index.json")) |> Jason.decode!() == []
    assert File.read!(Path.join(output, "results.json")) |> Jason.decode!() == []
    assert File.exists?(Path.join(output, "stopped-case.json"))

    assert [] ==
             Phase1.run(
               output: Path.join(tmp, "replay"),
               subjects: ["intervals"],
               instances: 1,
               replay: true,
               partial_replay: true,
               fixtures: Path.join(output, "fixtures"),
               command_runner: fn _, _, _ -> flunk("no completed model commands to replay") end
             )
  end

  @tag :tmp_dir
  test "a real Kernel timeout remains privately analyzable and preserves a replayable prefix", %{
    tmp_dir: tmp
  } do
    previous = Application.fetch_env(:ptc_runner, :llm_adapter)
    previous_counter = Application.fetch_env(:ptc_runner, :prelude_search_test_counter)
    previous_key = System.get_env("OPENROUTER_API_KEY")
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.PreludeSearchLLMAdapter)
    Application.put_env(:ptc_runner, :prelude_search_test_counter, counter)
    System.put_env("OPENROUTER_API_KEY", "test-only-no-network")

    on_exit(fn ->
      for {key, value} <- [llm_adapter: previous, prelude_search_test_counter: previous_counter] do
        case value do
          {:ok, value} -> Application.put_env(:ptc_runner, key, value)
          :error -> Application.delete_env(:ptc_runner, key)
        end
      end

      if previous_key,
        do: System.put_env("OPENROUTER_API_KEY", previous_key),
        else: System.delete_env("OPENROUTER_API_KEY")
    end)

    runner = fn _, ["ptc" | args], _ ->
      presentation = PtcRunner.MixCommandAdapter.execute(args)
      {presentation.stdout <> presentation.stderr, presentation.exit_status}
    end

    output = Path.join(tmp, "live")

    opts = [
      subjects: ["intervals"],
      instances: 1,
      request_timeout_ms: 1_000,
      command_runner: runner
    ]

    rows = Phase1.run([output: output] ++ opts)
    assert length(rows) == 1, File.read!(Path.join(output, "stopped-case.json"))
    summary = output |> Path.join("summary.json") |> File.read!() |> Jason.decode!()
    assert summary["spent_or_reserved_microusd"] == 100_001
    assert summary["stop_reason"] == "case_failed_reserved_at_ceiling"
    failed = Path.join(output, "runs/intervals-0-E1-three-turn")
    [trace] = Path.wildcard(Path.join(failed, "traces/*.jsonl"))
    run_id = trace |> Path.basename(".jsonl") |> String.replace_suffix(".private", "")
    analysis_dir = Path.join(tmp, "analysis")
    File.mkdir_p!(analysis_dir)

    analysis_output =
      ExUnit.CaptureIO.capture_io(fn ->
        presentation =
          PtcRunner.MixCommandAdapter.execute([
            "repl",
            "--profile",
            "private-run-analysis-v2",
            "--private-unattended",
            "--run",
            run_id,
            "--resource",
            "traces=" <> Path.join(failed, "traces"),
            "--resource",
            "inspection=" <> Path.join(failed, "inspection"),
            "--session-trace-dir",
            analysis_dir,
            "--format",
            "jsonl",
            "-e",
            "(analysis/open " <> Jason.encode!(run_id) <> ")"
          ])

        assert presentation.exit_status == 0, presentation.stdout <> presentation.stderr
      end)

    assert analysis_output =~ "model_exchanges"
    assert File.read!(Path.join(failed, "result.json")) =~ "llm_request_timeout"

    Application.put_env(:ptc_runner, :prelude_search_malformed_program, true)
    on_exit(fn -> Application.delete_env(:ptc_runner, :prelude_search_malformed_program) end)
    malformed_output = Path.join(tmp, "malformed")

    assert [_row] =
             Phase1.run(
               output: malformed_output,
               subjects: ["intervals"],
               instances: 1,
               budget_microusd: 100_000,
               command_runner: runner
             )

    capture = Path.join(malformed_output, "runs/intervals-0-E1-one-turn")
    [malformed_trace] = Path.wildcard(Path.join(capture, "traces/*.jsonl"))
    malformed_run_id = malformed_trace |> Path.basename(".jsonl") |> String.split(".") |> hd()

    malformed_analysis =
      ExUnit.CaptureIO.capture_io(fn ->
        presentation =
          PtcRunner.MixCommandAdapter.execute([
            "repl",
            "--profile",
            "private-run-analysis-v2",
            "--private-unattended",
            "--resource",
            "traces=" <> Path.join(capture, "traces"),
            "--resource",
            "inspection=" <> Path.join(capture, "inspection"),
            "--session-trace-dir",
            analysis_dir,
            "--format",
            "jsonl",
            "-e",
            "(analysis/open " <> Jason.encode!(malformed_run_id) <> ")",
            "-e",
            "(analysis/read " <>
              Jason.encode!(malformed_run_id) <> " {\"collection\" \"execution_errors\"})"
          ])

        assert presentation.exit_status == 0, presentation.stdout <> presentation.stderr
      end)

    [_opened, errors] =
      malformed_analysis
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["type"] == "evaluation"))
      |> Enum.map(&get_in(&1, ["result", "value"]))

    [error] = errors["items"]
    assert error["mission_name"] == "repair-0"
    assert error["reason"] == "parse_error"
    assert error["details"]["source_location"] == %{"offset" => 4}
    evaluation_id = error["evaluation_id"]

    assert %{"filters" => %{"evaluation_id" => ^evaluation_id}, "state" => "complete"} =
             Enum.find(error["relationships"], &(&1["rel"] == "failed_generated_source"))

    assert %{
             "filters" => %{
               "evaluation_id" => ^evaluation_id,
               "status" => "evaluation_error"
             },
             "state" => "complete"
           } = Enum.find(error["relationships"], &(&1["rel"] == "evaluation_failure"))

    replay =
      Phase1.run(
        [
          output: Path.join(tmp, "replay"),
          replay: true,
          partial_replay: true,
          fixtures: Path.join(output, "fixtures")
        ] ++ opts
      )

    assert Enum.map(replay, &Map.take(&1, ["candidates", "selection"])) ==
             Enum.map(rows, &Map.take(&1, ["candidates", "selection"]))

    assert Enum.map(replay, &get_in(&1, ["usage", "llm_spend"])) ==
             Enum.map(rows, &get_in(&1, ["usage", "llm_spend"]))

    [fixture] = Path.wildcard(Path.join(output, "fixtures/*.jsonl"))
    File.write!(fixture, File.read!(fixture) <> "\n")
    rejected = Path.join(tmp, "tampered-replay")

    assert_raise RuntimeError, "replay fixture identity changed", fn ->
      Phase1.run(
        [
          output: rejected,
          replay: true,
          partial_replay: true,
          fixtures: Path.join(output, "fixtures")
        ] ++ opts
      )
    end

    reservation = rejected |> Path.join("reservation.json") |> File.read!() |> Jason.decode!()
    assert reservation["reserved_microusd"] == 0
    assert Agent.get(counter, & &1) == 2
  end

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
