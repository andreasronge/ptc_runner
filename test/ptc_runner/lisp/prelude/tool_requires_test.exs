defmodule PtcRunner.Lisp.Prelude.ToolRequiresTest do
  @moduledoc """
  Plan P3: the generalized `requires` resolver — `tool:<name>` capability
  requirements, union (not override) merge semantics, transitive `tool_refs`
  promotion, and
  attach-time fail-closed validation against the granted `tools:` map.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude.{Attach, AttachContext, Compiler}
  alias PtcRunner.Lisp.Result, as: Step

  defp compile!(source) do
    {:ok, prelude} = Compiler.compile(source)
    prelude
  end

  defp ctx(opts), do: AttachContext.new(opts)
  # ============================================================
  # Compile-time inference: tool_refs -> tool: requires (union)
  # ============================================================
  describe "tool: requires inference" do
    test "a typed tool call promotes to a tool: requirement" do
      [export] =
        compile!("""
        (ns cap "Cap." {:visibility :prompt})
        (defn fetch "doc" [id] (tool/get_thing {:id id}))
        """).exports

      assert export.requires == ["tool:get_thing"]
      assert export.tool_refs == ["get_thing"]
      assert export.effect == :read
    end

    # Kitchen-sink: a distinct typed tool inside EVERY container/wrapper. This is
    # the positive fail-open contract — a "doesn't crash" test would pass on a
    # walker that silently drops a container, so we assert each sentinel tool is
    # actually EXTRACTED. The day the grammar grows a container without updating
    # the walkers, a new sentinel goes missing and this fails loudly.
    test "tool inference descends into every container/wrapper (let/vector/map/set/short-fn/for)" do
      [export] =
        compile!(~S"""
        (ns kit "Kitchen sink." {:visibility :prompt})
        (defn everything
          "Embeds a distinct typed tool in each container."
          [xs]
          (let [a (tool/sentinel_let {})]
            [a
             (tool/sentinel_vec {})
             {(tool/sentinel_mapkey {}) (tool/sentinel_mapval {})}
             #{(tool/sentinel_set {})}
             (map #(tool/sentinel_shortfn %) xs)
             (for [x xs] (tool/sentinel_for {}))]))
        """).exports

      for sentinel <- ~w(
            sentinel_let sentinel_vec sentinel_mapkey sentinel_mapval
            sentinel_set sentinel_shortfn sentinel_for
          ) do
        assert sentinel in export.tool_refs,
               "#{sentinel} was dropped — a container is not being walked (fail-open)"

        assert "tool:#{sentinel}" in export.requires
      end
    end

    test "a typed tool call inside #() is inferred (no fail-open through short-fn)" do
      [export] =
        compile!("""
        (ns cap "Cap." {:visibility :prompt})
        (defn fetch-all "doc" [ids] (map #(tool/get_thing {:id %}) ids))
        """).exports

      assert "tool:get_thing" in export.requires
      assert "get_thing" in export.tool_refs
    end

    test "a tool/call inside #() carries the generic tool requirement" do
      [export] =
        compile!("""
        (ns cap "Cap." {:visibility :prompt})
        (defn fetch-all "doc" [ids]
          (map #(tool/call {:server "svc" :tool "op" :args {:id %}}) ids))
        """).exports

      assert "tool:call" in export.requires
    end

    test "a typed tool call inside a set literal #{} is inferred" do
      [export] =
        compile!("""
        (ns cap "Cap." {:visibility :prompt})
        (defn f "doc" [x] \#{(tool/get_thing {:x x})})
        """).exports

      assert "tool:get_thing" in export.requires
    end

    test "a helper-backed tool is carried transitively by the public export" do
      # `report` reaches `tool/secret_tool` ONLY through the private helper
      # `dig`; the requirement must still surface on the public export.
      prelude =
        compile!("""
        (ns cap "Cap." {:visibility :prompt})
        (defn- dig "private" [x] (tool/secret_tool {:x x}))
        (defn report "doc" [x] (dig x))
        """)

      [export] = prelude.exports
      assert export.ref == "cap/report"
      assert "tool:secret_tool" in export.requires
    end

    test "requires is the UNION of inferred and explicit (inferred survives explicit)" do
      [export] =
        compile!("""
        (ns cap "Cap." {:visibility :prompt})
        (defn f "doc" {:requires ["tool:extra"]} [x] (tool/foo {:x x}))
        """).exports

      # Old replacement semantics would have dropped the inferred tool:foo.
      assert "tool:foo" in export.requires
      assert "tool:extra" in export.requires
      assert export.requires == Enum.sort(export.requires)
    end

    test "tool/call is treated like every other named tool" do
      [export] =
        compile!("""
        (ns cap "Cap." {:visibility :prompt})
        (defn get-thing "doc" [id]
          (tool/call {:server "svc" :tool "op" :args {:id id}}))
        """).exports

      assert export.requires == ["tool:call"]
    end

    test "dynamic tool/call arguments do not create ambient authority" do
      [implicit] =
        compile!("""
        (ns cap "Cap." {:visibility :prompt})
        (defn proxy "doc" [s t] (tool/call {:server s :tool t :args {}}))
        """).exports

      assert implicit.requires == ["tool:call"]

      [explicit] =
        compile!("""
        (ns cap "Cap." {:visibility :prompt})
        (defn proxy "doc" {:requires ["tool:audit"]} [s t]
          (tool/call {:server s :tool t :args {}}))
        """).exports

      assert explicit.requires == ["tool:audit", "tool:call"]
    end
  end

  # ============================================================
  # Attach-time fail-closed validation against the granted tools
  # ============================================================

  describe "tool: attach validation" do
    @cap """
    (ns cap "Cap." {:visibility :prompt})
    (defn fetch "doc" [id] (tool/get_thing {:id id}))
    """

    test "fails closed when the required tool is not granted" do
      assert {:error, err} = Attach.validate_requires(compile!(@cap), ctx(tools: %{}))
      assert err.reason == :prelude_attach_failed
      assert err.message =~ "get_thing"
      assert err.ref == "cap/fetch"
    end

    test "passes when the host grants a tool of that name" do
      tools = %{"get_thing" => fn _args -> :ok end}
      assert :ok = Attach.validate_requires(compile!(@cap), ctx(tools: tools))
    end

    test "fails compilation for an unrecognized requirement shape" do
      assert {:error, err} =
               Compiler.compile("""
               (ns cap "Cap." {:visibility :prompt})
               (defn f "doc" {:requires ["weird:thing"]} [] (tool/foo {}))
               """)

      assert err.reason == :invalid_requires
      assert err.message =~ "tool:<name>"
    end

    test "a dynamic-dispatch export attaches only once the explicit requirement is satisfied" do
      explicit =
        compile!("""
        (ns cap "Cap." {:visibility :prompt})
        (defn proxy "doc" {:requires ["tool:do_it"]} [s] (tool/call {:server s :tool "x" :args {}}))
        """)

      # Without the grant -> fail closed.
      assert {:error, _} = Attach.validate_requires(explicit, ctx(tools: %{}))
      # Both the inferred call tool and the explicit tool must be granted.
      assert :ok =
               Attach.validate_requires(
                 explicit,
                 ctx(tools: %{"do_it" => fn _ -> nil end, "call" => fn _ -> nil end})
               )
    end
  end

  # ============================================================
  # End-to-end through Lisp.run/2
  # ============================================================

  describe "Lisp.run threads the granted tools into attach" do
    @cap """
    (ns cap "Cap." {:visibility :prompt})
    (defn fetch "doc" [id] (tool/get_thing {:id id}))
    """

    test "a granted tool: export is callable" do
      tools = %{"get_thing" => fn args -> %{"id" => args["id"], "ok" => true} end}

      assert {:ok, %Step{} = step} =
               Lisp.run(~S|(cap/fetch "x")|, prelude: compile!(@cap), tools: tools)

      assert step.return == %{"id" => "x", "ok" => true}
    end

    test "an ungranted tool: export fails attach before running user code" do
      assert {:error, %Step{} = step} =
               Lisp.run(~S|(cap/fetch "x")|, prelude: compile!(@cap), tools: %{})

      assert step.fail.reason == :prelude_attach_failed
      assert step.fail.message =~ "get_thing"
    end

    test "accepts the tuple-list tools: shape Lisp.run also accepts" do
      # `tools:` may be a `[{name, tool}, ...]` list, not only a map; grant
      # validation must canonicalize before checking (no BadMapError).
      tools = [{"get_thing", fn args -> %{"id" => args["id"]} end}]

      assert {:ok, %Step{return: %{"id" => "x"}}} =
               Lisp.run(~S|(cap/fetch "x")|, prelude: compile!(@cap), tools: tools)
    end
  end

  describe "private tool authority" do
    @cap """
    (ns cap "Cap." {:visibility :prompt})
    (defn fetch "doc" [id] (tool/private_fetch {:id id}))
    """

    test "direct user calls to private tools fail closed" do
      tools = %{
        "private_fetch" => {fn _args -> "secret" end, visibility: :private}
      }

      assert {:error, %Step{} = step} =
               Lisp.run(~S|(tool/private_fetch {:id "x"})|, tools: tools)

      assert step.fail.reason == :private_tool_unauthorized
      assert step.fail.message =~ "private_fetch"
    end

    test "a current prelude export may call its declared private tools" do
      tools = %{
        "private_fetch" =>
          {fn args -> %{"id" => args["id"], "ok" => true} end,
           signature: "(id :string) -> :map", visibility: :private}
      }

      assert {:ok, %Step{} = step} =
               Lisp.run(~S|(cap/fetch "x")|, prelude: compile!(@cap), tools: tools)

      assert step.return == %{"id" => "x", "ok" => true}
      assert [%{private: true, origin: %{ref: "cap/fetch"}}] = step.tool_calls
    end

    test "a value-position HOF use of an export may call its declared private tools" do
      tools = %{
        "private_fetch" =>
          {fn args -> %{"id" => args["id"], "ok" => true} end,
           signature: "(id :string) -> :map", visibility: :private}
      }

      assert {:ok, %Step{} = step} =
               Lisp.run(~S|(map cap/fetch ["x"])|, prelude: compile!(@cap), tools: tools)

      assert step.return == [%{"id" => "x", "ok" => true}]
      assert [%{private: true, origin: %{ref: "cap/fetch"}}] = step.tool_calls
    end

    test "a value-position pcalls use of an export may call its declared private tools" do
      prelude =
        compile!("""
        (ns cap "Cap." {:visibility :prompt})
        (defn fetch-zero "doc" [] (tool/private_fetch {:id "x"}))
        """)

      tools = %{
        "private_fetch" =>
          {fn args -> %{"id" => args["id"], "ok" => true} end,
           signature: "(id :string) -> :map", visibility: :private}
      }

      assert {:ok, %Step{} = step} =
               Lisp.run(~S|(pcalls cap/fetch-zero)|, prelude: prelude, tools: tools)

      assert step.return == [%{"id" => "x", "ok" => true}]
    end

    test "pcalls prelude exports resolve private helper functions" do
      prelude =
        compile!("""
        (ns cap "Cap." {:visibility :prompt})
        (defn- fetch-helper [] (tool/private_fetch {:id "x"}))
        (defn fetch-zero "doc" [] (fetch-helper))
        """)

      tools = %{
        "private_fetch" =>
          {fn args -> %{"id" => args["id"], "ok" => true} end,
           signature: "(id :string) -> :map", visibility: :private}
      }

      assert {:ok, %Step{} = step} =
               Lisp.run(~S|(pcalls cap/fetch-zero)|, prelude: prelude, tools: tools)

      assert step.return == [%{"id" => "x", "ok" => true}]
    end

    test "value-position export authority is restored after the call returns" do
      tools = %{
        "private_fetch" => {fn _args -> "secret" end, visibility: :private}
      }

      assert {:error, %Step{} = step} =
               Lisp.run(
                 ~S|(let [f cap/fetch] (f "x") (tool/private_fetch {:id "y"}))|,
                 prelude: compile!(@cap),
                 tools: tools
               )

      assert step.fail.reason == :private_tool_unauthorized
      assert step.fail.message =~ "private_fetch"
    end

    test "public tools called from prelude exports keep origin without private marker" do
      prelude =
        compile!("""
        (ns cap "Cap." {:visibility :prompt})
        (defn ping "doc" [] (tool/public_ping {}))
        """)

      tools = %{"public_ping" => fn _args -> "pong" end}

      assert {:ok, %Step{} = step} = Lisp.run(~S|(cap/ping)|, prelude: prelude, tools: tools)

      assert step.return == "pong"
      assert [%{origin: %{ref: "cap/ping"}} = call] = step.tool_calls
      refute Map.get(call, :private)
    end

    test "private tool args are signature validated before execution" do
      tools = %{
        "private_fetch" =>
          {fn _args -> flunk("private tool should not execute with invalid args") end,
           signature: "(id :int) -> :map", visibility: :private}
      }

      assert {:error, %Step{} = step} =
               Lisp.run(~S|(cap/fetch "not-int")|, prelude: compile!(@cap), tools: tools)

      assert step.fail.reason == :private_tool_args_error
      assert step.fail.message =~ "private_fetch"
      assert step.fail.message =~ "expected int"
    end

    test "user closures passed to a prelude export cannot reference private tools" do
      prelude =
        compile!("""
        (ns cap "Cap." {:visibility :prompt})
        (defn run "doc" [f]
          (do
            (tool/private_fetch {:id "export"})
            (f)))
        """)

      parent = self()

      tools = %{
        "private_fetch" =>
          {fn args ->
             send(parent, {:private_fetch, args["id"]})
             %{"id" => args["id"], "ok" => true}
           end, signature: "(id :string) -> :map", visibility: :private}
      }

      assert {:error, %Step{} = step} =
               Lisp.run(
                 ~S|(cap/run (fn [] (tool/private_fetch {:id "user"})))|,
                 prelude: prelude,
                 tools: tools
               )

      assert step.fail.reason == :private_tool_unauthorized
      assert step.fail.message =~ "private_fetch"
      refute_received {:private_fetch, "export"}
      refute_received {:private_fetch, "user"}
    end

    test "escaped prelude closures applied inside another export do not inherit its authority" do
      prelude =
        compile!("""
        (ns cap "Cap." {:visibility :prompt})
        (defn make "doc" []
          (fn [] (tool/private_fetch {:id "escaped"})))
        (defn run "doc" [f]
          (do
            (tool/private_fetch {:id "export"})
            (f)))
        """)

      parent = self()

      tools = %{
        "private_fetch" =>
          {fn args ->
             send(parent, {:private_fetch, args["id"]})
             %{"id" => args["id"], "ok" => true}
           end, signature: "(id :string) -> :map", visibility: :private}
      }

      assert {:error, %Step{} = step} =
               Lisp.run(~S|(cap/run (cap/make))|, prelude: prelude, tools: tools)

      assert step.fail.reason == :private_tool_unauthorized
      assert step.fail.message =~ "private_fetch"
      assert_received {:private_fetch, "export"}
      refute_received {:private_fetch, "escaped"}
    end

    test "anonymous closures authored inside a prelude export keep that export's authority" do
      prelude =
        compile!("""
        (ns cap "Cap." {:visibility :prompt})
        (defn run "doc" []
          (map (fn [id] (tool/private_fetch {:id id})) ["inner"]))
        """)

      tools = %{
        "private_fetch" =>
          {fn args -> %{"id" => args["id"], "ok" => true} end,
           signature: "(id :string) -> :map", visibility: :private}
      }

      assert {:ok, %Step{} = step} =
               Lisp.run(~S|(cap/run)|, prelude: prelude, tools: tools)

      assert step.return == [%{"id" => "inner", "ok" => true}]
      assert [%{private: true, origin: %{ref: "cap/run"}}] = step.tool_calls
    end

    test "user closures applied inside a prelude export do not see private helpers" do
      prelude =
        compile!("""
        (ns cap "Cap." {:visibility :prompt})
        (defn- count [xs] 99)
        (defn run "doc" [f] (f))
        """)

      assert {:ok, %Step{} = step} =
               Lisp.run(~S|(cap/run (fn [] (count [1 2])))|, prelude: prelude)

      assert step.return == 2
    end

    test "escaped prelude closures do not retain private tool authority" do
      tools = %{
        "private_fetch" => {fn _args -> "secret" end, visibility: :private}
      }

      assert {:error, %Step{} = step} =
               Lisp.run(~S|(def f cap/fetch) (f "x")|, prelude: compile!(@cap), tools: tools)

      assert step.fail.reason == :private_tool_unauthorized
      assert step.fail.message =~ "private_fetch"
    end

    test "escaped prelude closures nested in collections do not retain private tool authority" do
      tools = %{
        "private_fetch" => {fn _args -> "secret" end, visibility: :private}
      }

      assert {:error, %Step{} = step} =
               Lisp.run(
                 ~S|(def boxed [cap/fetch]) ((first boxed) "x")|,
                 prelude: compile!(@cap),
                 tools: tools
               )

      assert step.fail.reason == :private_tool_unauthorized
      assert step.fail.message =~ "private_fetch"
    end

    test "escaped wrapper closures do not retain captured private tool authority" do
      tools = %{
        "private_fetch" => {fn _args -> "secret" end, visibility: :private}
      }

      assert {:error, %Step{} = step} =
               Lisp.run(
                 ~S|(def wrapper (let [f cap/fetch] (fn [id] (f id)))) (wrapper "x")|,
                 prelude: compile!(@cap),
                 tools: tools
               )

      assert step.fail.reason == :private_tool_unauthorized
      assert step.fail.message =~ "private_fetch"
    end

    test "private tool calls do not seed a cache entry usable by direct callers" do
      tools = %{
        "private_fetch" => {fn _args -> "secret" end, visibility: :private, cache: true}
      }

      assert {:error, %Step{} = step} =
               Lisp.run(
                 ~S|(cap/fetch "x") (tool/private_fetch {:id "x"})|,
                 prelude: compile!(@cap),
                 tools: tools
               )

      assert step.fail.reason == :private_tool_unauthorized
    end

    test "private tools ignore the cache setting within a prelude workflow" do
      provider_calls = :atomics.new(1, [])

      prelude =
        compile!("""
        (ns cap "Cap." {:visibility :prompt})
        (defn fetch-twice "doc" [id]
          [(tool/private_fetch {:id id})
           (tool/private_fetch {:id id})])
        """)

      tools = %{
        "private_fetch" =>
          {fn _args -> :atomics.add_get(provider_calls, 1, 1) end,
           visibility: :private, cache: true}
      }

      assert {:ok, %Step{} = step} =
               Lisp.run(~S|(cap/fetch-twice "x")|, prelude: prelude, tools: tools)

      assert step.return == [1, 2]
      assert Enum.all?(step.tool_calls, &(Map.get(&1, :cached, false) == false))
      assert :atomics.get(provider_calls, 1) == 2
    end
  end
end
