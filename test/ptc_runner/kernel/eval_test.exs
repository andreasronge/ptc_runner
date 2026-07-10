defmodule PtcRunner.Kernel.EvalTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Eval
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.PreludeStore

  @variant_dir Path.expand("../../../priv/kernel_feedback_variants", __DIR__)
  @feedback_a_path Path.join(@variant_dir, "feedback_a_default.lisp")
  @feedback_b_path Path.join(@variant_dir, "feedback_b_memory_guidance.lisp")

  test "mini suite mock mode reports deterministic per-case counts" do
    assert {:ok, report} = Eval.run(suite: "mini", mode: :mock)

    assert report.suite == "mini"
    assert report.mode == :mock
    assert report.model == nil
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
    refute traces =~ "result_preview"
    refute traces =~ "changed_keys"

    decoded = Jason.decode!(json)

    assert decoded["cases"] |> hd() |> Map.fetch!("expected_result") == %{
             "type" => "integer",
             "value" => 250
           }

    assert decoded["cases"] |> hd() |> Map.fetch!("actual_result") == %{
             "type" => "integer",
             "value" => 250
           }

    assert decoded["cases"] |> hd() |> Map.fetch!("inner_prelude_call_counts") == %{}
    assert is_list(decoded["cases"] |> hd() |> Map.fetch!("preludes"))
    assert is_list(decoded["cases"] |> hd() |> Map.fetch!("inner_preludes"))
  end

  test "smoke and live runs require the report contract and reject non-kernel variants" do
    assert {:error, {:report_required, "smoke"}} =
             Eval.run(suite: "smoke", mode: :mock, variant: "kernel")

    assert {:error, {:unsupported_variant, "incumbent"}} =
             Eval.run(suite: "mini", mode: :mock, variant: "incumbent")

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
  end

  @tag :tmp_dir
  test "failed runs leave neither raw nor published persistent traces", %{tmp_dir: dir} do
    assert_raise BadMapError, fn ->
      Eval.run_cases(
        [
          %{
            id: "crash",
            task: "Return one.",
            context: %{},
            expected: 1,
            max_turns: 1,
            mock_programs: ["(return 1)"]
          }
        ],
        mode: :mock,
        trace_dir: dir,
        prelude_source_overrides: :invalid
      )
    end

    assert Path.wildcard(Path.join(dir, "*")) == []
  end

  test "default markdown report is sanitized" do
    assert {:ok, report} = Eval.run(suite: "mini", mode: :mock)

    markdown = Eval.render_markdown(report)

    assert markdown =~ "context_filter_count"
    assert markdown =~ "domain_tool"
    assert markdown =~ "memory_persistence"
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
      expected: 42,
      max_turns: 3,
      mock_programs: [~S|(return 0)|]
    }

    assert {:ok, report} = Eval.run_cases([wrong_case], mode: :mock)
    assert [case_result] = report.cases
    assert case_result.status == :fail
    assert case_result.value == 0
    assert case_result.failure_reason =~ "expected_mismatch"
    refute Eval.passed?(report)
    assert Eval.failure_count(report) == 1
  end

  test "mock report trace redacts raw host-held memory values" do
    secret = String.duplicate("SECRET-TRACE-", 40)

    memory_case = %{
      id: "redacted_memory",
      task: "Store a large value, then return ok.",
      context: %{},
      expected: "ok",
      max_turns: 3,
      mock_programs: [~s|(do (def payload "#{secret}") (return :ok))|]
    }

    assert {:ok, report} = Eval.run_cases([memory_case], mode: :mock)
    assert [%{status: :pass, trace: trace}] = report.cases
    inspected = inspect(trace)

    refute inspected =~ secret
    refute inspected =~ "payload"
    assert Enum.any?(trace, &(&1.event == "memory"))
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
      expected: 42,
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
