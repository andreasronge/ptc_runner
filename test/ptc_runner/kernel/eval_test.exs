defmodule PtcRunner.Kernel.EvalTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Eval
  alias PtcRunner.Kernel.Eval.Oracle
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.PreludeStore
  alias PtcRunner.SubAgent
  alias PtcRunner.TraceLog

  @variant_dir Path.expand("../../../priv/kernel_feedback_variants", __DIR__)
  @feedback_a_path Path.join(@variant_dir, "feedback_a_default.lisp")
  @feedback_b_path Path.join(@variant_dir, "feedback_b_memory_guidance.lisp")

  test "mini suite mock mode reports deterministic per-case counts" do
    assert {:ok, report} = Eval.run(suite: "mini", mode: :mock)

    assert report.suite == "mini"
    assert report.mode == :mock
    assert report.model == nil
    assert report.llm_source == "mock"
    assert report.evidence_eligible == false
    assert report.dataset_seed == 0
    assert report.dataset_hash == nil
    assert report.case_definition_hash =~ ~r/\A[0-9a-f]{64}\z/
    assert report.pass_count == 6
    assert report.case_count == 6
    assert report.pass_rate == 1.0
    assert length(report.cases) == 6
    assert Enum.all?(report.cases, &(&1.status == :pass))
    assert Eval.passed?(report)
    assert Eval.failure_count(report) == 0

    assert Map.new(report.cases, &{&1.case, &1.value}) == %{
             "arithmetic" => 42,
             "context_filter_count" => 2,
             "context_aggregation" => 12,
             "domain_tool" => 9,
             "eval_retry" => 3,
             "memory_persistence" => 41
           }

    retry = Enum.find(report.cases, &(&1.case == "eval_retry"))
    assert retry.action_count == 2
    assert retry.eval_count == 2

    memory = Enum.find(report.cases, &(&1.case == "memory_persistence"))
    assert memory.action_count == 2
    assert memory.eval_count == 2

    for case_result <- report.cases -- [retry, memory] do
      assert case_result.action_count == 1
      assert case_result.eval_count == 1
    end
  end

  test "non-dataset suites use case identity without a misleading dataset hash" do
    assert {:ok, first} = Eval.run(suite: "mini", mode: :mock, seed: 7)
    assert {:ok, second} = Eval.run(suite: "mini", mode: :mock, seed: 7)
    assert {:ok, other} = Eval.run(suite: "mini", mode: :mock, seed: 8)

    assert first.dataset_hash == nil
    assert second.dataset_hash == nil
    assert other.dataset_hash == nil
    assert first.case_definition_hash == second.case_definition_hash
    assert first.case_definition_hash == other.case_definition_hash
    assert first.command_options.seed == 7

    assert {:ok, selected} =
             Eval.run(suite: "mini", mode: :mock, seed: 7, case: "arithmetic")

    assert selected.dataset_hash == first.dataset_hash
    refute selected.case_definition_hash == first.case_definition_hash
  end

  @tag :tmp_dir
  test "Tier 2 runs both variants as one paired experiment", %{tmp_dir: dir} do
    assert {:ok, pair} =
             Eval.run_pair(
               suite: "tier2",
               mode: :mock,
               seed: 17,
               report: Path.join(dir, "pair.md")
             )

    assert [incumbent, kernel] = pair.reports
    assert incumbent.variant == "incumbent"
    assert kernel.variant == "kernel"
    assert pair.complete
    refute pair.aborted
    refute pair.evidence_eligible

    assert kernel.dataset_hash == incumbent.dataset_hash
    assert kernel.dataset_hash =~ ~r/\A[0-9a-f]{64}\z/
    assert kernel.case_definition_hash == incumbent.case_definition_hash
    assert kernel.case_count == 5
    assert incumbent.case_count == 5
    assert kernel.pass_count == 5
    assert incumbent.pass_count == 5
    assert Enum.map(kernel.cases, & &1.case) == Enum.map(incumbent.cases, & &1.case)

    for report <- [kernel, incumbent] do
      cross_dataset = Enum.find(report.cases, &(&1.case == "engineering_expenses"))
      assert cross_dataset.status == :pass
      assert cross_dataset.action_count == 2
      assert cross_dataset.eval_count == 2
    end
  end

  @tag :tmp_dir
  test "transport failures abort remaining cases for both variants and write an aborted report",
       %{
         tmp_dir: dir
       } do
    cases = Enum.take(Eval.mini_cases(), 2)

    for variant <- ["kernel", "incumbent"] do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      live_llm = fn _request ->
        Agent.update(calls, &(&1 + 1))
        {:error, :provider_unavailable}
      end

      report_path = Path.join(dir, "#{variant}-aborted.md")

      assert {:ok, report} =
               Eval.run_cases(cases,
                 mode: :live,
                 variant: variant,
                 model: "ollama:test-model",
                 live_llm: live_llm,
                 report: report_path,
                 trace_dir: Path.join(dir, "#{variant}-traces")
               )

      assert report.aborted == true
      assert report.abort_reason == "transport_failure"

      assert [%{status: :infrastructure_error, failure_reason: "transport_failure"}] =
               report.cases

      assert Agent.get(calls, & &1) == 1
      assert File.read!(report_path) =~ "aborted: true"
      assert Jason.decode!(File.read!(Path.rootname(report_path) <> ".json"))["aborted"] == true
      Agent.stop(calls)
    end
  end

  test "Tier 2 seed-derived oracles reject trivial positive answers" do
    cases = Map.new(Eval.tier2_cases(17), &{&1.id, &1})

    for {case_id, wrong_answer} <- [
          {"delivered_orders", 1},
          {"total_revenue", 1_001},
          {"remote_employees", 1},
          {"engineering_expenses", 1}
        ] do
      assert {:error, reason} =
               Oracle.verify(Map.fetch!(cases, case_id), wrong_answer)

      assert reason =~ "constraint_failed"
    end
  end

  test "evidence eligibility recognizes only preregistered eval configurations" do
    tier2 = %{
      suite: "tier2",
      mode: :live,
      variant: "kernel",
      runs: 1,
      seed: 17,
      requested_model: "deepseek",
      temperature: 0.0,
      max_tokens: 512,
      receive_timeout: 60_000,
      req_http_options: [retry: :transient, max_retries: 3],
      report: "reports/kernel_eval/m2-kernel.md",
      trace_dir: "reports/kernel_eval/m2-kernel-traces",
      prelude_source_overrides: %{},
      role_policy: nil,
      role: nil,
      prelude_store: nil,
      preludes: nil,
      inner_preludes: nil,
      kernel_memory_byte_cap: nil,
      unsafe_debug: false,
      unsafe_debug_agent: nil,
      paired_run: true,
      case_ids:
        ~w(products_count delivered_orders total_revenue remote_employees engineering_expenses),
      case_definition_hash: "4b448ecc370db8260cc8b4537bd7ed61ae9c8c0c0bbec80203d754d362df4431"
    }

    assert Eval.preregistered_config?(tier2)
    assert Eval.preregistered_config?(%{tier2 | variant: "incumbent"})
    refute Eval.preregistered_config?(%{tier2 | runs: 2})
    refute Eval.preregistered_config?(%{tier2 | seed: 18})
    refute Eval.preregistered_config?(%{tier2 | case_ids: ["products_count"]})
    refute Eval.preregistered_config?(%{tier2 | requested_model: "other"})
    refute Eval.preregistered_config?(%{tier2 | temperature: 0.1})
    refute Eval.preregistered_config?(%{tier2 | max_tokens: 1})
    refute Eval.preregistered_config?(%{tier2 | prelude_source_overrides: %{"x" => "y"}})
    refute Eval.preregistered_config?(%{tier2 | kernel_memory_byte_cap: 1_000})
    refute Eval.preregistered_config?(%{tier2 | report: nil})
    refute Eval.preregistered_config?(%{tier2 | trace_dir: nil})
    refute Eval.preregistered_config?(%{tier2 | suite: "custom"})
  end

  test "case definition hash binds explicit tool fixture behavior" do
    cases = Eval.mini_cases()
    original_hash = Eval.case_definition_hash(cases)

    mutated =
      Enum.map(cases, fn
        %{id: "domain_tool"} = eval_case ->
          put_in(eval_case, [:tool_fixtures, "lookup", "alpha", "score"], 10)

        eval_case ->
          eval_case
      end)

    refute Eval.case_definition_hash(mutated) == original_hash
  end

  @tag :tmp_dir
  test "Tier 2 persistence rejects a hard-coded answer gated on the old singleton poison", %{
    tmp_dir: dir
  } do
    eval_case = Enum.find(Eval.tier2_cases(17), &(&1.id == "engineering_expenses"))
    {:between, lower, upper} = eval_case.constraint
    expected = (lower + upper) / 2

    definition =
      ~S|(def engineering-ids (set (map #(% "id") (filter #(= (% "department") "engineering") data/employees))))|

    conditional =
      "(if (= (count engineering-ids) 1) (return 0) (return #{expected}))"

    callback =
      scripted_live_llm([
        %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => definition}}]},
        %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => conditional}}]}
      ])

    assert {:ok, %{cases: [result]}} =
             Eval.run_cases([eval_case],
               suite: "tier2",
               seed: 17,
               mode: :live,
               variant: "kernel",
               model: "ollama:test-model",
               live_llm: callback,
               report: Path.join(dir, "conditional-hardcode.md"),
               trace_dir: Path.join(dir, "conditional-hardcode-traces")
             )

    assert result.status == :fail
    assert result.persistence_verified == false
  end

  @tag :tmp_dir
  test "persistent traces hash catalog arguments instead of retaining them", %{tmp_dir: dir} do
    secret = "CATALOG-SECRET"

    eval_case = %{
      id: "catalog_redaction",
      task: "Inspect the catalog and return one.",
      context: %{},
      expect: :integer,
      constraint: {:eq, 1},
      max_turns: 1,
      mock_programs: [~s|(do (apropos "#{secret}") (return 1))|]
    }

    assert {:ok, %{cases: [%{status: :pass, trace_path: trace_path}]}} =
             Eval.run_cases([eval_case], mode: :mock, trace_dir: dir)

    persisted = File.read!(trace_path)
    refute persisted =~ secret

    turn =
      trace_path
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["event"] == "turn"))

    assert [%{"operation" => "apropos", "args_hash" => hash} = op] =
             turn["data"]["catalog_ops"]

    assert hash =~ ~r/\A[0-9a-f]{64}\z/
    refute Map.has_key?(op, "args")
  end

  test "incumbent variant runs the same canonical cases and oracles" do
    assert {:ok, report} =
             Eval.run(
               suite: "mini",
               case: "context_filter_count",
               mode: :mock,
               variant: "incumbent"
             )

    assert report.variant == "incumbent"
    assert report.command_options.variant == "incumbent"
    assert [%{case: "context_filter_count", status: :pass, value: 2} = result] = report.cases
    assert result.expected_turns == result.actual_turns
    assert File.exists?(result.trace_path)
    assert Path.basename(result.trace_path) =~ "incumbent-context_filter_count"
  end

  @tag :tmp_dir
  test "live adapters preserve model-authored retry workloads for kernel and incumbent", %{
    tmp_dir: dir
  } do
    eval_case = Enum.find(Eval.mini_cases(), &(&1.id == "eval_retry"))

    kernel_llm =
      scripted_live_llm([
        %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => "(+ 1 2)"}}]},
        %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => "(return 3)"}}]}
      ])

    fence = <<96, 96, 96>>

    incumbent_llm =
      scripted_live_llm([
        fence <> "clojure\n(+ 1 2)\n" <> fence,
        fence <> "clojure\n(return 3)\n" <> fence
      ])

    assert {:ok,
            %{
              llm_source: "injected",
              evidence_eligible: false,
              command_options: %{llm_source: "injected"},
              cases: [kernel]
            }} =
             Eval.run_cases([eval_case],
               mode: :live,
               variant: "kernel",
               model: "deepseek",
               live_llm: kernel_llm,
               report: Path.join(dir, "kernel.md"),
               trace_dir: Path.join(dir, "kernel-traces")
             )

    assert {:ok,
            %{
              llm_source: "injected",
              evidence_eligible: false,
              command_options: %{llm_source: "injected"},
              cases: [incumbent]
            }} =
             Eval.run_cases([eval_case],
               mode: :live,
               variant: "incumbent",
               model: "deepseek",
               live_llm: incumbent_llm,
               report: Path.join(dir, "incumbent.md"),
               trace_dir: Path.join(dir, "incumbent-traces")
             )

    for result <- [kernel, incumbent] do
      assert result.status == :pass
      assert result.value == 3
      assert result.action_count == 2
      assert result.eval_count == 2
    end
  end

  @tag :tmp_dir
  test "live Tier 2 cross-dataset adapters honor the model-authored two-turn memory workload", %{
    tmp_dir: dir
  } do
    eval_case = Enum.find(Eval.tier2_cases(17), &(&1.id == "engineering_expenses"))

    final_program =
      ~S|(return (reduce + (map #(% "amount") (filter #(engineering-ids (% "employee_id")) data/expenses))))|

    fence = <<96, 96, 96>>

    callbacks = %{
      "kernel" =>
        scripted_live_llm([
          %{
            tool_calls: [
              %{
                name: "run_ptc_lisp",
                args: %{
                  "program" =>
                    ~S|(def engineering-ids (set (map #(% "id") (filter #(= (% "department") "engineering") data/employees))))|
                }
              }
            ]
          },
          %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => final_program}}]}
        ]),
      "incumbent" =>
        scripted_live_llm([
          fence <>
            "clojure\n" <>
            ~S|(def engineering-ids (set (map #(% "id") (filter #(= (% "department") "engineering") data/employees))))| <>
            "\n" <> fence,
          fence <> "clojure\n" <> final_program <> "\n" <> fence
        ])
    }

    for {variant, callback} <- callbacks do
      assert {:ok, %{cases: [result]}} =
               Eval.run_cases([eval_case],
                 suite: "tier2",
                 seed: 17,
                 mode: :live,
                 variant: variant,
                 model: "ollama:test-model",
                 live_llm: callback,
                 report: Path.join(dir, "#{variant}-engineering.md"),
                 trace_dir: Path.join(dir, "#{variant}-engineering-traces")
               )

      assert result.status == :pass
      assert result.eval_count == 2
      assert result.action_count == 2
      assert result.persistence_verified == true
    end
  end

  @tag :tmp_dir
  test "Tier 2 memory workload rejects two turns that do not persist the required name", %{
    tmp_dir: dir
  } do
    eval_case = Enum.find(Eval.tier2_cases(17), &(&1.id == "engineering_expenses"))
    {:between, lower, upper} = eval_case.constraint
    expected = (lower + upper) / 2
    fence = <<96, 96, 96>>

    callbacks = %{
      "kernel" =>
        scripted_live_llm([
          %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => "(def irrelevant 1)"}}]},
          %{
            tool_calls: [
              %{name: "run_ptc_lisp", args: %{"program" => "(return #{expected})"}}
            ]
          }
        ]),
      "incumbent" =>
        scripted_live_llm([
          fence <> "clojure\n(def irrelevant 1)\n" <> fence,
          fence <> "clojure\n(return #{expected})\n" <> fence
        ])
    }

    for {variant, callback} <- callbacks do
      assert {:ok, %{cases: [result]}} =
               Eval.run_cases([eval_case],
                 suite: "tier2",
                 seed: 17,
                 mode: :live,
                 variant: variant,
                 model: "ollama:test-model",
                 live_llm: callback,
                 report: Path.join(dir, "#{variant}-adversarial.md"),
                 trace_dir: Path.join(dir, "#{variant}-adversarial-traces")
               )

      assert result.status == :fail, "#{variant}: #{inspect(result)}"
      assert result.failure_reason == "required_persisted_value_not_defined"
      assert result.persistence_verified == false
    end
  end

  @tag :tmp_dir
  test "Tier 2 memory workload rejects a quoted persisted-name mention", %{tmp_dir: dir} do
    eval_case = Enum.find(Eval.tier2_cases(17), &(&1.id == "engineering_expenses"))
    {:between, lower, upper} = eval_case.constraint
    expected = (lower + upper) / 2

    definition =
      ~S|(def engineering-ids (set (map #(% "id") (filter #(= (% "department") "engineering") data/employees))))|

    quoted_return = "(do (quote engineering-ids) (return #{expected}))"
    fence = <<96, 96, 96>>

    callbacks = %{
      "kernel" =>
        scripted_live_llm([
          %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => definition}}]},
          %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => quoted_return}}]}
        ]),
      "incumbent" =>
        scripted_live_llm([
          fence <> "clojure\n" <> definition <> "\n" <> fence,
          fence <> "clojure\n" <> quoted_return <> "\n" <> fence
        ])
    }

    for {variant, callback} <- callbacks do
      assert {:ok, %{cases: [result]}} =
               Eval.run_cases([eval_case],
                 suite: "tier2",
                 seed: 17,
                 mode: :live,
                 variant: variant,
                 model: "ollama:test-model",
                 live_llm: callback,
                 report: Path.join(dir, "#{variant}-quoted.md"),
                 trace_dir: Path.join(dir, "#{variant}-quoted-traces")
               )

      assert result.status == :fail, "#{variant}: #{inspect(result)}"
      assert result.failure_reason == "required_persisted_name_not_reused"
      assert result.persistence_verified == false
    end
  end

  @tag :tmp_dir
  test "Tier 2 memory workload rejects poisoned dead work followed by a hard-coded answer", %{
    tmp_dir: dir
  } do
    eval_case = Enum.find(Eval.tier2_cases(17), &(&1.id == "engineering_expenses"))
    {:between, lower, upper} = eval_case.constraint
    expected = (lower + upper) / 2

    definition =
      ~S|(def engineering-ids (set (map #(% "id") (filter #(= (% "department") "engineering") data/employees))))|

    hardcoded = "(do (/ 1 (count engineering-ids)) (return #{expected}))"
    fence = <<96, 96, 96>>

    callbacks = %{
      "kernel" =>
        scripted_live_llm([
          %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => definition}}]},
          %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => hardcoded}}]}
        ]),
      "incumbent" =>
        scripted_live_llm([
          fence <> "clojure\n" <> definition <> "\n" <> fence,
          fence <> "clojure\n" <> hardcoded <> "\n" <> fence
        ])
    }

    for {variant, callback} <- callbacks do
      assert {:ok, %{cases: [result]}} =
               Eval.run_cases([eval_case],
                 suite: "tier2",
                 seed: 17,
                 mode: :live,
                 variant: variant,
                 model: "ollama:test-model",
                 live_llm: callback,
                 report: Path.join(dir, "#{variant}-hardcoded.md"),
                 trace_dir: Path.join(dir, "#{variant}-hardcoded-traces")
               )

      assert result.status == :fail, "#{variant}: #{inspect(result)}"
      assert result.failure_reason == "required_persisted_name_not_reused"
      assert result.persistence_verified == false
    end
  end

  @tag :tmp_dir
  test "Tier 2 memory workload accepts a retry before the first committed definition", %{
    tmp_dir: dir
  } do
    eval_case = Enum.find(Eval.tier2_cases(17), &(&1.id == "engineering_expenses"))

    definition =
      ~S|(def engineering-ids (set (map #(% "id") (filter #(= (% "department") "engineering") data/employees))))|

    final_program =
      ~S|(return (reduce + (map #(% "amount") (filter #(engineering-ids (% "employee_id")) data/expenses))))|

    fence = <<96, 96, 96>>

    callbacks = %{
      "kernel" =>
        scripted_live_llm([
          %{content: "not a tool call"},
          %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => definition}}]},
          %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => final_program}}]}
        ]),
      "incumbent" =>
        scripted_live_llm([
          "not lisp ((",
          fence <> "clojure\n" <> definition <> "\n" <> fence,
          fence <> "clojure\n" <> final_program <> "\n" <> fence
        ])
    }

    for {variant, callback} <- callbacks do
      assert {:ok, %{cases: [result]}} =
               Eval.run_cases([eval_case],
                 suite: "tier2",
                 seed: 17,
                 mode: :live,
                 variant: variant,
                 model: "ollama:test-model",
                 live_llm: callback,
                 report: Path.join(dir, "#{variant}-retry-before-definition.md"),
                 trace_dir: Path.join(dir, "#{variant}-retry-before-definition-traces")
               )

      assert result.status == :pass
      assert result.persistence_verified == true
      assert result.action_count == 3
    end
  end

  @tag :tmp_dir
  test "Tier 2 memory workload rejects a destructuring shadow of the persisted name", %{
    tmp_dir: dir
  } do
    eval_case = Enum.find(Eval.tier2_cases(17), &(&1.id == "engineering_expenses"))
    {:between, lower, upper} = eval_case.constraint
    expected = (lower + upper) / 2

    callback =
      scripted_live_llm([
        %{
          tool_calls: [
            %{
              name: "run_ptc_lisp",
              args: %{
                "program" =>
                  ~S|(def engineering-ids (set (map #(% "id") (filter #(= (% "department") "engineering") data/employees))))|
              }
            }
          ]
        },
        %{
          tool_calls: [
            %{
              name: "run_ptc_lisp",
              args: %{
                "program" => "(let [[engineering-ids] [[1]]] (return #{expected}))"
              }
            }
          ]
        }
      ])

    assert {:ok, %{cases: [result]}} =
             Eval.run_cases([eval_case],
               suite: "tier2",
               seed: 17,
               mode: :live,
               variant: "kernel",
               model: "ollama:test-model",
               live_llm: callback,
               report: Path.join(dir, "kernel-shadow.md"),
               trace_dir: Path.join(dir, "kernel-shadow-traces")
             )

    assert result.status == :fail
    assert result.failure_reason == "required_persisted_name_not_reused"
    assert result.persistence_verified == false
  end

  @tag :tmp_dir
  test "Tier 2 memory workload rejects dead references followed by recomputation", %{
    tmp_dir: dir
  } do
    eval_case = Enum.find(Eval.tier2_cases(17), &(&1.id == "engineering_expenses"))

    recompute =
      ~S|(do (if false engineering-ids nil) (let [fresh-ids (set (map #(% "id") (filter #(= (% "department") "engineering") data/employees)))] (return (reduce + (map #(% "amount") (filter #(fresh-ids (% "employee_id")) data/expenses))))))|

    callback =
      scripted_live_llm([
        %{
          tool_calls: [
            %{
              name: "run_ptc_lisp",
              args: %{
                "program" =>
                  ~S|(def engineering-ids (set (map #(% "id") (filter #(= (% "department") "engineering") data/employees))))|
              }
            }
          ]
        },
        %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => recompute}}]}
      ])

    assert {:ok, %{cases: [result]}} =
             Eval.run_cases([eval_case],
               suite: "tier2",
               seed: 17,
               mode: :live,
               variant: "kernel",
               model: "ollama:test-model",
               live_llm: callback,
               report: Path.join(dir, "kernel-recompute.md"),
               trace_dir: Path.join(dir, "kernel-recompute-traces")
             )

    assert result.status == :fail
    assert result.failure_reason == "required_persisted_name_not_reused"
    assert result.persistence_verified == false
  end

  @tag :tmp_dir
  test "Tier 2 memory workload rejects a rolled-back definition", %{tmp_dir: dir} do
    eval_case = Enum.find(Eval.tier2_cases(17), &(&1.id == "engineering_expenses"))
    {:between, lower, upper} = eval_case.constraint
    expected = (lower + upper) / 2

    callback =
      scripted_live_llm([
        %{
          tool_calls: [
            %{
              name: "run_ptc_lisp",
              args: %{
                "program" => ~S|(def engineering-ids #{1}) (def too-big (range 0 5000))|
              }
            }
          ]
        },
        %{
          tool_calls: [
            %{name: "run_ptc_lisp", args: %{"program" => "(return #{expected})"}}
          ]
        }
      ])

    assert {:ok, %{cases: [result]}} =
             Eval.run_cases([eval_case],
               suite: "tier2",
               seed: 17,
               mode: :live,
               variant: "kernel",
               model: "ollama:test-model",
               live_llm: callback,
               kernel_memory_byte_cap: 1_000,
               report: Path.join(dir, "kernel-rollback.md"),
               trace_dir: Path.join(dir, "kernel-rollback-traces")
             )

    assert result.status == :fail
    assert result.persistence_verified == false
  end

  @tag :tmp_dir
  test "Tier 2 memory workload rejects backup state defined beside the required value", %{
    tmp_dir: dir
  } do
    eval_case = Enum.find(Eval.tier2_cases(17), &(&1.id == "engineering_expenses"))

    definition =
      ~S|(def engineering-ids (set (map #(% "id") (filter #(= (% "department") "engineering") data/employees)))) (def backup-ids engineering-ids)|

    final_program =
      ~S|(do engineering-ids (return (reduce + (map #(% "amount") (filter #(backup-ids (% "employee_id")) data/expenses)))))|

    callback =
      scripted_live_llm([
        %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => definition}}]},
        %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => final_program}}]}
      ])

    assert {:ok, %{cases: [result]}} =
             Eval.run_cases([eval_case],
               suite: "tier2",
               seed: 17,
               mode: :live,
               variant: "kernel",
               model: "ollama:test-model",
               live_llm: callback,
               report: Path.join(dir, "kernel-backup.md"),
               trace_dir: Path.join(dir, "kernel-backup-traces")
             )

    assert result.status == :fail
    assert result.failure_reason == "required_persisted_value_not_defined"
    assert result.persistence_verified == false
  end

  @tag :tmp_dir
  test "Tier 2 run_cases requires case-bound dataset seed metadata", %{tmp_dir: dir} do
    cases = Eval.tier2_cases(17)
    report = Path.join(dir, "tier2.md")

    assert {:error, :tier2_seed_required} =
             Eval.run_cases(cases, suite: "tier2", mode: :mock, report: report)

    assert {:error, {:tier2_seed_mismatch, 18, [17]}} =
             Eval.run_cases(cases,
               suite: "tier2",
               seed: 18,
               mode: :mock,
               report: report
             )
  end

  @tag :tmp_dir
  test "Tier 2 run_cases rejects context that does not match the seeded dataset", %{tmp_dir: dir} do
    [eval_case | rest] = Eval.tier2_cases(17)
    mutated = put_in(eval_case, [:context, "products"], [])

    assert {:error, {:tier2_dataset_mismatch, ["products_count"]}} =
             Eval.run_cases([mutated | rest],
               suite: "tier2",
               seed: 17,
               mode: :mock,
               report: Path.join(dir, "mutated.md")
             )
  end

  @tag :tmp_dir
  test "Tier 2 full suite rejects definitions that differ from preregistered hashes", %{
    tmp_dir: dir
  } do
    [eval_case | rest] = Eval.tier2_cases(17)
    mutated = %{eval_case | task: eval_case.task <> " Changed after preregistration."}

    assert {:error,
            {:tier2_preregistration_hash_mismatch,
             %{
               dataset_hash: "503d8233cce08aa825a00e14d49c6e13d2a9db931fa219a8cc3500866e8a0953",
               case_definition_hash: actual
             }}} =
             Eval.run_cases([mutated | rest],
               suite: "tier2",
               seed: 17,
               mode: :mock,
               report: Path.join(dir, "mutated-definition.md")
             )

    assert actual =~ ~r/\A[0-9a-f]{64}\z/
    refute actual == "4b448ecc370db8260cc8b4537bd7ed61ae9c8c0c0bbec80203d754d362df4431"
  end

  @tag :tmp_dir
  test "incumbent setup cleans linked agents when trace initialization raises", %{tmp_dir: dir} do
    trace_file = Path.join(dir, "not-a-directory")
    File.write!(trace_file, "occupied")
    links_before = self() |> Process.info(:links) |> elem(1) |> MapSet.new()

    eval_case = %{
      id: "cleanup",
      task: "Return one.",
      context: %{},
      expect: :integer,
      constraint: {:eq, 1},
      max_turns: 1,
      mock_programs: ["(return 1)"]
    }

    assert {:ok, report} =
             Eval.run_cases([eval_case],
               mode: :mock,
               variant: "incumbent",
               trace_dir: trace_file
             )

    assert report.aborted

    assert [%{status: :infrastructure_error, failure_reason: "case_exception:File.Error"}] =
             report.cases

    links_after = self() |> Process.info(:links) |> elem(1) |> MapSet.new()
    assert links_after == links_before
  end

  test "kernel setup cleans linked agents when mock LLM initialization raises" do
    eval_case = Eval.mini_cases() |> hd() |> Map.delete(:mock_programs)
    links_before = self() |> Process.info(:links) |> elem(1) |> MapSet.new()

    assert {:ok, report} = Eval.run_cases([eval_case], mode: :mock, variant: "kernel")
    assert report.aborted

    assert [%{status: :infrastructure_error, failure_reason: "case_exception:KeyError"}] =
             report.cases

    links_after = self() |> Process.info(:links) |> elem(1) |> MapSet.new()
    assert links_after == links_before
  end

  @tag :tmp_dir
  test "unexpected later case exceptions preserve completed rows and write an aborted report", %{
    tmp_dir: dir
  } do
    [passing | _] = Eval.mini_cases()
    crashing = passing |> Map.put(:id, "crashing") |> Map.delete(:mock_programs)
    report_path = Path.join(dir, "partial.md")

    assert {:ok, report} =
             Eval.run_cases([passing, crashing],
               mode: :mock,
               variant: "kernel",
               report: report_path
             )

    assert report.aborted
    assert [%{status: :pass}, %{failure_reason: "case_exception:KeyError"}] = report.cases
    assert File.read!(report_path) =~ "case_exception:KeyError"
    assert Jason.decode!(File.read!(Path.rootname(report_path) <> ".json"))["aborted"]
  end

  @tag :tmp_dir
  test "paired canonical artifacts are create-once", %{tmp_dir: dir} do
    report = Path.join(dir, "pair.md")

    assert {:ok, _pair} = Eval.run_pair(mode: :mock, seed: 17, report: report)

    assert_raise ArgumentError, ~r/canonical experiment artifact already exists/, fn ->
      Eval.run_pair(mode: :mock, seed: 17, report: report)
    end
  end

  @tag :tmp_dir
  test "paired reports reject JSON paths before running cases", %{tmp_dir: dir} do
    report = Path.join(dir, "pair.json")

    assert {:error, {:invalid_report_path, ^report}} =
             Eval.run_pair(mode: :mock, seed: 17, report: report)

    refute File.exists?(report)
  end

  test "incumbent trace integrity counts only the measured outer SubAgent" do
    nested_tool = fn _args ->
      assert {:ok, step} =
               SubAgent.run("Return seven.",
                 name: "kernel_eval_incumbent",
                 llm: fn _request -> {:ok, "```clojure\n(return 7)\n```"} end,
                 max_turns: 1,
                 completion_mode: :explicit
               )

      step.return
    end

    eval_case = %{
      id: "nested_incumbent_trace",
      task: "Call the nested tool and return its value.",
      context: %{},
      tools: %{"nested" => nested_tool},
      expect: :integer,
      constraint: {:eq, 7},
      max_turns: 2,
      mock_programs: ["(return (tool/nested {}))"]
    }

    assert {:ok, %{cases: [result]}} =
             Eval.run_cases([eval_case], variant: "incumbent", mode: :mock)

    assert result.status == :pass
    assert result.expected_turns == 1
    assert result.actual_turns == 1
    assert result.action_count == 1
    assert result.eval_count == 1
  end

  test "kernel trace integrity counts only the measured outer kernel run" do
    nested_tool = fn _args ->
      nested_llm = fn _request ->
        {:ok,
         %{
           tool_calls: [
             %{name: "run_ptc_lisp", args: %{"program" => "(return 7)"}}
           ]
         }}
      end

      assert {:ok, %{"value" => 7}} = Kernel.run(%{"task" => "Return seven."}, llm: nested_llm)
      7
    end

    eval_case = %{
      id: "nested_kernel_trace",
      task: "Call the nested tool and return its value.",
      context: %{},
      tools: %{"nested" => nested_tool},
      expect: :integer,
      constraint: {:eq, 7},
      max_turns: 2,
      mock_programs: ["(return (tool/nested {}))"]
    }

    assert {:ok, %{cases: [result]}} =
             Eval.run_cases([eval_case], variant: "kernel", mode: :mock)

    assert result.status == :pass
    assert result.expected_turns == 1
    assert result.actual_turns == 1
    assert result.action_count == 1
    assert result.eval_count == 1
  end

  test "incumbent eval count excludes attempts where no program ran" do
    eval_case = %{
      id: "incumbent_parse_retry",
      task: "Return seven.",
      context: %{},
      expect: :integer,
      constraint: {:eq, 7},
      max_turns: 2,
      mock_programs: [],
      mock_incumbent_responses: ["I will answer in prose.", "```clojure\n(return 7)\n```"]
    }

    assert {:ok, %{cases: [result]}} =
             Eval.run_cases([eval_case], variant: "incumbent", mode: :mock)

    assert result.status == :pass
    assert result.action_count == 2
    assert result.eval_count == 1
  end

  @tag :tmp_dir
  test "smoke suite writes sanitized markdown, JSON twin, and persistent canonical traces", %{
    tmp_dir: dir
  } do
    report_path = Path.join(dir, "m1-smoke.md")
    trace_dir = Path.join(dir, "traces")

    assert {:ok, report} =
             Eval.run(
               suite: "smoke",
               mode: :mock,
               variant: "kernel",
               report: report_path,
               trace_dir: trace_dir
             )

    assert report.suite == "smoke"
    assert report.variant == "kernel"
    assert report.commit =~ ~r/\A[0-9a-f]{40}\z/
    assert report.command_options.variant == "kernel"
    assert report.command_options.suite == "smoke"
    assert [%{case: "record_count_500", status: :pass, value: 250} = run] = report.cases
    assert run.expected_turns == 1
    assert run.actual_turns == 1
    assert run.dropped_turns == 0
    assert run.unexpected_turns == 0
    assert run.write_errors == 0
    assert length(run.prompt_hashes) == 1
    assert length(run.action_hashes) == 1
    assert Enum.all?(run.prompt_hashes ++ run.action_hashes, &(&1 =~ ~r/\A[0-9a-f]{64}\z/))
    assert File.exists?(run.trace_path)
    assert Path.dirname(run.trace_path) == trace_dir

    json_path = Path.rootname(report_path) <> ".json"
    assert File.exists?(report_path)
    assert File.exists?(json_path)

    markdown = File.read!(report_path)
    json = File.read!(json_path)
    traces = trace_dir |> Path.join("*.jsonl") |> Path.wildcard() |> Enum.map_join(&File.read!/1)

    for forbidden <- [
          "OPENROUTER_API_KEY",
          "sk-or-",
          "You are controlling PTC-Lisp",
          "mock_programs",
          "(return",
          "messages"
        ] do
      refute markdown =~ forbidden
      refute json =~ forbidden
      refute traces =~ forbidden
    end

    refute markdown =~ "tool_calls"
    refute json =~ "tool_calls"

    assert traces =~ "program_hash"
    assert traces =~ "result_hash"
    assert traces =~ ~s|"projection":{"name":"m2_evidence_turn","version":1}|
    refute traces =~ "result_preview"
    refute traces =~ "changed_keys"

    decoded = Jason.decode!(json)

    assert decoded["cases"] |> hd() |> Map.fetch!("expected_result") == %{
             "expect" => "integer",
             "constraint" => %{"kind" => "eq", "value" => 250}
           }

    assert decoded["cases"] |> hd() |> Map.fetch!("actual_result") == %{
             "type" => "integer",
             "value" => 250
           }

    assert decoded["cases"] |> hd() |> Map.fetch!("inner_prelude_call_counts") == %{}
    assert is_list(decoded["cases"] |> hd() |> Map.fetch!("preludes"))
    assert is_list(decoded["cases"] |> hd() |> Map.fetch!("inner_preludes"))
  end

  test "smoke and live runs require the report contract and reject unknown variants" do
    assert {:error, {:report_required, "smoke"}} =
             Eval.run(suite: "smoke", mode: :mock, variant: "kernel")

    assert {:error, {:report_required, "tier2"}} =
             Eval.run(suite: "tier2", mode: :mock, variant: "kernel")

    assert {:error, {:unsupported_variant, "unknown"}} =
             Eval.run(suite: "mini", mode: :mock, variant: "unknown")

    assert {:error, {:report_required, "mini"}} =
             Eval.run(suite: "mini", mode: :live, variant: "kernel")

    assert {:error, {:report_required, "smoke"}} =
             Eval.run_cases(Eval.smoke_cases(), suite: "smoke", mode: :mock)
  end

  test "trace-integrity loss fails the report even when the oracle passed" do
    report = %{
      cases: [
        %{status: :pass, expected_turns: 1, actual_turns: 0, write_errors: 0}
      ]
    }

    refute Eval.passed?(report)
    assert Eval.failure_count(report) == 1

    for original <- [
          {:pass, nil, nil},
          {:fail, "wrong_answer", "failure-hash"}
        ] do
      assert {:infrastructure_error, "trace_integrity_failure", nil} =
               Eval.enforce_trace_integrity(original, 1, 0, 0)

      assert {:infrastructure_error, "trace_integrity_failure", nil} =
               Eval.enforce_trace_integrity(original, 0, 1, 0)

      assert {:infrastructure_error, "trace_integrity_failure", nil} =
               Eval.enforce_trace_integrity(original, 0, 0, 1)
    end
  end

  test "default markdown report is sanitized" do
    assert {:ok, report} = Eval.run(suite: "mini", mode: :mock)

    markdown = Eval.render_markdown(report)
    json = Jason.encode!(report)

    assert markdown =~ "context_filter_count"
    assert markdown =~ "domain_tool"
    assert markdown =~ "memory_persistence"
    assert markdown =~ "provenance_eligible: #{report.provenance_eligible}"
    assert markdown =~ "evidence_eligible: #{report.evidence_eligible}"
    assert markdown =~ "preregistered_config: #{report.preregistered_config}"
    assert Jason.decode!(json)["provenance_eligible"] == report.provenance_eligible
    assert Jason.decode!(json)["evidence_eligible"] == report.evidence_eligible
    assert Jason.decode!(json)["preregistered_config"] == report.preregistered_config
    refute markdown =~ "OPENROUTER_API_KEY"
    refute markdown =~ "sk-or-"
    refute markdown =~ "You are controlling PTC-Lisp"
    refute markdown =~ "messages"
    refute markdown =~ "tool_calls"
    refute markdown =~ "(return (+ 40 2))"
  end

  test "model seam resolves aliases through the registry" do
    assert {:ok, "openrouter:deepseek/deepseek-v4-flash"} = Eval.resolve_model("deepseek")
  end

  test "unknown case fails instead of producing an empty passing report" do
    assert {:error, {:unknown_case, "missing"}} =
             Eval.run(suite: "mini", mode: :mock, case: "missing")
  end

  test "mock cases fail when returned value does not match expected value" do
    wrong_case = %{
      id: "wrong_answer",
      task: "Return the integer result of 40 + 2.",
      context: %{},
      expect: :integer,
      constraint: {:eq, 42},
      max_turns: 3,
      mock_programs: [~S|(return 0)|]
    }

    assert {:ok, report} = Eval.run_cases([wrong_case], mode: :mock)
    assert [case_result] = report.cases
    assert case_result.status == :fail
    assert case_result.value == 0
    assert case_result.failure_reason == "constraint_failed:eq"
    refute Eval.passed?(report)
    assert Eval.failure_count(report) == 1
  end

  @tag :tmp_dir
  test "mock report trace redacts raw host-held memory values", %{tmp_dir: dir} do
    secret = String.duplicate("SECRET-TRACE-", 40)

    memory_case = %{
      id: "redacted_memory",
      task: "Store a large value, then return ok.",
      context: %{},
      expect: :string,
      constraint: {:eq, "ok"},
      max_turns: 3,
      mock_programs: [~s|(do (def payload "#{secret}") (return :ok))|]
    }

    assert {:ok, report} = Eval.run_cases([memory_case], mode: :mock, trace_dir: dir)
    assert [%{status: :pass, trace: trace}] = report.cases
    inspected = inspect(trace)

    refute inspected =~ secret
    refute inspected =~ "payload"
    assert Enum.any?(trace, &(&1.event == "memory"))

    persisted = report.cases |> hd() |> Map.fetch!(:trace_path) |> File.read!()
    refute persisted =~ secret
    assert persisted =~ ~s|"changed_keys":["payload"]|
  end

  @tag :tmp_dir
  test "persistent traces discard nested non-turn telemetry payloads", %{tmp_dir: dir} do
    secret = "NESTED-TRACE-SECRET"

    eval_case = %{
      id: "nested_trace_redaction",
      task: "Call the granted tool and return one.",
      context: %{},
      tools: %{
        "leak" => fn _args ->
          TraceLog.write_to_active(%{
            "event" => "llm.stop",
            "data" => %{"messages" => secret, "result" => secret}
          })

          %{"ok" => true}
        end
      },
      expect: :integer,
      constraint: {:eq, 1},
      max_turns: 1,
      mock_programs: ["(do (tool/leak {}) (return 1))"]
    }

    assert {:ok, %{cases: [%{status: :pass, trace_path: trace_path}]}} =
             Eval.run_cases([eval_case], mode: :mock, trace_dir: dir)

    persisted = File.read!(trace_path)
    refute persisted =~ secret
    refute persisted =~ "llm.stop"
    assert persisted =~ ~s("event":"turn")
  end

  @tag :tmp_dir
  test "persistent traces hash model-controlled failure reasons", %{tmp_dir: dir} do
    secret = "PERSISTED-FAIL-SECRET"

    eval_case = %{
      id: "failure_reason_redaction",
      task: "Fail with the supplied reason.",
      context: %{},
      expect: :integer,
      constraint: {:eq, 1},
      max_turns: 1,
      mock_programs: [~s|(fail {"reason" "#{secret}"})|]
    }

    assert {:ok, %{cases: [%{status: :fail, trace_path: trace_path}]}} =
             Eval.run_cases([eval_case], mode: :mock, trace_dir: dir)

    persisted = File.read!(trace_path)
    refute persisted =~ secret

    turn =
      trace_path
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["event"] == "turn"))

    assert turn["data"]["fail"]["reason"] == "kernel_failure"
    assert turn["data"]["fail"]["reason_hash"] =~ ~r/\A[0-9a-f]{64}\z/
  end

  @tag :tmp_dir
  test "reports hash non-string model-controlled failure reasons", %{tmp_dir: dir} do
    secret = "PERSISTED-REPORT-FAIL-SECRET"
    report_path = Path.join(dir, "failure.md")

    core = ~s|(ns agent.core "Failure projection." {:visibility :prompt})
               (defn run-mission [_mission _cfg]
                 (fail {"reason" ["#{secret}"]}))|

    eval_case = %{
      id: "failure_report_redaction",
      task: "Fail.",
      context: %{},
      expect: :integer,
      constraint: {:eq, 1},
      max_turns: 1,
      mock_programs: ["(return 1)"]
    }

    assert {:ok, %{cases: [%{status: :fail} = result]}} =
             Eval.run_cases([eval_case],
               mode: :mock,
               report: report_path,
               trace_dir: Path.join(dir, "traces"),
               prelude_source_overrides: %{"agent.core" => core}
             )

    assert result.failure_reason == "kernel_failure"
    assert result.failure_hash =~ ~r/\A[0-9a-f]{64}\z/

    markdown = File.read!(report_path)
    json = File.read!(Path.rootname(report_path) <> ".json")
    refute markdown =~ secret
    refute json =~ secret
    assert markdown =~ result.failure_hash
    assert json =~ result.failure_hash
  end

  @tag :tmp_dir
  test "reports hash expected string oracle values", %{tmp_dir: dir} do
    secret = "EXPECTED-SECRET-" <> String.duplicate("x", 80)
    report_path = Path.join(dir, "expected-secret.md")

    eval_case = %{
      id: "expected_secret",
      task: "Return the expected value.",
      context: %{},
      expect: :string,
      constraint: {:eq, secret},
      max_turns: 1,
      mock_programs: [~s|(return "#{secret}")|]
    }

    assert {:ok, %{cases: [%{status: :pass}]}} =
             Eval.run_cases([eval_case],
               mode: :mock,
               report: report_path,
               trace_dir: Path.join(dir, "traces")
             )

    markdown = File.read!(report_path)
    json = File.read!(Path.rootname(report_path) <> ".json")
    refute markdown =~ secret
    refute json =~ secret
    assert markdown =~ "hash"
    assert json =~ "hash"
  end

  @tag :tmp_dir
  test "reports redact malformed oracle terms from failure reasons", %{tmp_dir: dir} do
    secret = "MALFORMED-ORACLE-SECRET"
    report_path = Path.join(dir, "malformed-oracle.md")

    eval_case = %{
      id: "malformed_oracle",
      task: "Return one.",
      context: %{},
      expect: secret,
      constraint: {:unsupported, secret},
      max_turns: 1,
      mock_programs: ["(return 1)"]
    }

    assert {:ok, %{cases: [%{status: :fail, failure_reason: "unknown_expect"}]}} =
             Eval.run_cases([eval_case],
               mode: :mock,
               report: report_path,
               trace_dir: Path.join(dir, "traces")
             )

    refute File.read!(report_path) =~ secret
    refute File.read!(Path.rootname(report_path) <> ".json") =~ secret
  end

  @tag :tmp_dir
  test "report path cannot collide with its JSON twin", %{tmp_dir: dir} do
    path = Path.join(dir, "smoke.json")

    assert {:error, {:invalid_report_path, ^path}} =
             Eval.run(suite: "smoke", mode: :mock, report: path)

    refute File.exists?(path)
  end

  @tag :tmp_dir
  test "concurrent dotenv model identities wait for the selected model", %{tmp_dir: dir} do
    dotenv_key = {PtcRunner.Dotenv, :dotenv_loaded}
    previous_loaded = :persistent_term.get(dotenv_key, :missing)
    previous_model = System.get_env("PTC_TEST_MODEL")

    File.write!(
      Path.join(dir, ".env"),
      String.duplicate("# keep loader busy\n", 100_000) <> "PTC_TEST_MODEL=openai:gpt\n"
    )

    System.delete_env("PTC_TEST_MODEL")
    :persistent_term.erase(dotenv_key)

    on_exit(fn ->
      restore_env("PTC_TEST_MODEL", previous_model)

      case previous_loaded do
        :missing -> :persistent_term.erase(dotenv_key)
        value -> :persistent_term.put(dotenv_key, value)
      end
    end)

    identities =
      File.cd!(dir, fn ->
        parent = self()

        tasks =
          for _ <- 1..20 do
            Task.async(fn ->
              send(parent, {:ready, self()})

              receive do
                :go -> Eval.resolve_model_identity(nil)
              end
            end)
          end

        pids = for _ <- tasks, do: receive(do: ({:ready, pid} -> pid))
        Enum.each(pids, &send(&1, :go))
        Enum.map(tasks, &Task.await(&1, 10_000))
      end)

    assert identities ==
             List.duplicate({:ok, "openai:gpt", "openai:gpt-4.1-mini"}, 20)
  end

  test "feedback variant swap changes only the feedback component hash" do
    {:ok, prelude_a} =
      Kernel.compile_prelude(prelude_source_overrides: feedback_override(@feedback_a_path))

    {:ok, prelude_b} =
      Kernel.compile_prelude(prelude_source_overrides: feedback_override(@feedback_b_path))

    components_a = components_by_id(Prelude.trace_summary(prelude_a))
    components_b = components_by_id(Prelude.trace_summary(prelude_b))

    assert components_a["agent.prompt"].source_hash == components_b["agent.prompt"].source_hash
    assert components_a["agent.core"].source_hash == components_b["agent.core"].source_hash

    refute components_a["agent.feedback"].source_hash ==
             components_b["agent.feedback"].source_hash

    assert components_a["agent.feedback"].origin ==
             "file:priv/kernel_feedback_variants/feedback_a_default.lisp"

    assert components_b["agent.feedback"].origin ==
             "file:priv/kernel_feedback_variants/feedback_b_memory_guidance.lisp"

    assert components_a["agent.feedback"].source_hash == sha256_file(@feedback_a_path)
    assert components_b["agent.feedback"].source_hash == sha256_file(@feedback_b_path)
  end

  test "sanitized mock report attributes the run to the feedback variant source hash" do
    assert {:ok, report_a} =
             Eval.run(
               suite: "mini",
               mode: :mock,
               case: "eval_retry",
               prelude_source_overrides: feedback_override(@feedback_a_path)
             )

    assert {:ok, report_b} =
             Eval.run(
               suite: "mini",
               mode: :mock,
               case: "eval_retry",
               prelude_source_overrides: feedback_override(@feedback_b_path)
             )

    component_a = report_a |> feedback_component_from_report()
    component_b = report_b |> feedback_component_from_report()

    assert component_a.source_hash == sha256_file(@feedback_a_path)
    assert component_b.source_hash == sha256_file(@feedback_b_path)
    refute component_a.source_hash == component_b.source_hash
    assert component_a.namespaces == ["agent.feedback"]
    assert component_b.namespaces == ["agent.feedback"]

    inspected = inspect([report_a, report_b])
    refute inspected =~ "(defn eval-feedback"
    refute inspected =~ "(return 3)"
    refute inspected =~ "Previous PTC-Lisp program did not return successfully"
    refute inspected =~ "reuse the bounded defined names"
  end

  test "sanitized mock report redacts untrusted prelude component origin" do
    secret = "sk-or-" <> String.duplicate("SECRET", 40)

    override = %{
      "agent.feedback" => %{
        source: File.read!(@feedback_a_path),
        origin: {:file, "/tmp/#{secret}/feedback_a_default.lisp"}
      }
    }

    assert {:ok, report} =
             Eval.run(
               suite: "mini",
               mode: :mock,
               case: "eval_retry",
               prelude_source_overrides: override
             )

    component = feedback_component_from_report(report)

    assert String.starts_with?(component.origin, "redacted:")
    assert byte_size(component.origin) == byte_size("redacted:") + 64
    refute inspect(report) =~ secret
  end

  test "custom eval cases use role-backed inner preludes and retain sanitized slot provenance" do
    {:ok, store} = seeded_store()
    secret = "S21-EVAL-SECRET"

    {:ok, _} =
      PreludeStore.write(
        store,
        "domain.example",
        """
        (ns domain.example "#{secret}" {:visibility :prompt})
        (defn twice "Double." [x] (+ x x))
        """,
        %{"secret" => secret},
        origin: {:memory, secret}
      )

    eval_case = %{
      id: "inner_prelude",
      task: "Return the computed value.",
      context: %{},
      expect: :integer,
      constraint: {:eq, 42},
      max_turns: 1,
      mock_programs: ["(return (domain.example/twice 21))"]
    }

    assert {:ok, %{cases: [%{status: :pass, trace: trace}]}} =
             Eval.run_cases([eval_case],
               mode: :mock,
               prelude_store: store,
               role_policy: role_policy(),
               inner_preludes: ["domain.example@1"]
             )

    assert Enum.map(Enum.filter(trace, &(&1.event == "prelude")), & &1.slot) == [
             "loop",
             "inner"
           ]

    refute inspect(trace) =~ secret
    refute inspect(trace) =~ "(ns domain.example"
  end

  @tag :tmp_dir
  test "live mode reports provider-specific missing key", %{tmp_dir: dir} do
    previous_env = System.get_env("OPENAI_API_KEY")
    previous_config = Application.get_env(:req_llm, :openai_api_key)

    System.delete_env("OPENAI_API_KEY")
    Application.delete_env(:req_llm, :openai_api_key)

    on_exit(fn ->
      restore_env("OPENAI_API_KEY", previous_env)
      restore_config(:openai_api_key, previous_config)
    end)

    assert {:error, {:missing_api_key, "OPENAI_API_KEY", "openai:gpt-4.1-mini"}} =
             Eval.run(
               suite: "mini",
               mode: :live,
               model: "openai:gpt",
               report: Path.join(dir, "openai.md")
             )
  end

  @tag :tmp_dir
  test "bedrock live preflight requires bearer token or AWS key pair", %{tmp_dir: dir} do
    keys = [
      "AWS_BEARER_TOKEN_BEDROCK",
      "AWS_ACCESS_KEY_ID",
      "AWS_SECRET_ACCESS_KEY",
      "AWS_SESSION_TOKEN"
    ]

    previous = Map.new(keys, &{&1, System.get_env(&1)})

    Enum.each(keys, &System.delete_env/1)
    System.put_env("AWS_ACCESS_KEY_ID", "access-only")

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
    end)

    assert {:error,
            {:missing_api_key,
             "AWS_BEARER_TOKEN_BEDROCK or AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY",
             "amazon_bedrock:anthropic.claude-haiku-4-5-20251001-v1:0"}} =
             Eval.run(
               suite: "mini",
               mode: :live,
               model: "bedrock:haiku",
               report: Path.join(dir, "bedrock.md")
             )
  end

  defp restore_env(_key, nil), do: :ok
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_config(_key, nil), do: :ok
  defp restore_config(key, value), do: Application.put_env(:req_llm, key, value)

  defp scripted_live_llm(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    fn _request ->
      Agent.get_and_update(agent, fn
        [response | rest] -> {{:ok, response}, rest}
        [] -> {{:error, :script_exhausted}, []}
      end)
    end
  end

  defp feedback_override(path) do
    origin =
      path
      |> Path.relative_to(File.cwd!())
      |> then(&{:file, &1})

    %{"agent.feedback" => %{source: File.read!(path), origin: origin}}
  end

  defp components_by_id(%{components: components}) do
    Map.new(components, &{&1.id, &1})
  end

  defp feedback_component_from_report(%{cases: [%{trace: trace}]}) do
    %{prelude: %{components: components}} = Enum.find(trace, &(&1.event == "prelude"))
    Enum.find(components, &(&1.id == "agent.feedback"))
  end

  defp sha256_file(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp seeded_store do
    {:ok, store} = PreludeStore.new()

    for name <- ~w(prompt feedback) do
      {:ok, _} =
        PreludeStore.write(
          store,
          "agent.#{name}",
          File.read!(Path.expand("../../../priv/preludes/agent/#{name}.lisp", __DIR__))
        )
    end

    {:ok, _} =
      PreludeStore.write(
        store,
        "agent.core",
        File.read!(Path.expand("../../../priv/preludes/agent/core.lisp", __DIR__)),
        %{"requires_preludes" => ["agent.prompt@1", "agent.feedback@1"]}
      )

    {:ok, store}
  end

  defp role_policy do
    %{
      "default_role" => "kernel",
      "roles" => %{
        "kernel" => %{
          "prelude_store_access" => "none",
          "preludes" => ["agent.core@1"],
          "default_preludes" => ["agent.core@1"],
          "inner_preludes" => ["domain.example@1"],
          "default_inner_preludes" => ["domain.example@1"]
        }
      }
    }
  end
end
