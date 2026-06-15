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

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Step

  # A `def`-bound name is externalized into `Step.memory` through the bounded
  # vocabulary, so it may surface as either an atom or a binary key. Check both.
  defp memory_get(memory, name) when is_binary(name) do
    Map.get(memory, String.to_atom(name)) || Map.get(memory, name)
  end

  defp memory_has?(memory, name) when is_binary(name) do
    Map.has_key?(memory, String.to_atom(name)) or Map.has_key?(memory, name)
  end

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

    test "a def-exported function value is yielded (not applied) by a zero-arg call" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns cfg "Config." {:visibility :prompt})
        (def handler (fn [x] (* x 2)))
        """)

      # `(cfg/handler)` yields the function VALUE; applying it then doubles.
      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(~S|(let [h (cfg/handler)] (return (h 21)))|, prelude: prelude)

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

  describe "qualified self references are rejected (codex re-review)" do
    test "a qualified self-reference is a clear compile error naming the bare alternative" do
      source = """
      (ns crm "C." {:visibility :prompt})
      (defn- helper [x] (str "sib:" x))
      (defn use-it [x] (crm/helper x))
      """

      assert {:error, err} = Compiler.compile(source)
      assert err.reason == :qualified_self_reference
      assert err.message =~ "helper"
    end

    test "a quoted qualified symbol is NOT treated as a self-reference" do
      source = ~S|(ns crm "C." {:visibility :prompt}) (defn names [] (quote crm/helper))|

      # Quoted data is skipped by the self-ref check, so it is never rejected as a
      # qualified self-reference (it may still fail for other reasons).
      case Compiler.compile(source) do
        {:ok, _prelude} -> :ok
        {:error, err} -> refute err.reason == :qualified_self_reference
      end
    end

    test "a self-reference hidden in a short-fn gets the clear error, not a generic one" do
      # The self-ref check must descend into `#(...)` too — otherwise the helpful
      # "call the sibling by its bare name" error degrades to a generic analyze
      # failure. (It is still rejected either way; this pins the error quality.)
      source = """
      (ns crm "C." {:visibility :prompt})
      (defn- helper [x] (str "sib:" x))
      (defn use-it [xs] (map #(crm/helper %) xs))
      """

      assert {:error, err} = Compiler.compile(source)
      assert err.reason == :qualified_self_reference
      assert err.message =~ "helper"
    end

    test "a self-reference hidden in a set literal gets the clear error" do
      source =
        ~S|(ns crm "C." {:visibility :prompt}) (defn- helper [x] x) (defn use-it [x] #{(crm/helper x)})|

      assert {:error, err} = Compiler.compile(source)
      assert err.reason == :qualified_self_reference
      assert err.message =~ "helper"
    end
  end

  describe "map-destructured locals are not false dependencies (codex re-review)" do
    test "{:keys [...]} binding shadows a same-named helper" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns crm "C." {:visibility :prompt})
        (defn- fetch [id] (tool/call {:server "s" :tool "t" :args {:id id}}))
        (defn pure [{:keys [fetch]}] (str fetch))
        """)

      pure = Enum.find(prelude.exports, &(&1.ref == "crm/pure"))

      # `fetch` here is the destructured param, not the helper.
      assert pure.requires == []
      assert pure.tool_refs == []
    end
  end

  describe "dead/quoted forms are not inferred as dependencies (codex re-review)" do
    test "a tool/call inside (comment ...) is not inferred as a requirement" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns crm "C." {:visibility :prompt})
        (defn noop [] (comment (tool/call {:server "missing" :tool "noop" :args {}})))
        """)

      noop = Enum.find(prelude.exports, &(&1.ref == "crm/noop"))

      # The commented-out call must not become a requires/tool-ref dependency.
      assert noop.requires == []
      assert noop.tool_refs == []
    end
  end

  describe "provider-ref metadata is validated (codex re-review)" do
    test "a non-string :provider-ref fails compilation" do
      source = """
      (ns crm "C." {:visibility :prompt})
      (defn search "Search." {:provider-ref :backend} [q] q)
      """

      assert {:error, err} = Compiler.compile(source)
      assert err.reason == :invalid_metadata
    end

    test "a string :provider-ref is kept and the trace stays JSON-serializable" do
      source = """
      (ns crm "C." {:visibility :prompt})
      (defn search "Search." {:provider-ref "upstream:crm/search"} [q] q)
      """

      {:ok, prelude} = Compiler.compile(source)
      search = Enum.find(prelude.exports, &(&1.ref == "crm/search"))

      assert search.provider_ref == "upstream:crm/search"
      assert {:ok, _json} = Jason.encode(Prelude.trace_summary(prelude))
    end
  end

  describe "value-position exports run isolated (codex re-review)" do
    test "a value-position export does not embed the private env in user-visible data" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns crm "C." {:visibility :prompt})
        (defn- secret-helper [] "PRIVATE")
        (defn pub [] (secret-helper))
        """)

      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run("(def f crm/pub) (return :ok)", prelude: prelude)

      f = Map.get(step.memory, "f") || Map.get(step.memory, :f)
      {:closure, _p, _b, _env, _th, meta} = f

      # The closure carries only the PUBLIC namespace name, never the private env
      # (which would expose private helper BODIES through Step data). pub's body
      # may reference the helper by name, but the helper's implementation
      # ("PRIVATE") must not be embedded in the value.
      assert meta[:prelude_ns] == "crm"
      refute Map.has_key?(meta, :prelude_ns_env)
      refute inspect(f) =~ "PRIVATE"
    end

    test "a value-position export's (def) does not write user memory" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns iso "Iso." {:visibility :prompt})
        (defn writer [] (def leaked 1) leaked)
        """)

      # `iso/writer` used as a value, then invoked, must run in prelude scope —
      # its internal `(def leaked ...)` must NOT pollute the caller's memory.
      program = "(def f iso/writer) (def r (f)) (return r)"

      assert {:ok, %Step{} = step} = PtcRunner.Lisp.run(program, prelude: prelude)

      assert step.return == {:__ptc_return__, 1}
      refute Map.has_key?(step.memory, :leaked)
      refute Map.has_key?(step.memory, "leaked")
    end
  end

  describe "prelude bodies are checked for undefined vars (codex re-review)" do
    test "a typo in a prelude body is rejected at compile time" do
      source = """
      (ns crm "C." {:visibility :prompt})
      (defn bad [] (typo))
      """

      assert {:error, err} = Compiler.compile(source)
      assert err.reason == :compile_error
      assert err.message =~ "typo"
    end

    test "forward references to siblings are allowed" do
      source = """
      (ns crm "C." {:visibility :prompt})
      (defn caller [] (callee))
      (defn callee [] 42)
      """

      assert {:ok, _prelude} = Compiler.compile(source)
    end
  end

  describe "tool_refs are per-export, not namespace-wide (codex re-review)" do
    @mixed """
    (ns mix "Mixed." {:visibility :prompt})
    (defn fetch [id] (tool/call {:server "s" :tool "t" :args {:id id}}))
    (defn pure [x] (str "p:" x))
    """

    test "a pure export does not inherit a tool-backed sibling's tool" do
      {:ok, prelude} = Compiler.compile(@mixed)

      fetch = Enum.find(prelude.exports, &(&1.ref == "mix/fetch"))
      pure = Enum.find(prelude.exports, &(&1.ref == "mix/pure"))

      assert fetch.tool_refs == ["call"]
      assert pure.tool_refs == []

      # A non-empty tools map lacking "call": calling ONLY the pure export must
      # NOT be rejected by the pre-execution tool guard.
      tools = %{"other" => fn _ -> nil end}

      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(~S|(return (mix/pure "a"))|, prelude: prelude, tools: tools)

      assert step.return == {:__ptc_return__, "p:a"}
    end

    test "a tool reached through a private helper is included transitively" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns mix "Mixed." {:visibility :prompt})
        (defn- do-fetch [id] (tool/call {:server "s" :tool "t" :args {:id id}}))
        (defn fetch [id] (do-fetch id))
        (defn pure [x] x)
        """)

      fetch = Enum.find(prelude.exports, &(&1.ref == "mix/fetch"))
      pure = Enum.find(prelude.exports, &(&1.ref == "mix/pure"))

      assert fetch.tool_refs == ["call"]
      assert pure.tool_refs == []
    end
  end

  describe "runtime def targets are not dependency edges (codex re-review)" do
    @def_shadow """
    (ns mix "Mixed." {:visibility :prompt})
    (defn- fetch [id] (tool/call {:server "s" :tool "t" :args {:id id}}))
    (defn shadows [] (def fetch 1) 99)
    (defn caller [] (fetch 1))
    """

    test "a (def name ...) target sharing a helper name forges no requires/tool_refs edge" do
      {:ok, prelude} = Compiler.compile(@def_shadow)

      shadows = Enum.find(prelude.exports, &(&1.ref == "mix/shadows"))
      caller = Enum.find(prelude.exports, &(&1.ref == "mix/caller"))

      # `shadows` only BINDS `fetch` via `(def fetch 1)`; it never calls the
      # private helper, so it must inherit none of its backing.
      assert shadows.requires == []
      assert shadows.tool_refs == []

      # `caller` genuinely calls the helper, so the real edge is preserved.
      assert caller.requires == ["upstream:s/t"]
      assert caller.tool_refs == ["call"]
    end
  end

  describe "exports returning closures keep private-helper access (codex re-review)" do
    test "a closure returned from an export resolves its private helper when applied" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns crm "C." {:visibility :prompt})
        (defn- helper [x] (str "h:" x))
        (defn make [] (fn [x] (helper x)))
        """)

      # The returned closure is applied LATER under the caller's namespace; it
      # must still reach its private helper.
      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(~S|(let [f (crm/make)] (return (f "a")))|, prelude: prelude)

      assert step.return == {:__ptc_return__, "h:a"}
    end
  end

  describe "mcp is a reserved prelude namespace (codex re-review)" do
    test "declaring (ns mcp ...) is rejected at compile time" do
      source = ~S|(ns mcp "M." {:visibility :prompt}) (defn foo [] 1)|

      assert {:error, err} = Compiler.compile(source)
      assert err.reason == :reserved_namespace
    end
  end

  describe "prelude def names cannot shadow builtins (codex re-review)" do
    test "a public def named like a builtin is rejected" do
      source = """
      (ns crm "C." {:visibility :prompt})
      (defn count [xs] 42)
      """

      # `count` interns to an atom (builtin); a prelude def is string-keyed, so a
      # bare sibling reference would silently hit the builtin. Reject fail-closed.
      assert {:error, err} = Compiler.compile(source)
      assert err.reason == :reserved_name
      assert err.message =~ "count"
    end

    test "a private helper named like a builtin is also rejected" do
      source = """
      (ns crm "C." {:visibility :prompt})
      (defn- map [f xs] xs)
      """

      assert {:error, err} = Compiler.compile(source)
      assert err.reason == :reserved_name
    end
  end

  describe "malformed prelude metadata fails recoverably (codex re-review)" do
    @bad_meta ~S|(ns crm "C." {"visibility" :prompt}) (defn get-user [id] id)|

    test "a non-keyword metadata key is a validation error, not a crash" do
      assert {:error, err} = Compiler.compile(@bad_meta)
      assert err.reason == :invalid_metadata
    end

    test "Lisp.run(prelude: bad_source) returns an error Step, not a raised crash" do
      assert {:error, %Step{} = step} = PtcRunner.Lisp.run("(return 1)", prelude: @bad_meta)
      assert step.fail.reason == :invalid_metadata
    end
  end

  describe "bare same-namespace sibling calls (codex branch review)" do
    @sibling_prelude """
    (ns crm "CRM helpers." {:visibility :prompt})
    (defn get-user [id]
      (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
    (defn get-user!
      "Return a CRM user, or abort the program."
      [id]
      (let [res (get-user id)]
        (if (res :ok) (res :value) (fail {:reason (res :reason)}))))
    """

    test "an export calling a sibling by bare name compiles and inherits its requires" do
      {:ok, prelude} = Compiler.compile(@sibling_prelude)

      bang = Enum.find(prelude.exports, &(&1.ref == "crm/get-user!"))

      # The bare sibling call is seen by the requires call-graph (edge to get-user).
      assert bang.requires == ["upstream:crm/get_user"]
    end

    test "the bare sibling call resolves at runtime" do
      {:ok, prelude} = Compiler.compile(@sibling_prelude)
      tools = %{"call" => fn _ -> %{ok: true, value: %{"id" => "u_1"}, reason: nil} end}

      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(~S|(return (crm/get-user! "u_1"))|,
                 prelude: prelude,
                 tools: tools
               )

      assert step.return == {:__ptc_return__, %{"id" => "u_1"}}
    end
  end

  describe "new discovery forms are shadowable by locals (codex branch review)" do
    test "a local named all-ns shadows the discovery form" do
      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(~S|(let [all-ns (fn [] 42)] (return (all-ns)))|)

      assert step.return == {:__ptc_return__, 42}
    end

    test "a local named ns-name shadows the discovery form" do
      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(~S|(let [ns-name (fn [_] "local")] (return (ns-name 'x)))|)

      assert step.return == {:__ptc_return__, "local"}
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

  describe "value-position exports stay isolated on abort (codex re-review)" do
    @abort_prelude """
    (ns crm "C." {:visibility :prompt})
    (defn- leak [] "PRIVATELEAK")
    (defn boom [] (str (leak)) (fail "boom-msg"))
    (defn early [] (str (leak)) (return "early-val"))
    """

    test "a value-position (fail) does not leak the private env into Step.memory" do
      {:ok, prelude} = Compiler.compile(@abort_prelude)

      # `(apply crm/boom [])` runs the export in value position (do_execute_closure).
      # Its `(fail ...)` throws the EXPORT context, whose user_ns is the private
      # prelude env. Without isolation that env becomes Step.memory and the
      # caller's own `keep` binding is dropped.
      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run("(def keep 7) (apply crm/boom [])", prelude: prelude)

      assert step.return == {:__ptc_fail__, "boom-msg"}
      assert memory_get(step.memory, "keep") == 7
      refute memory_has?(step.memory, "leak")
      refute memory_has?(step.memory, "boom")
      refute inspect(step.memory) =~ "PRIVATELEAK"
    end

    test "a value-position (return) keeps caller memory and hides the private env" do
      {:ok, prelude} = Compiler.compile(@abort_prelude)

      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run("(def keep 7) (apply crm/early [])", prelude: prelude)

      assert step.return == {:__ptc_return__, "early-val"}
      assert memory_get(step.memory, "keep") == 7
      refute memory_has?(step.memory, "leak")
      refute inspect(step.memory) =~ "PRIVATELEAK"
    end

    test "a HOF-position (fail) does not leak the private env into Step.memory" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns crm "C." {:visibility :prompt})
        (defn- leak [] "PRIVATELEAK")
        (defn boom [x] (str (leak) x) (fail "hof-boom"))
        """)

      # `(map crm/boom ...)` runs the export through the HOF path
      # (eval_closure_args). The `(fail ...)` must restore the caller's namespace
      # before it escapes the Erlang HOF boundary.
      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run("(def keep 7) (map crm/boom [1])", prelude: prelude)

      assert step.return == {:__ptc_fail__, "hof-boom"}
      assert memory_get(step.memory, "keep") == 7
      refute inspect(step.memory) =~ "PRIVATELEAK"
    end

    test "a closure returned through a HOF still resolves its private helper" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns crm "C." {:visibility :prompt})
        (defn- helper [x] (str "h:" x))
        (defn make-adder [n] (fn [x] (helper x)))
        """)

      # `(map crm/make-adder ...)` returns closures via the HOF path; each must be
      # tagged with its prelude namespace so a later `(f "a")` reaches `helper`.
      program = ~S|(let [fs (map crm/make-adder [1]) f (first fs)] (return (f "a")))|

      assert {:ok, %Step{} = step} = PtcRunner.Lisp.run(program, prelude: prelude)

      assert step.return == {:__ptc_return__, "h:a"}
    end
  end
end
