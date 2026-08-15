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

    test "agent exports advertise their public configuration" do
      {:ok, components} = Library.components(agent_main_closure())
      {:ok, bundle} = Kernel.compile_bundle(components)

      signatures = Map.new(bundle.prelude.exports, &{&1.ref, &1.signature})

      for ref <- ~w(agent.core/run-value agent.core/run-outcome agent.core/run-result-value) do
        assert signatures[ref] ==
                 "(task :string, cfg {model :string?, mission :string?, max_turns :int?, max_program_chars :int?, max_observation_chars :int?, max_transcript_chars :int?, consolidate_at_turns_remaining :int?}) -> :any"
      end

      assert signatures["agent.core/run"] ==
               "(task :string, cfg {model :string?, mission :string?, max_turns :int?, max_program_chars :int?, max_observation_chars :int?, max_transcript_chars :int?, consolidate_at_turns_remaining :int?, result_envelope :bool?}) -> :any"

      assert signatures["agent.main/run"] ==
               "(input {task :string, agent {model :string?, mission :string?, max_turns :int?, max_program_chars :int?, max_observation_chars :int?, max_transcript_chars :int?, consolidate_at_turns_remaining :int?}}) -> :any"
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

  describe "cap/fold-pages" do
    test "reduces pages into bounded caller state and reports completion" do
      source = ~S"""
      (cap/fold-pages
        (fn [cursor]
          (if cursor
            {"items" [3] "next_cursor" nil "snapshot_hash" "sha256:same"}
            {"items" [1 2] "next_cursor" "page-2" "snapshot_hash" "sha256:same"}))
        +
        0
        {"max_pages" 2})
      """

      assert run(source) ==
               ~S|{"complete?" true "next_cursor" nil "pages" 2 "snapshot_hash" "sha256:same" "value" 6}|
    end

    test "preserves a resumable cursor and validates the expected snapshot" do
      source = ~S"""
      (cap/fold-pages
        (fn [_] {"items" [1 2] "next_cursor" "page-2" "snapshot_hash" "sha256:same"})
        +
        0
        {"max_pages" 1})
      """

      assert run(source) ==
               ~S|{"complete?" false "next_cursor" "page-2" "pages" 1 "snapshot_hash" "sha256:same" "value" 3}|

      resumed = ~S"""
      (cap/fold-pages
        (fn [cursor]
          {"items" [(if (= cursor "page-2") 3 99)]
           "next_cursor" nil
           "snapshot_hash" "sha256:same"})
        +
        0
        {"max_pages" 1 "cursor" "page-2" "snapshot_hash" "sha256:same"})
      """

      assert run(resumed) ==
               ~S|{"complete?" true "next_cursor" nil "pages" 1 "snapshot_hash" "sha256:same" "value" 3}|

      changed =
        String.replace(
          resumed,
          ~S|"cursor" "page-2" "snapshot_hash" "sha256:same"|,
          ~S|"cursor" "page-2" "snapshot_hash" "sha256:other"|
        )

      assert run(changed) =~ ":snapshot-changed"
    end

    test "rejects missing provenance, invalid bounds, and cursor cycles" do
      assert run(~S|(cap/fold-pages (fn [_] {"items" [] "next_cursor" nil}) + 0 {"max_pages" 1})|) =~
               ":missing-snapshot-hash"

      assert run(~S|(cap/fold-pages (fn [_] {}) + 0 {"max_pages" 0})|) =~
               ":invalid-max-pages"

      cycle = ~S"""
      (cap/fold-pages
        (fn [cursor]
          {"items" []
           "next_cursor" (if (= cursor "a") "b" "a")
           "snapshot_hash" "sha256:same"})
        +
        0
        {"max_pages" 4 "cursor" "a" "snapshot_hash" "sha256:same"})
      """

      assert run(cycle) =~ ":cursor-cycle"
    end

    test "traverses data larger than the old eager collector with constant accumulator state" do
      payload = String.duplicate("x", 1_100)

      source = """
      (cap/fold-pages
        (fn [cursor]
          (let [page (if cursor (parse-long cursor) 0)]
            {"items" (mapv (fn [item] (str page ":" item ":" "#{payload}"))
                            (range 50))
             "next_cursor" (if (< page 99) (str (inc page)) nil)
             "snapshot_hash" "sha256:large"}))
        (fn [count _] (inc count))
        0
        {"max_pages" 100})
      """

      # The 5,000 unique items carry more than 5 MiB in aggregate, but only
      # one 50-item page and the integer accumulator are live at a time. This
      # is a heap-safety test, not a deadline test, so tolerate loaded CI hosts.
      assert run(source, timeout: 30_000) ==
               ~S|{"complete?" true "next_cursor" nil "pages" 100 "snapshot_hash" "sha256:large" "value" 5000}|
    end
  end

  describe "analysis prelude composition" do
    test "one analysis component declares its shared dependency and three exports" do
      assert {:ok, analysis} = Library.component("analysis")
      assert analysis.dependencies == ["cap"]

      assert {:ok, components} = Library.resolve_components([{:library, "analysis"}])
      assert Enum.map(components, & &1.id) == ["analysis", "cap"]

      assert {:ok, bundle} = Kernel.compile_bundle(components)

      for ref <- [
            "analysis/runs",
            "analysis/open",
            "analysis/read"
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

  defp run(source, opts \\ []) do
    {:ok, components} = Library.components(["cap"])
    {:ok, bundle} = Kernel.compile_bundle(components)

    run_opts =
      Keyword.merge(
        [
          prelude: bundle.prelude,
          tools: discovery_tools(),
          filter_context: false,
          caller: :kernel
        ],
        opts
      )

    case Lisp.run_native(source, run_opts) do
      {:ok, result} ->
        {rendered, _truncated} = Lisp.format_value(result.return)
        rendered

      {:error, result} ->
        flunk("unexpected evaluator failure: #{inspect(result.fail, limit: 20)}")
    end
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
