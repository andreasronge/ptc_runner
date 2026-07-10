defmodule PtcRunner.Kernel.FeedbackABTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.FeedbackAB
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude

  @variant_paths [
    "priv/kernel_feedback_variants/feedback_a_default.lisp",
    "priv/kernel_feedback_variants/feedback_b_memory_guidance.lisp",
    "priv/kernel_feedback_variants/feedback_c_no_memory_guidance.lisp"
  ]

  test "mock shakedown validates frozen provenance and reports both cells" do
    assert {:ok, result} = FeedbackAB.run(mode: :mock, runs: 1, case: "eval_retry")

    assert result.suite == "mini"
    assert result.mode == :mock
    assert result.model == nil
    assert result.requested_model == nil
    assert result.llm_source == "mock"
    assert result.evidence_eligible == false
    assert result.preregistered_config == false
    assert result.seed == "m2-feedback-ab-order-v1"
    assert length(result.cells) == 3
    assert length(result.rows) == 3
    assert Enum.sort(Enum.map(result.rows, & &1.cell)) == ["A", "B", "C"]
    assert Enum.all?(result.rows, &(&1.case == "eval_retry"))
    assert Enum.all?(result.rows, &(&1.status == :pass))
    assert FeedbackAB.passed?(result)
    assert FeedbackAB.failure_count(result) == 0

    hashes = Map.new(result.rows, &{&1.cell, {&1.prompt_hash, &1.feedback_hash}})

    assert hashes == %{
             "A" =>
               {"9bcaa98e2f05d8a1a08a1f44bbe3b1a5a23b27bbb6af33419d1582f5b1d556eb",
                "c7babc612f8e87a2556898ac4cea31668baa0ff73153636a48b38c1faa74ab0b"},
             "B" =>
               {"9bcaa98e2f05d8a1a08a1f44bbe3b1a5a23b27bbb6af33419d1582f5b1d556eb",
                "d39fae64506909201a5b3c542b504713984656c9f133423d9414138874282c8c"},
             "C" =>
               {"9bcaa98e2f05d8a1a08a1f44bbe3b1a5a23b27bbb6af33419d1582f5b1d556eb",
                "ae83f8c52d178b906e2034c0937b7bc5b516825d4657ac67240e993db6d27e21"}
           }
  end

  test "markdown report is sanitized and labels the result as descriptive" do
    assert {:ok, result} = FeedbackAB.run(mode: :mock, runs: 1, case: "eval_retry")

    markdown = FeedbackAB.render_markdown(result)

    assert markdown =~ "non-M3 descriptive shakedown"
    assert markdown =~ "Canonical TurnEvents may be available for"
    assert markdown =~ "does not supply the preregistered M3 sample"
    assert markdown =~ "| A |"
    assert markdown =~ "| B |"
    assert markdown =~ "| C |"
    refute markdown =~ "(return 3)"
    refute markdown =~ "(defn eval-feedback"
    refute markdown =~ "Previous PTC-Lisp program did not return successfully"
    refute markdown =~ "PTC-Lisp is Clojure-like and runs as an interactive REPL"
    refute markdown =~ "Use value symbols directly"
  end

  test "invalid run setup returns a structured error" do
    assert {:error, {:unknown_case, "missing"}} =
             FeedbackAB.run(mode: :mock, runs: 1, case: "missing")
  end

  test "a partial early-stop schedule is never evidence eligible" do
    eligible_failure = %{status: :fail, provenance_eligible: true, commit: "commit-a"}

    refute FeedbackAB.evidence_eligible?([eligible_failure], nil, 2)
    assert FeedbackAB.evidence_eligible?([eligible_failure], nil, 1)
    refute FeedbackAB.evidence_eligible?([eligible_failure], :transport_failure, 1)

    refute FeedbackAB.evidence_eligible?(
             [eligible_failure, %{eligible_failure | commit: "commit-b"}],
             nil,
             2
           )
  end

  test "evidence eligibility recognizes only the exact preregistered configuration" do
    exact = %{
      suite: "mini",
      mode: :live,
      runs: 5,
      seed: "m2-feedback-ab-order-v1",
      requested_model: "deepseek",
      temperature: 0.0,
      max_tokens: 512,
      receive_timeout: 60_000,
      report: "reports/kernel_eval/m2-feedback-ab-live.md",
      live_llm: nil,
      unsafe_debug_agent: nil,
      stop_on_failure: false,
      case_ids:
        ~w(arithmetic context_filter_count context_aggregation domain_tool eval_retry memory_persistence),
      cell_ids: ~w(A B C),
      case_definition_hash: "754473db7fa9d831a22a5d108765e732b574ac8bfdb283e25ce03472a2da14e5"
    }

    assert FeedbackAB.preregistered_config?(exact)
    refute FeedbackAB.preregistered_config?(%{exact | runs: 1})
    refute FeedbackAB.preregistered_config?(%{exact | case_ids: ["arithmetic"]})
    refute FeedbackAB.preregistered_config?(%{exact | requested_model: "other"})
    refute FeedbackAB.preregistered_config?(%{exact | temperature: 0.1})
    refute FeedbackAB.preregistered_config?(%{exact | max_tokens: 1})
    refute FeedbackAB.preregistered_config?(%{exact | report: nil})
    refute FeedbackAB.preregistered_config?(%{exact | report: "reports/other.md"})

    refute FeedbackAB.preregistered_config?(%{
             exact
             | report: "reports/kernel_eval/s19-feedback-ab-live.md"
           })

    assert FeedbackAB.preregistered_config?(%{
             exact
             | report: "./reports/kernel_eval/m2-feedback-ab-live.md"
           })

    refute FeedbackAB.preregistered_config?(%{exact | live_llm: fn _ -> :ok end})
    refute FeedbackAB.preregistered_config?(%{exact | unsafe_debug_agent: self()})
    refute FeedbackAB.preregistered_config?(%{exact | stop_on_failure: true})
  end

  test "preregistered schedules reject the first ineligible cell provenance" do
    assert {:error, :ineligible_run_provenance} =
             FeedbackAB.require_preregistered_provenance(
               %{provenance_eligible: false},
               require_provenance: true
             )

    assert :ok =
             FeedbackAB.require_preregistered_provenance(
               %{provenance_eligible: true},
               require_provenance: true
             )

    assert :ok =
             FeedbackAB.require_preregistered_provenance(
               %{provenance_eligible: false},
               require_provenance: false
             )
  end

  @tag :tmp_dir
  test "live model resolution loads the dotenv override before choosing a default", %{
    tmp_dir: dir
  } do
    dotenv_key = {PtcRunner.Dotenv, :dotenv_loaded}
    previous_loaded = :persistent_term.get(dotenv_key, :missing)
    previous_model = System.get_env("PTC_TEST_MODEL")

    File.ln_s!(Path.expand("priv"), Path.join(dir, "priv"))
    File.write!(Path.join(dir, ".env"), "PTC_TEST_MODEL=ollama:dotenv-model\n")
    System.delete_env("PTC_TEST_MODEL")
    :persistent_term.erase(dotenv_key)

    on_exit(fn ->
      restore_env("PTC_TEST_MODEL", previous_model)

      case previous_loaded do
        :missing -> :persistent_term.erase(dotenv_key)
        value -> :persistent_term.put(dotenv_key, value)
      end
    end)

    callback = fn _request ->
      {:ok,
       %{
         tool_calls: [
           %{name: "run_ptc_lisp", args: %{"program" => "(return (+ 40 2))"}}
         ]
       }}
    end

    assert {:ok, result} =
             File.cd!(dir, fn ->
               FeedbackAB.run(
                 mode: :live,
                 runs: 1,
                 case: "arithmetic",
                 cell: "A",
                 live_llm: callback
               )
             end)

    assert result.model == "ollama:dotenv-model"
    assert result.llm_source == "injected"
    assert result.evidence_eligible == false
  end

  test "infrastructure abort preserves completed rows and halts the feedback run" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    live_llm = fn _request ->
      call = Agent.get_and_update(calls, fn count -> {count, count + 1} end)

      if call == 0 do
        {:ok,
         %{
           tool_calls: [
             %{name: "run_ptc_lisp", args: %{"program" => "(return (+ 40 2))"}}
           ]
         }}
      else
        {:error, :provider_unavailable}
      end
    end

    assert {:ok, result} =
             FeedbackAB.run(
               mode: :live,
               model: "deepseek",
               runs: 1,
               case: "arithmetic",
               live_llm: live_llm
             )

    assert result.aborted == true
    assert result.llm_source == "injected"
    assert result.evidence_eligible == false
    assert Enum.all?(result.rows, &(&1.llm_source == "injected"))
    assert Enum.all?(result.rows, &(&1.provenance_eligible == false))

    assert {:infrastructure_abort, "arithmetic", 1, cell, "transport_failure"} =
             result.abort_reason

    assert cell in ["A", "B", "C"]
    assert [%{status: :pass, case: "arithmetic"}] = result.rows
    refute FeedbackAB.passed?(result)
    Agent.stop(calls)
  end

  @tag :tmp_dir
  test "raised cell setup failures preserve completed rows in an abort result", %{tmp_dir: dir} do
    assert {:ok, baseline} =
             FeedbackAB.run(mode: :mock, runs: 1, case: "arithmetic")

    [first_cell, failing_cell | _] = Enum.map(baseline.rows, & &1.cell)
    collision = Path.join(dir, "feedback-ab-arithmetic-1-#{failing_cell}-traces")
    File.write!(collision, "not a directory")

    assert {:ok, result} =
             FeedbackAB.run(
               mode: :mock,
               runs: 1,
               case: "arithmetic",
               eval_report_dir: dir
             )

    assert result.aborted == true
    assert [%{cell: ^first_cell, status: :pass}] = result.rows

    assert {:infrastructure_abort, "arithmetic", 1, ^failing_cell, "case_exception:File.Error"} =
             result.abort_reason
  end

  test "trace-integrity failures are infrastructure aborts, not ordinary rows" do
    assert {:error, "trace_integrity_failure"} =
             FeedbackAB.validate_case_integrity(%{
               failure_reason: "trace_integrity_failure",
               write_errors: 0,
               expected_turns: 2,
               actual_turns: 2
             })

    assert {:error, "trace_integrity_failure"} =
             FeedbackAB.validate_case_integrity(%{
               failure_reason: nil,
               write_errors: 1,
               expected_turns: 2,
               actual_turns: 2
             })

    assert :ok =
             FeedbackAB.validate_case_integrity(%{
               failure_reason: "wrong_answer",
               write_errors: 0,
               expected_turns: 2,
               actual_turns: 2
             })
  end

  test "every feedback cell bounds oversized values and prints before encoding" do
    large = String.duplicate("x", 500_000)

    for path <- @variant_paths do
      override = %{
        "agent.feedback" => %{source: File.read!(path), origin: {:file, path}}
      }

      assert {:ok, prelude} = Kernel.compile_prelude(prelude_source_overrides: override)

      assert {:ok, %{kind: :constant}} =
               Prelude.fetch_export(prelude, "agent.feedback/feedback-max-chars")

      assert {:ok, %{kind: :constant}} =
               Prelude.fetch_export(prelude, "agent.feedback/feedback-truncation-hint")

      source =
        ~S|(agent.feedback/eval-feedback {"status" "continue" "value" payload "prints" [payload]} {"protocol_tool_name" "renamed_tool"})|

      assert {:ok, step} =
               Lisp.run(source,
                 prelude: prelude,
                 memory: %{"payload" => large},
                 tools: kernel_private_tools()
               )

      assert String.length(step.return) <= 4_096
      decoded = Jason.decode!(step.return)
      assert decoded["instruction"] =~ "renamed_tool"
      assert decoded["truncated"] == true
      assert decoded["hint"] =~ "smaller intermediate result"
      refute step.return =~ String.duplicate("x", 1_000)

      if path =~ "feedback_c_no_memory_guidance" do
        refute decoded["instruction"] =~ "memory_summary"
        refute decoded["instruction"] =~ "persisted"
        refute decoded["hint"] =~ "persisted"
      end
    end
  end

  test "cell C normal feedback contains no memory-persistence guidance" do
    path = "priv/kernel_feedback_variants/feedback_c_no_memory_guidance.lisp"
    override = %{"agent.feedback" => %{source: File.read!(path), origin: {:file, path}}}
    assert {:ok, prelude} = Kernel.compile_prelude(prelude_source_overrides: override)

    assert {:ok, step} =
             Lisp.run(
               ~S|(agent.feedback/eval-feedback {"status" "continue" "reason" "retry"} {"protocol_tool_name" "run_ptc_lisp"})|,
               prelude: prelude,
               tools: kernel_private_tools()
             )

    decoded = Jason.decode!(step.return)
    refute decoded["instruction"] =~ "memory_summary"
    refute decoded["instruction"] =~ "persisted"
    refute Map.has_key?(decoded, "hint")
  end

  defp kernel_private_tools do
    %{
      "llm-complete" => {fn _args -> %{"kind" => "ok"} end, [visibility: :private]},
      "eval-program" =>
        {fn _args -> %{"status" => "return", "value" => "ok"} end, [visibility: :private]},
      "log" => {fn _args -> %{"ok" => true} end, [visibility: :private]}
    }
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
