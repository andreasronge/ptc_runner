defmodule PtcRunner.SubAgent.PreludeDepsIntegrationTest do
  @moduledoc """
  Keystone end-to-end proof for declared prelude-to-prelude dependencies
  (docs/plans/prelude-deps.md §3 — the investigation's former "runtime
  spike"): store `base` (tool-backed) and `audit` (declares `base`), attach
  `["audit"]`, and drive compiled cross-namespace calls at session runtime
  through all three attach entry points (Session, Definition, per-run
  selection).
  """
  use ExUnit.Case, async: true

  alias PtcRunner.PreludeStore
  alias PtcRunner.Session

  @base_source """
  (ns base "Shared helpers.")

  (defn- normalize [x] (str "n:" x))

  (defn helper [x] (str "helper:" (normalize x)))

  (defn fetch [id] (tool/fetch_user {:id id}))
  """

  @audit_source """
  (ns audit "Audit checks.")

  (defn check [id] (base/fetch id))

  (defn tag-all [xs] (map base/helper xs))

  (defn mk [] (fn [x] (base/helper x)))
  """

  defp store_with_deps do
    {:ok, store} = PreludeStore.new()
    {:ok, _} = PreludeStore.write(store, "base", @base_source)

    {:ok, _} =
      PreludeStore.write(store, "audit", @audit_source, %{"requires_preludes" => ["base"]})

    store
  end

  defp counting_fetch_tool(agent) do
    fn args ->
      Agent.update(agent, &[args | &1])
      %{"id" => args["id"], "name" => "Ada"}
    end
  end

  describe "Session attach (entry point 1)" do
    test "attaching the dependent auto-pulls its pinned dep, deps first, with provenance" do
      store = store_with_deps()

      session =
        Session.new(
          prelude_store: store,
          preludes: ["audit"],
          tools: %{"fetch_user" => fn args -> %{"id" => args["id"]} end}
        )

      assert {:ok, [base_ref, audit_ref]} = Session.preludes(session)
      assert %{id: "base", version: 1, required_by: ["audit"]} = base_ref
      assert %{id: "audit", version: 1, required_by: []} = audit_ref
    end

    test "compiled cross-namespace calls run at session runtime with one ledger entry" do
      store = store_with_deps()
      {:ok, agent} = Agent.start_link(fn -> [] end)

      session =
        Session.new(
          prelude_store: store,
          preludes: ["audit"],
          tools: %{"fetch_user" => counting_fetch_tool(agent)}
        )

      assert {{:ok, step}, session} = Session.eval(session, ~s{(audit/check "u1")})
      assert step.return == %{"id" => "u1", "name" => "Ada"}
      assert length(step.tool_calls) == 1
      assert Agent.get(agent, &length(&1)) == 1

      # Value-position dep refs and closures returned across namespaces both
      # resolve through the same dynamic prelude_exports table.
      assert {{:ok, step}, session} = Session.eval(session, ~s{(audit/tag-all ["a" "b"])})
      assert step.return == ["helper:n:a", "helper:n:b"]

      assert {{:ok, step}, _session} = Session.eval(session, ~s{((audit/mk) "v")})
      assert step.return == "helper:n:v"
    end

    test "the dep's private helpers stay unreachable from user code" do
      store = store_with_deps()

      session =
        Session.new(
          prelude_store: store,
          preludes: ["audit"],
          tools: %{"fetch_user" => fn _ -> %{} end}
        )

      assert {{:error, step}, _session} = Session.eval(session, ~s{(base/normalize "x")})
      assert step.fail.message =~ "not a public export"
    end

    test "dep-derived tool requirements gate the attach before any side effect" do
      store = store_with_deps()

      # No fetch_user granted: the bundle's requires (base/fetch's own, and
      # audit/check's unioned copy) fail attach validation at eval.
      session = Session.new(prelude_store: store, preludes: ["audit"])

      assert {{:error, step}, _session} = Session.eval(session, ~s{(audit/check "u1")})
      assert step.fail.reason == :prelude_attach_failed
    end

    test "version conflicts between selection and pins fail closed with requirers named" do
      store = store_with_deps()

      # base moves to v2; audit still pins v1. Selecting both bare is a
      # conflict; aligning the selection to the pin resolves it.
      {:ok, _} =
        PreludeStore.write(store, "base", """
        (ns base "Shared helpers, v2.")

        (defn helper [x] (str "helper2:" x))
        """)

      assert_raise ArgumentError, ~r/conflicting versions of prelude `base`.*audit/, fn ->
        Session.new(prelude_store: store, preludes: ["audit", "base"])
      end

      session =
        Session.new(
          prelude_store: store,
          preludes: ["audit", "base@1"],
          tools: %{"fetch_user" => fn _ -> %{} end}
        )

      assert {:ok, [%{id: "base", version: 1, required_by: ["audit"]}, %{id: "audit"}]} =
               Session.preludes(session)
    end
  end

  describe "SubAgent Definition attach (entry point 2)" do
    test "preludes: on new/1 freezes the dep closure into runtime_prelude" do
      store = store_with_deps()

      agent =
        PtcRunner.SubAgent.new(
          prompt: "Check {{id}}",
          signature: "(id :string) -> {user :any}",
          prelude_store: store,
          preludes: ["audit"],
          tools: %{"fetch_user" => fn args -> %{"id" => args["id"]} end},
          max_turns: 1
        )

      assert agent.runtime_prelude.namespaces == ["audit", "base"]

      assert [%{id: "base"}, %{id: "audit"}] = agent.runtime_prelude.metadata.components

      llm = fn _ -> {:ok, ~S|(return {:user (audit/check data/id)})|} end
      assert {:ok, step} = PtcRunner.SubAgent.run(agent, llm: llm, context: %{"id" => "u9"})
      assert step.return["user"] == %{"id" => "u9"}
    end
  end

  describe "SubAgent per-run selection (entry point 3)" do
    test "run/2 resolves the dep closure per run" do
      store = store_with_deps()

      agent =
        PtcRunner.SubAgent.new(
          prompt: "Check {{id}}",
          signature: "(id :string) -> {user :any}",
          tools: %{"fetch_user" => fn args -> %{"id" => args["id"]} end},
          max_turns: 1
        )

      llm = fn _ -> {:ok, ~S|(return {:user (audit/check data/id)})|} end

      assert {:ok, step} =
               PtcRunner.SubAgent.run(agent,
                 prelude_store: store,
                 preludes: ["audit"],
                 llm: llm,
                 context: %{"id" => "u3"}
               )

      assert step.return["user"] == %{"id" => "u3"}
      assert agent.runtime_prelude == nil
    end
  end
end
