defmodule PtcRunner.Kernel.CapAgentMainTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.TrustedTool

  describe "cap is composition-only" do
    # Assert on the compiled inventory rather than the source text: what
    # matters is that the model never sees these helpers, not how the
    # namespace happens to be spelled.
    test "no cap export reaches the prompt inventory" do
      {:ok, components} = Library.components(["cap"])
      {:ok, bundle} = Kernel.compile_bundle(components)

      prompt_refs = Enum.map(Prelude.prompt_exports(bundle.prelude), & &1.ref)

      assert prompt_refs == [],
             "cap composes envelopes for other libraries; it must not spend prompt budget"
    end

    test "agent.main does reach the prompt inventory" do
      {:ok, components} = Library.components(agent_main_closure())
      {:ok, bundle} = Kernel.compile_bundle(components)

      prompt_refs = Enum.map(Prelude.prompt_exports(bundle.prelude), & &1.ref)
      assert "agent.main/run" in prompt_refs
    end
  end

  describe "cap/unwrap!" do
    test "returns the value of a successful capability response" do
      assert run(~S|(cap/unwrap! {:status :ok :value 42})|) == "42"
    end

    test "fails the program on an error envelope instead of returning it" do
      # The point of unwrap! is that a forgotten check cannot turn a provider
      # error into ordinary data, so this must not succeed with the envelope.
      rendered = run(~S|(cap/unwrap! {:status :denied :reason "no"})|)

      assert rendered =~ ":__ptc_fail__"
      assert rendered =~ ":status :denied"
    end

    test "a missing status is an error, not an implicit success" do
      assert run(~S|(cap/unwrap! {:value 1})|) =~ ":__ptc_fail__"
    end
  end

  describe "cap/with-cursor" do
    test "adds an opaque cursor to a string-keyed argument map" do
      assert run(~S|(cap/with-cursor {"limit" 100} "abc")|) ==
               ~S|{"cursor" "abc" "limit" 100}|
    end

    test "a nil cursor selects the first page and removes a stale cursor" do
      assert run(~S|(cap/with-cursor {"path" "lib" "limit" 100} nil)|) ==
               ~S|{"limit" 100 "path" "lib"}|

      assert run(~S|(cap/with-cursor {"cursor" "stale" "limit" 100} nil)|) ==
               ~S|{"limit" 100}|

      assert run(~S|(cap/with-cursor {:cursor "stale" :limit 100} nil)|) ==
               ~S|{:limit 100}|
    end

    test "does not interpret or transform the cursor" do
      assert run(~S|(cap/with-cursor {} "opaque:page/2?x=1")|) ==
               ~S|{"cursor" "opaque:page/2?x=1"}|
    end
  end

  describe "cap/collect-pages" do
    test "follows opaque cursors and reports complete traversal" do
      source = ~S"""
      (cap/collect-pages
        (fn [cursor]
          (if cursor
            {"items" [3] "next_cursor" nil}
            {"items" [1 2] "next_cursor" "page-2"}))
        2)
      """

      assert run(source) ==
               ~S|{"complete?" true "items" [1 2 3] "pages" 2}|
    end

    test "preserves snapshot provenance and rejects a changed snapshot" do
      source = ~S"""
      (cap/collect-pages
        (fn [cursor]
          (if cursor
            {"items" [2] "next_cursor" nil "snapshot_hash" "sha256:same"}
            {"items" [1] "next_cursor" "page-2" "snapshot_hash" "sha256:same"}))
        2)
      """

      assert run(source) ==
               ~S|{"complete?" true "items" [1 2] "pages" 2 "snapshot_hash" "sha256:same"}|

      changed = ~S"""
      (cap/collect-pages
        (fn [cursor]
          (if cursor
            {"items" [2] "next_cursor" nil "snapshot_hash" "sha256:changed"}
            {"items" [1] "next_cursor" "page-2" "snapshot_hash" "sha256:first"}))
        2)
      """

      assert run(changed) =~ ":snapshot-changed"
    end

    test "marks a bounded prefix incomplete and rejects an invalid bound" do
      source = ~S"""
      (cap/collect-pages
        (fn [cursor]
          {"items" [(if cursor 2 1)] "next_cursor" "more"})
        1)
      """

      assert run(source) ==
               ~S|{"complete?" false "items" [1] "pages" 1}|

      assert run(~S|(cap/collect-pages (fn [_] {"items" []}) 0)|) =~
               ":invalid-max-pages"
    end
  end

  describe "analysis prelude composition" do
    test "primitive and analysis components declare their direct shared dependencies" do
      assert {:ok, log_core} = Library.component("log.core")
      assert {:ok, inspection_core} = Library.component("inspection.core")
      assert {:ok, log_analysis} = Library.component("log.analysis")
      assert {:ok, inspection_analysis} = Library.component("inspection.analysis")

      assert log_core.dependencies == ["cap"]
      assert inspection_core.dependencies == ["cap"]
      assert log_analysis.dependencies == ["cap", "log.core"]
      assert inspection_analysis.dependencies == ["cap", "inspection.core"]

      assert {:ok, components} =
               Library.resolve_components([
                 {:library, "log.analysis"},
                 {:library, "inspection.analysis"}
               ])

      assert Enum.map(components, & &1.id) == [
               "cap",
               "inspection.analysis",
               "inspection.core",
               "log.analysis",
               "log.core"
             ]

      assert {:ok, bundle} = Kernel.compile_bundle(components)

      for ref <- [
            "log.analysis/all-runs",
            "log.analysis/all-turns",
            "inspection.analysis/all-runs",
            "inspection.analysis/all-model-exchanges",
            "inspection.analysis/all-capability-calls",
            "inspection.analysis/all-generated-sources",
            "inspection.analysis/all-effective-preludes",
            "inspection.analysis/all-provider-exchanges"
          ] do
        assert {:ok, _export} = Prelude.fetch_export(bundle.prelude, ref)
      end
    end
  end

  describe "agent.main is domain-blind" do
    test "declares exactly agent.core as its dependency" do
      {:ok, component} = Library.component("agent.main")
      assert component.dependencies == ["agent.core"]
    end

    test "carries no application or repository vocabulary" do
      {:ok, component} = Library.component("agent.main")
      source = String.downcase(component.source)

      for term <- ~w(repository repo scout commit branch file code review) do
        refute String.contains?(source, term),
               "agent.main must stay domain-blind; found #{inspect(term)}"
      end
    end

    test "forwards only task and agent from input" do
      {:ok, component} = Library.component("agent.main")

      assert component.source =~ ~s|(get input "task")|
      assert component.source =~ ~s|(get input "agent")|
    end
  end

  # Returns the canonical rendering of the program's value. PTC-Lisp keywords
  # are a wrapped type that inspects like an atom but does not match one, so
  # comparing rendered values keeps these assertions honest and readable.
  describe "agent.main as a manifest entry" do
    @tag :tmp_dir
    test "a manifest selects it and reaches agent.core without a local wrapper",
         %{tmp_dir: dir} do
      manifest = %{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"library" => "agent.main"}],
          "entry" => "agent.main/run"
        },
        # No local component: the point is that an application needs no
        # hand-written wrapper to reach the agent loop.
        "input" => %{
          "value" => %{"task" => "summarize", "agent" => %{"max_turns" => 1}}
        }
      }

      path = Path.join(dir, "ptc.json")
      File.write!(path, Jason.encode!(manifest))

      assert {:ok, loaded} = Manifest.load(path)

      ids = Enum.map(loaded.workflow_components, & &1.id)
      assert "agent.main" in ids

      assert "agent.core" in ids,
             "agent.main must pull agent.core through its declared dependency"

      assert loaded.entry == "agent.main/run"

      # The closure compiles as a bundle, so the entry is genuinely runnable.
      assert {:ok, _bundle} = Kernel.compile_bundle(loaded.workflow_components)
    end

    # Fetching a component does not pull its dependencies; compilation is what
    # refuses an incomplete set. A partial closure must fail loudly rather than
    # produce a bundle whose entry cannot reach the agent loop.
    test "compiling it without its dependency is refused rather than silently partial" do
      {:ok, components} = Library.components(["agent.main"])

      assert {:error, %{id: "agent.main", reason: :missing_component_dependency}} =
               Kernel.compile_bundle(components)
    end
  end

  defp agent_main_closure do
    ~w(agent.main agent.core agent.feedback agent.native agent.prompt agent.retry
       kernel llm result workflow.event)
  end

  defp run(source) do
    {:ok, components} = Library.components(["cap"])
    {:ok, bundle} = Kernel.compile_bundle(components)

    {:ok, result} =
      Lisp.run_native(source,
        prelude: bundle.prelude,
        tools: discovery_tools(),
        filter_context: false,
        caller: :kernel
      )

    {rendered, _truncated} = Lisp.format_value(result.return)
    rendered
  end

  # `cap` declares the discovery tools it wraps, so the bundle only attaches
  # when the host grants them. These stubs satisfy that contract; the helpers
  # under test are pure and never call them.
  defp discovery_tools do
    Map.new(
      ~w(cap-list cap-describe),
      &{&1, %TrustedTool{function: fn _arguments -> %{status: :error} end}}
    )
  end
end
