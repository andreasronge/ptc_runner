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
    test "normalizes a page into items and a next cursor" do
      assert run(~S|(cap/with-cursor {:items [1 2] :next_cursor "abc"})|) ==
               ~S|{:cursor "abc" :items [1 2]}|
    end

    test "reports nil at the end of a collection" do
      assert run(~S|(cap/with-cursor {:items [1]})|) == "{:cursor nil :items [1]}"
    end

    test "unwraps a page still inside its capability envelope" do
      assert run(~S|(cap/with-cursor {:status :ok :value {:items ["x"]}})|) ==
               ~S|{:cursor nil :items ["x"]}|
    end

    test "tolerates a malformed page rather than crashing a traversal" do
      assert run(~S|(cap/with-cursor {:items "not-a-list" :next_cursor 7})|) ==
               "{:cursor nil :items []}"
    end

    # Traversal stays the caller's business; `with-cursor` shapes one page.
    test "composes into an explicit loop over pages" do
      source = ~S"""
      (let [pages {"" {:items [1 2] :next_cursor "p2"}
                   "p2" {:items [3] :next_cursor nil}}]
        (loop [cursor "" acc []]
          (let [page (cap/with-cursor (get pages cursor))
                gathered (concat acc (get page :items))]
            (if (get page :cursor)
              (recur (get page :cursor) gathered)
              gathered))))
      """

      assert run(source) == "[1 2 3]"
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
