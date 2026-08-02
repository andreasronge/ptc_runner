defmodule PtcRunner.Kernel.DiscoverableReachabilityTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.TrustedTool

  # `cap` is the sharpest case in the shipped library: its own docstring calls
  # it "Capability discovery and envelope composition helpers", and it is
  # `:discoverable`, so before these forms existed nothing could discover the
  # discovery helper.
  defp cap_bundle do
    {:ok, components} = Library.components(["cap"])
    {:ok, bundle} = Kernel.compile_bundle(components)
    bundle
  end

  # `cap` declares the discovery tools it wraps, so the bundle only attaches
  # when the host grants them. Introspection never calls them.
  defp discovery_tools do
    Map.new(
      ~w(cap-list cap-describe),
      &{&1, %TrustedTool{function: fn _arguments -> %{status: :error} end}}
    )
  end

  defp run!(source, bundle) do
    {:ok, result} =
      Lisp.run_native(source,
        prelude: bundle.prelude,
        tools: discovery_tools(),
        filter_context: false,
        caller: :kernel
      )

    result
  end

  describe ":discoverable has two observable states" do
    test "a discoverable namespace is absent from the prompt inventory and present to (dir)" do
      bundle = cap_bundle()

      prompt_refs = Enum.map(Prelude.prompt_exports(bundle.prelude), & &1.ref)
      assert prompt_refs == []

      assert "cap/unwrap!" in run!(~S|(dir "cap")|, bundle).return,
             "a :discoverable export must be reachable by discovery, " <>
               "otherwise the visibility is merely hidden"
    end

    test "(dir) names the namespace the prompt withholds" do
      assert run!("(dir)", cap_bundle()).return == ["cap"]
    end

    test "documentation for a withheld export is readable" do
      assert [printed] = run!(~S|(doc "cap/collect-pages")|, cap_bundle()).prints

      assert printed =~ "cap/collect-pages"
      assert printed =~ "cursor"
    end

    test "apropos finds a withheld export by its docstring" do
      assert "cap/with-cursor" in run!(~S|(apropos "pagination")|, cap_bundle()).return
    end
  end

  describe "REPL sessions" do
    setup do
      bundle = cap_bundle()

      {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [])
      {:ok, mission} = MissionEnvironment.new([])
      {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)
      {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-introspection")

      {:ok, config} =
        RunConfig.new(
          workflow_environment: workflow,
          mission_environment: mission,
          input: %{},
          limits: limits,
          event_sink: sink
        )

      {:ok, session} = ReplSession.new(config: config)
      {:ok, session: session}
    end

    test "introspection answers the same way it does in a run", %{session: session} do
      assert {:ok, step, session} = ReplSession.eval(session, "(dir)")
      assert step.return == ["cap"]

      assert {:ok, step, session} = ReplSession.eval(session, ~S|(dir "cap")|)
      assert "cap/unwrap!" in step.return

      assert {:ok, step, _session} = ReplSession.eval(session, ~S|(export-meta "cap/unwrap!")|)
      assert step.return.ref == "cap/unwrap!"
      assert step.return.visibility == :discoverable
    end

    test "doc prints across a session turn and returns nil", %{session: session} do
      assert {:ok, step, _session} = ReplSession.eval(session, ~S|(doc "cap/unwrap!")|)

      assert step.return == nil
      assert [printed] = step.prints
      assert printed =~ "cap/unwrap!"
    end
  end
end
