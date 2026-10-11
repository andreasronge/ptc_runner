defmodule PtcRunner.Lisp.HostErrorPolicyTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Prelude.Compiler

  test "host errors fail closed without an injected policy" do
    assert Helpers.sanitize_private_error(
             {:runtime_limit_exceeded, "PRIVATE",
              %{limit: :subordinate_evaluations, limit_value: 1}}
           ) == {:private_prelude_error, "private prelude evaluation failed"}
  end

  test "host runtime errors are rebuilt instead of retaining private fields" do
    reason =
      {:runtime_limit_exceeded, "PRIVATE",
       %{limit: :subordinate_evaluations, limit_value: 1, secret: "PRIVATE"}}

    result = Helpers.sanitize_private_error(reason, nil, PtcRunner.Kernel.HostErrorPolicy)
    assert elem(result, 0) == :runtime_limit_exceeded
    refute inspect(result) =~ "PRIVATE"
    assert Helpers.sanitize_private_error(result, nil, PtcRunner.Kernel.HostErrorPolicy) == result
  end

  test "policy exceptions and invalid outputs fail closed" do
    for policy <- [
          PtcRunner.TestSupport.HostErrorPolicy.Raising,
          PtcRunner.TestSupport.HostErrorPolicy.Throwing,
          PtcRunner.TestSupport.HostErrorPolicy.Invalid,
          PtcRunner.TestSupport.HostErrorPolicy.Oversized,
          PtcRunner.TestSupport.HostErrorPolicy.Deep
        ] do
      assert Helpers.sanitize_private_error({:host_error, "PRIVATE", %{}}, nil, policy) ==
               {:private_prelude_error, "private prelude evaluation failed"}

      assert PtcRunner.Lisp.HostErrorPolicy.project_failure_metadata(policy, %{}, :extract) == %{}

      assert {:error, step} =
               PtcRunner.Lisp.run("(pcalls #(fail {:kind :application-error}))",
                 host_error_policy: policy
               )

      assert step.fail.details == %{}
      refute inspect(step.fail) =~ "POLICY_SECRET"
    end
  end

  test "workers and nested private boundaries use the invocation policy" do
    {:ok, prelude} =
      Compiler.compile("""
      (ns api "API" {:visibility :prompt})
      (defn inner [x] (tool/read {:x x}))
      (defn outer [x] (inner x))
      (defn make [] (fn [] (inner 1)))
      """)

    tools = %{
      "read" => fn _ ->
        %PtcRunner.Lisp.TrustedError{
          reason: :runtime_limit_exceeded,
          message: "PRIVATE",
          details: %{limit: :subordinate_evaluations, limit_value: 1, secret: "PRIVATE"}
        }
      end
    }

    assert {:error, default} = PtcRunner.Lisp.run("(api/outer 1)", prelude: prelude, tools: tools)
    assert default.fail.reason == :private_prelude_error
    refute inspect(default.fail) =~ "PRIVATE"

    for source <- [
          "(api/outer 1)",
          "(pmap api/outer [1])",
          "(pcalls #(api/outer 1))",
          "(map api/outer [1])"
        ] do
      assert {:error, step} =
               PtcRunner.Lisp.run(source,
                 prelude: prelude,
                 tools: tools,
                 host_error_policy: PtcRunner.TestSupport.HostErrorPolicy.Alternate
               )

      assert step.fail.reason == :runtime_limit_exceeded, source <> inspect(step.fail)
      assert step.fail.message =~ "alternate policy", source
      refute inspect(step.fail) =~ "PRIVATE", source
    end

    assert {:ok, first} =
             PtcRunner.Lisp.run_native("(def saved (api/make))",
               prelude: prelude,
               tools: tools,
               host_error_policy: PtcRunner.TestSupport.HostErrorPolicy.Alternate
             )

    assert {:error, second} =
             PtcRunner.Lisp.run_native("(saved)",
               memory: first.memory,
               prelude: prelude,
               tools: tools,
               host_error_policy: PtcRunner.Kernel.HostErrorPolicy
             )

    assert second.fail.reason == :runtime_limit_exceeded
    assert second.fail.message =~ "subordinate_evaluations"
    refute inspect(first.memory) =~ "HostErrorPolicy"
  end

  test "parallel fail remains usable without a host catalog" do
    for source <- [
          "(pmap (fn [_] (fail {:kind :application-error :reason \"PRIVATE\"})) [1])",
          "(pcalls #(fail {:kind :application-error :reason \"PRIVATE\"}))"
        ] do
      assert {:error, step} = PtcRunner.Lisp.run(source)
      assert step.fail.details == %{failure_kind: "application-error"}
      refute inspect(step.fail) =~ "PRIVATE"
    end
  end

  test "the no-policy projection rejects nested and oversized kinds and drops host fields" do
    for kind <- [%{nested: %{value: "PRIVATE"}}, ["PRIVATE"], String.duplicate("x", 129)] do
      assert PtcRunner.Lisp.HostErrorPolicy.project_failure_metadata(nil, %{kind: kind}, :extract) ==
               %{}
    end

    assert PtcRunner.Lisp.HostErrorPolicy.project_failure_metadata(
             nil,
             %{llm_provider_failure: :rate_limited, llm_provider_retryable?: true},
             :retain
           ) == %{}
  end
end
