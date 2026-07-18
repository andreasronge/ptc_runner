defmodule PtcRunner.Lisp.Prelude.RuntimeContractTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Eval
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Lisp.Result, as: Step

  defp compile!(source) do
    assert {:ok, prelude} = Compiler.compile(source)
    prelude
  end

  describe "public function contracts" do
    test "Eval.eval returns a contract error tuple instead of leaking the exception" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn double {:signature "(value :int) -> :int"} [value] (* value 2))
        """)

      assert {:error, {:prelude_contract_error, _message, %{phase: :input, ref: "api/double"}}} =
               Eval.eval(
                 {:prelude_call, "api/double", [{:string, "bad"}]},
                 %{},
                 %{},
                 %{},
                 fn _, _ -> nil end,
                 [],
                 prelude: prelude
               )
    end

    test "rejects a wrong direct input before entering the body" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn stringify
          {:signature "(value :int) -> :string"}
          [value]
          (println "entered")
          (str value))
        """)

      assert {:error, %Step{} = step} = Lisp.run(~S|(api/stringify "42")|, prelude: prelude)
      assert step.fail.reason == :prelude_contract_error
      assert step.fail.details.phase == :input
      assert step.fail.details.ref == "api/stringify"
      assert step.fail.details.path == ["value"]
      assert step.prints == []
      assert step.prelude_call_counts == %{}
    end

    test "accepts correct direct inputs and outputs" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn stringify
          {:signature "(value :int) -> :string"}
          [value]
          (str value))
        """)

      assert {:ok, %Step{return: "42"}} = Lisp.run(~S|(api/stringify 42)|, prelude: prelude)
    end

    test "rejects alias-equivalent input keys before the wrapper reads either value" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn pick
          {:signature "(input {user-id :int}) -> :any"}
          [input]
          (println "entered")
          (get input :user-id))
        """)

      assert {:error, %Step{} = step} =
               Lisp.run(~S|(api/pick {:user_id 1 :user-id "bad"})|, prelude: prelude)

      assert step.fail.reason == :prelude_contract_error
      assert step.fail.details.phase == :input
      assert step.fail.details.path == ["input", "user-id"]
      assert step.fail.message =~ "ambiguous field aliases"
      assert step.prints == []
    end

    test "rejects alias-equivalent keys in a wrapper output" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn ambiguous
          {:signature "() -> {user-id :int}"}
          []
          {:user_id 1 :user-id "bad"})
        """)

      assert {:error, %Step{} = step} = Lisp.run(~S|(api/ambiguous)|, prelude: prelude)
      assert step.fail.reason == :prelude_contract_error
      assert step.fail.details.phase == :output
      assert step.fail.details.path == ["user-id"]
      assert step.fail.message =~ "ambiguous field aliases"
    end

    test "rejects a wrong ordinary output and retains capability activity" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn fetch
          {:signature "() -> :string"}
          []
          (tool/read {}))
        """)

      tools = %{"read" => fn _ -> 42 end}

      assert {:error, %Step{} = step} = Lisp.run(~S|(api/fetch)|, prelude: prelude, tools: tools)
      assert step.fail.reason == :prelude_contract_error
      assert step.fail.details.phase == :output
      assert step.fail.details.ref == "api/fetch"
      assert step.fail.details.capability_activity?
      assert length(step.tool_calls) == 1
    end

    test "returns contract-error ledgers in chronological order" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn bad
          {:signature "() -> :int"}
          []
          (do
            (println "first")
            (tool/first {})
            (println "second")
            (tool/second {})
            "wrong"))
        """)

      tools = %{"first" => fn _ -> %{} end, "second" => fn _ -> %{} end}

      assert {:error, %Step{} = step} = Lisp.run(~S|(api/bad)|, prelude: prelude, tools: tools)
      assert step.fail.reason == :prelude_contract_error
      assert step.prints == ["first", "second"]
      assert Enum.map(step.tool_calls, & &1.name) == ["first", "second"]
    end

    test "does not disclose captured closure values in contract errors" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn leak
          {:signature "() -> :int"}
          []
          (let [private-value "PRIVATE_SENTINEL"]
            (fn [] private-value)))
        """)

      assert {:error, %Step{} = step} = Lisp.run(~S|(api/leak)|, prelude: prelude)
      assert step.fail.reason == :prelude_contract_error
      assert step.fail.message =~ "expected int, got function"
      refute step.fail.message =~ "PRIVATE_SENTINEL"
      refute inspect(step.fail.details) =~ "PRIVATE_SENTINEL"
    end

    test "enforces the same input contract in a higher-order call" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn double
          {:signature "(value :int) -> :int"}
          [value]
          (* value 2))
        """)

      assert {:error, %Step{} = step} = Lisp.run(~S|(map api/double [1 "bad"])|, prelude: prelude)
      assert step.fail.reason == :prelude_contract_error
      assert step.fail.details.phase == :input
      assert step.fail.details.path == ["value"]
    end

    test "retains earlier higher-order capability activity on a later input failure" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn maybe
          {:signature "(value :int) -> :int"}
          [value]
          (if (= value 1) (do (tool/touch {}) value) value))
        """)

      assert {:error, %Step{} = step} =
               Lisp.run(~S|(map api/maybe [1 "bad"])|,
                 prelude: prelude,
                 tools: %{"touch" => fn _ -> %{} end}
               )

      assert step.fail.reason == :prelude_contract_error
      assert step.fail.details.capability_activity?
      assert length(step.tool_calls) == 1
      assert step.prelude_call_counts == %{"api/maybe" => 1}
    end

    test "retains the caller ledger when a higher-order output contract fails" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn bad {:signature "(value :int) -> :int"} [value] "wrong")
        """)

      assert {:error, %Step{} = step} =
               Lisp.run(~S|(tool/touch {}) (map api/bad [1])|,
                 prelude: prelude,
                 tools: %{"touch" => fn _ -> %{} end}
               )

      assert step.fail.reason == :prelude_contract_error
      assert step.fail.details.capability_activity?
      assert [%{name: "touch"}] = step.tool_calls
      assert step.prelude_call_counts == %{"api/bad" => 1}
    end

    test "retains capability activity across parallel workers on contract failure" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn maybe
          {:signature "(value :int) -> :int"}
          [value]
          (if (= value 1) (do (tool/touch {}) value) value))
        """)

      assert {:error, %Step{} = step} =
               Lisp.run(~S|(pmap api/maybe [1 "bad"])|,
                 prelude: prelude,
                 tools: %{"touch" => fn _ -> %{} end},
                 pmap_max_concurrency: 1
               )

      assert step.fail.reason == :prelude_contract_error
      assert step.fail.details.capability_activity?
      assert Enum.map(step.tool_calls, & &1.name) == ["touch"]
      assert step.prelude_call_counts == %{"api/maybe" => 1}
    end

    test "retains completed pcalls worker effects on a later contract failure" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn touch {:signature "() -> :map"} [] (tool/touch {}))
        (defn bad {:signature "() -> :int"} [] "wrong")
        """)

      assert {:error, %Step{} = step} =
               Lisp.run(~S|(pcalls api/touch api/bad)|,
                 prelude: prelude,
                 tools: %{"touch" => fn _ -> %{} end},
                 pmap_max_concurrency: 1
               )

      assert step.fail.reason == :prelude_contract_error
      assert step.fail.details.capability_activity?
      assert Enum.map(step.tool_calls, & &1.name) == ["touch"]
      assert step.prelude_call_counts == %{"api/bad" => 1, "api/touch" => 1}
    end

    test "counts an invalid export-local return once through map" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn bad {:signature "(value :int) -> :int"} [value] (return "wrong"))
        """)

      assert {:error, %Step{} = step} =
               Lisp.run(~S|(map api/bad [1])|, prelude: prelude)

      assert step.fail.reason == :prelude_contract_error
      assert step.prelude_call_counts == %{"api/bad" => 1}
    end

    test "counts an invalid export-local return once through pcalls" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn bad {:signature "() -> :int"} [] (return "wrong"))
        """)

      assert {:error, %Step{} = step} =
               Lisp.run(~S|(pcalls api/bad)|, prelude: prelude, pmap_max_concurrency: 1)

      assert step.fail.reason == :prelude_contract_error
      assert step.prelude_call_counts == %{"api/bad" => 1}
    end

    test "retains same-ref and same-print baselines on a pmap contract failure" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn maybe
          {:signature "(value :int) -> :int"}
          [value]
          (do (println "same") (if (= value 0) 0 "wrong")))
        """)

      assert {:error, %Step{} = step} =
               Lisp.run(~S|(api/maybe 0) (pmap api/maybe [1])|,
                 prelude: prelude,
                 pmap_max_concurrency: 1
               )

      assert step.fail.reason == :prelude_contract_error
      assert step.prints == ["same", "same"]
      assert step.prelude_call_counts == %{"api/maybe" => 2}
    end

    test "retains same-ref and same-print baselines on a pcalls contract failure" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn maybe
          {:signature "() -> :int"}
          []
          (do (println "same") (tool/next {})))
        """)

      next = fn _arguments ->
        Agent.get_and_update(counter, fn
          0 -> {0, 1}
          count -> {"wrong", count + 1}
        end)
      end

      assert {:error, %Step{} = step} =
               Lisp.run(~S|(api/maybe) (pcalls api/maybe)|,
                 prelude: prelude,
                 tools: %{"next" => next},
                 pmap_max_concurrency: 1
               )

      assert step.fail.reason == :prelude_contract_error
      assert step.prints == ["same", "same"]
      assert Enum.map(step.tool_calls, & &1.name) == ["next", "next"]
      assert step.prelude_call_counts == %{"api/maybe" => 2}
    end

    test "preserves arity errors before direct contract validation" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn add {:signature "(left :int, right :int) -> :int"} [left right] (+ left right))
        """)

      assert {:error, %Step{} = too_few} = Lisp.run(~S|(apply api/add [1])|, prelude: prelude)
      assert too_few.fail.reason == :arity_mismatch

      assert {:error, %Step{} = too_many} =
               Lisp.run(~S|(apply api/add [1 2 3])|, prelude: prelude)

      assert too_many.fail.reason == :arity_mismatch
    end

    test "preserves arity errors before higher-order contract validation" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn add {:signature "(left :int, right :int) -> :int"} [left right] (+ left right))
        (defn unary {:signature "(value :int) -> :int"} [value] value)
        """)

      assert {:error, %Step{} = too_few} = Lisp.run(~S|(map api/add [1])|, prelude: prelude)
      assert too_few.fail.reason == :runtime_error
      assert too_few.fail.message =~ "arity 2 called with 1 argument"

      assert {:error, %Step{} = too_many} =
               Lisp.run(~S|(reduce api/unary 0 [1])|, prelude: prelude)

      assert too_many.fail.reason == :runtime_error
      assert too_many.fail.message =~ "arity 1 called with 2 arguments"
    end

    test "preserves the contract classification through pmap" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn double
          {:signature "(value :int) -> :int"}
          [value]
          (* value 2))
        """)

      assert {:error, %Step{} = step} =
               Lisp.run(~S|(pmap api/double [1 "bad"])|, prelude: prelude)

      assert step.fail.reason == :prelude_contract_error
      assert step.fail.details.phase == :input
      assert step.fail.details.path == ["value"]
    end

    test "enforces output contracts through pcalls" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn bad {:signature "() -> :int"} [] "wrong")
        """)

      assert {:error, %Step{} = step} = Lisp.run(~S|(pcalls api/bad)|, prelude: prelude)
      assert step.fail.reason == :prelude_contract_error
      assert step.fail.details.phase == :output
      assert step.fail.details.ref == "api/bad"
    end

    test "pcalls contract failures retain the configured print limit" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn bad
          {:signature "() -> :int"}
          []
          (do (println "abcdef") "wrong"))
        """)

      assert {:error, %Step{} = step} =
               Lisp.run(~S|(pcalls api/bad)|,
                 prelude: prelude,
                 max_print_length: 3,
                 pmap_max_concurrency: 1
               )

      assert step.fail.reason == :prelude_contract_error
      assert step.prints == ["abc... (3/6 chars)"]
    end

    test "rejects strings, nil, and booleans for keyword inputs and outputs" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn identity-keyword
          {:signature "(value :keyword) -> :keyword"}
          [value]
          value)
        (defn bad-keyword {:signature "() -> :keyword"} [] nil)
        (defn bad-string-keyword {:signature "() -> :keyword"} [] "plain")
        """)

      for value <- [~S|"plain"|, "nil", "true", "false"] do
        assert {:error, %Step{} = step} =
                 Lisp.run("(api/identity-keyword #{value})", prelude: prelude)

        assert step.fail.reason == :prelude_contract_error
        assert step.fail.details.phase == :input
      end

      assert {:error, %Step{} = step} = Lisp.run(~S|(api/bad-keyword)|, prelude: prelude)
      assert step.fail.reason == :prelude_contract_error
      assert step.fail.details.phase == :output

      assert {:error, %Step{} = step} =
               Lisp.run(~S|(api/bad-string-keyword)|, prelude: prelude)

      assert step.fail.reason == :prelude_contract_error
      assert step.fail.details.phase == :output
    end

    test "retains parallel capability activity in output contract details" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn fetch
          {:signature "(value :int) -> :string"}
          [value]
          (tool/read {:value value}))
        """)

      tools = %{"read" => fn _ -> 42 end}

      assert {:error, %Step{} = step} =
               Lisp.run(~S|(pmap api/fetch [1])|, prelude: prelude, tools: tools)

      assert step.fail.reason == :prelude_contract_error
      assert step.fail.details.phase == :output
      assert step.fail.details.capability_activity?
      assert [%{name: "read"}] = step.tool_calls
      assert step.prelude_call_counts == %{"api/fetch" => 1}
    end

    test "retains pcalls capability effects on an output contract failure" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn fetch
          {:signature "() -> :string"}
          []
          (tool/read {}))
        """)

      assert {:error, %Step{} = step} =
               Lisp.run(~S|(pcalls api/fetch)|,
                 prelude: prelude,
                 tools: %{"read" => fn _ -> 42 end}
               )

      assert step.fail.reason == :prelude_contract_error
      assert step.fail.details.phase == :output
      assert step.fail.details.capability_activity?
      assert [%{name: "read"}] = step.tool_calls
      assert step.prelude_call_counts == %{"api/fetch" => 1}
    end

    test "validates an export-local return before propagating it" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn finish
          {:signature "() -> :int"}
          []
          (return "wrong"))
        """)

      assert {:error, %Step{} = step} = Lisp.run(~S|(api/finish)|, prelude: prelude)
      assert step.fail.reason == :prelude_contract_error
      assert step.fail.details.phase == :output
    end

    test "does not validate fail payloads as successful outputs" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn stop
          {:signature "() -> :int"}
          []
          (fail "expected failure"))
        """)

      assert {:ok, %Step{return: {:__ptc_fail__, "expected failure"}}} =
               Lisp.run(~S|(api/stop)|, prelude: prelude)
    end

    test "unsigned exports retain their existing dynamic behavior" do
      prelude =
        compile!("""
        (ns api "API" {:visibility :prompt})
        (defn identity-value [value] value)
        """)

      assert {:ok, %Step{return: "anything"}} =
               Lisp.run(~S|(api/identity-value "anything")|, prelude: prelude)
    end
  end
end
