defmodule PtcRunner.Lisp.Prelude.CodexRegressionTest do
  @moduledoc """
  Regression tests for two [P1] correctness bugs found by `codex review` on the
  Capability Prelude V1 spike:

    1. Namespace collapse — the compiler captured every prelude definition into
       one flat `user_ns` keyed by bare symbol, so two namespaces declaring the
       same public/private name silently conflated (e.g. `crm/who` and `hr/who`
       both resolved to the `hr` implementation).

    2. Preflight side-effect guard bypass — a prelude export wrapping
       `(tool/call ...)` hid the wrapped tool from `check_undefined_tools`, so a
       program could execute an earlier tool (a real side effect) before failing
       on the prelude export's missing tool, defeating the pre-execution guard.

  Both write a failing test FIRST per the repo's TDD rule.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Step

  describe "namespace-scoped private env (codex P1 #1)" do
    @two_ns_public """
    (ns crm "CRM." {:visibility :prompt})
    (defn who [] "crm-who")

    (ns hr "HR." {:visibility :prompt})
    (defn who [] "hr-who")
    """

    test "same public symbol in two namespaces resolves to distinct exports" do
      {:ok, prelude} = Compiler.compile(@two_ns_public)

      program = ~S|(return {:a (crm/who) :b (hr/who)})|

      assert {:ok, %Step{} = step} = PtcRunner.Lisp.run(program, prelude: prelude)

      assert step.return == {:__ptc_return__, %{"a" => "crm-who", "b" => "hr-who"}}
    end

    @two_ns_private """
    (ns crm "CRM." {:visibility :prompt})
    (defn- tag [] "crm")
    (defn label [] (tag))

    (ns hr "HR." {:visibility :prompt})
    (defn- tag [] "hr")
    (defn label [] (tag))
    """

    test "same private helper name in two namespaces does not cross-contaminate" do
      {:ok, prelude} = Compiler.compile(@two_ns_private)

      program = ~S|(return {:a (crm/label) :b (hr/label)})|

      assert {:ok, %Step{} = step} = PtcRunner.Lisp.run(program, prelude: prelude)

      # Each export must resolve its OWN namespace's private `tag`, not the last
      # one captured.
      assert step.return == {:__ptc_return__, %{"a" => "crm", "b" => "hr"}}
    end

    test "private env is keyed by namespace then symbol" do
      {:ok, prelude} = Compiler.compile(@two_ns_public)

      assert match?({:closure, _, _, _, _, _}, prelude.private_env["crm"]["who"])
      assert match?({:closure, _, _, _, _, _}, prelude.private_env["hr"]["who"])
      # The two `who` closures are genuinely different definitions.
      refute prelude.private_env["crm"]["who"] == prelude.private_env["hr"]["who"]
    end
  end

  describe "preflight includes prelude-wrapped tool calls (codex P1 #2)" do
    @wrapping_prelude """
    (ns crm "CRM." {:visibility :prompt})
    (defn get-user
      "Return a CRM user by id."
      [id]
      (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
    """

    test "a missing wrapped tool fails BEFORE an earlier tool can run" do
      {:ok, prelude} = Compiler.compile(@wrapping_prelude)
      {:ok, agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      # Non-empty toolset that has `foo` but NOT the wrapped upstream `call`.
      tools = %{
        "foo" => fn _args ->
          Agent.update(agent, fn calls -> [:foo | calls] end)
          %{ok: true}
        end
      }

      # `foo` would run first, then `crm/get-user` would fail on the missing
      # `call`. The pre-execution guard must reject the whole program first.
      program = ~S|(tool/foo {}) (crm/get-user "u_1")|

      assert {:error, %Step{} = step} =
               PtcRunner.Lisp.run(program, prelude: prelude, tools: tools)

      assert step.fail.reason == :unknown_tool
      assert step.fail.message =~ "call"
      # The side-effect guard held: `foo` never executed.
      assert Agent.get(agent, & &1) == []
    end

    test "a present wrapped tool still passes preflight and runs" do
      {:ok, prelude} = Compiler.compile(@wrapping_prelude)
      {:ok, agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      tools = %{
        "call" => fn _args ->
          Agent.update(agent, fn calls -> [:call | calls] end)
          %{ok: true, value: %{"id" => "u_1"}, reason: nil}
        end
      }

      program = ~S|(def res (crm/get-user "u_1")) (res :ok)|

      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(program, prelude: prelude, tools: tools)

      assert step.return == true
      assert Agent.get(agent, & &1) == [:call]
    end
  end

  describe "constant exports are usable values (codex P2 #2)" do
    @const_prelude """
    (ns cfg "Config." {:visibility :prompt})
    (def answer 42)
    """

    test "a constant export resolves in value position" do
      {:ok, prelude} = Compiler.compile(@const_prelude)

      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(~S|(return (inc cfg/answer))|, prelude: prelude)

      assert step.return == {:__ptc_return__, 43}
    end

    test "a zero-arg constant call yields the value, not not_callable" do
      {:ok, prelude} = Compiler.compile(@const_prelude)

      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(~S|(return (cfg/answer))|, prelude: prelude)

      assert step.return == {:__ptc_return__, 42}
    end
  end

  describe "prelude exports see their own data keys (codex round 3 #A)" do
    @data_prelude """
    (ns ctx "Context helpers." {:visibility :prompt})
    (defn user-count [] (count data/users))
    """

    test "an export reads data/* absent from the user AST under default filtering" do
      {:ok, prelude} = Compiler.compile(@data_prelude)

      # filter_context defaults to true; `users` never appears in the user
      # program `(ctx/user-count)`, so plain dataset filtering would drop it and
      # the export would see empty data.
      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run("(return (ctx/user-count))",
                 prelude: prelude,
                 context: %{"users" => [1, 2, 3]}
               )

      assert step.return == {:__ptc_return__, 3}
    end
  end

  describe "duplicate definitions are rejected (codex round 3 #B)" do
    test "a public/private name clash in a namespace fails compilation" do
      source = """
      (ns crm "CRM." {:visibility :prompt})
      (defn foo [x] x)
      (defn- foo [] 1)
      """

      assert {:error, err} = Compiler.compile(source)
      assert err.reason == :duplicate_ref
    end
  end

  describe "invalid :requires metadata fails compilation (codex round 3 #C)" do
    test "non-string :requires entries are rejected, not silently dropped" do
      source = """
      (ns crm "CRM." {:visibility :prompt})
      (defn get-user
        "Get user."
        {:requires [:bad]}
        [id]
        (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
      """

      assert {:error, err} = Compiler.compile(source)
      assert err.reason == :invalid_requires
    end
  end

  describe "multiple literal tool/calls keep all requires (codex round 4 #1)" do
    test "an export with two literal tool/calls keeps both upstream ids" do
      source = """
      (ns crm "CRM." {:visibility :prompt})
      (defn sync-user [id]
        (tool/call {:server "crm" :tool "get_user" :args {:id id}})
        (tool/call {:server "crm" :tool "put_user" :args {:id id}}))
      """

      {:ok, prelude} = Compiler.compile(source)
      [export] = prelude.exports

      # Both upstream operations must remain in requires so attach-time
      # validation checks each one (fail-closed), not be dropped as "unknown".
      assert export.requires == ["upstream:crm/get_user", "upstream:crm/put_user"]
      # No single backing provider when several literals are present.
      assert export.provider_ref == nil
    end
  end

  describe "helper-backed upstream requirements are inferred (codex round 7 #1)" do
    test "a public export inherits a private helper's upstream requirement" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns crm "CRM." {:visibility :prompt})
        (defn- do-fetch [id] (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
        (defn get-user [id] (do-fetch id))
        """)

      # Only get-user is public, and its OWN body has no literal tool/call — the
      # upstream is reached through the private helper. requires must still carry
      # it so attach-time validation fails closed when it isn't configured.
      assert [export] = prelude.exports
      assert export.ref == "crm/get-user"
      assert export.requires == ["upstream:crm/get_user"]
      assert export.effect == :read
    end
  end

  describe "a namespace cannot be redeclared (codex round 9)" do
    test "reopening a namespace with a different default is rejected, not mis-compiled" do
      source = """
      (ns a "A." {:visibility :prompt})
      (defn first-one [] 1)
      (ns a "A again." {:visibility :discoverable})
      (defn second-one [] 2)
      """

      # Without rejection, `first-one` would silently inherit the SECOND
      # directive's `:discoverable` default and drop out of the prompt inventory.
      assert {:error, err} = Compiler.compile(source)
      assert err.reason == :invalid_namespace
      assert err.message =~ "more than once"
    end
  end

  describe "requires inference counts real calls only (codex round 8)" do
    test "a param shadowing a helper name does not inherit the helper's requires" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns crm "CRM." {:visibility :prompt})
        (defn- fetch [id] (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
        (defn pure-export [fetch] (str "got " fetch))
        (defn real-caller [id] (fetch id))
        """)

      pure = Enum.find(prelude.exports, &(&1.ref == "crm/pure-export"))
      caller = Enum.find(prelude.exports, &(&1.ref == "crm/real-caller"))

      # `fetch` in pure-export is its OWN param, not the helper — no requirement,
      # so attach-time validation won't reject the prelude over an upstream it
      # never uses.
      assert pure.requires == []
      assert pure.effect == :unknown

      # real-caller genuinely calls the helper, so it carries the requirement.
      assert caller.requires == ["upstream:crm/get_user"]
    end

    test "a let binding shadowing a helper name is not a call edge" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns crm "CRM." {:visibility :prompt})
        (defn- fetch [id] (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
        (defn pure-export [] (let [fetch 1] (str fetch)))
        """)

      pure = Enum.find(prelude.exports, &(&1.ref == "crm/pure-export"))
      assert pure.requires == []
    end
  end

  describe "prelude constant evaluation is sandbox-bounded (codex round 7 #2)" do
    test "an oversized constant fails recoverably under the sandbox, not by hanging" do
      source = """
      (ns big "Big." {:visibility :prompt})
      (def huge (range 100000000))
      """

      # The constant's value is evaluated at compile time; without the bounded
      # sandbox this would exhaust memory in the caller process. It must instead
      # return a recoverable compile error.
      assert {:error, err} = Compiler.compile(source)
      assert err.reason == :compile_error
      assert err.message =~ "sandbox"
    end
  end

  describe "dir on a prelude namespace honors pagination (codex round 6 #1)" do
    @multi_export """
    (ns crm "CRM." {:visibility :prompt})
    (defn a [] 1)
    (defn b [] 2)
    (defn c [] 3)
    """

    test ":limit and :offset bound the dir output like the local/MCP paths" do
      {:ok, prelude} = Compiler.compile(@multi_export)

      assert {:ok, %Step{} = limited} =
               PtcRunner.Lisp.run(~S|(return (count (dir 'crm {:limit 2})))|, prelude: prelude)

      assert limited.return == {:__ptc_return__, 2}

      assert {:ok, %Step{} = offset} =
               PtcRunner.Lisp.run(~S|(return (count (dir 'crm {:offset 2})))|, prelude: prelude)

      assert offset.return == {:__ptc_return__, 1}
    end
  end

  describe "variadic exports enforce minimum arity (codex round 4 #2)" do
    @variadic_prelude """
    (ns crm "CRM." {:visibility :prompt})
    (defn search [id & opts] id)
    """

    test "too few args to a variadic export fails at analysis, before any side effect" do
      {:ok, prelude} = Compiler.compile(@variadic_prelude)

      assert {:error, %Step{} = step} =
               PtcRunner.Lisp.run("(crm/search)", prelude: prelude)

      assert step.fail.message =~ "at least"
    end

    test "enough args to a variadic export is accepted" do
      {:ok, prelude} = Compiler.compile(@variadic_prelude)

      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(~S|(return (crm/search "u_1" "extra"))|, prelude: prelude)

      assert step.return == {:__ptc_return__, "u_1"}
    end
  end
end
